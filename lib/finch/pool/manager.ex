defmodule Finch.Pool.Manager do
  @moduledoc false
  use GenServer

  @typedoc false
  @type request_ref :: {pool_mod :: module(), cancel_ref :: term()}

  @typedoc false
  @opaque pool_name() ::
            {Finch.Pool.scheme(), Finch.Pool.host(), :inet.port_number(), Finch.Pool.pool_tag()}

  @doc false
  @callback request(
              pid(),
              Finch.Request.t(),
              acc,
              Finch.stream(acc),
              Finch.name(),
              list()
            ) :: {:ok, acc} | {:error, term(), acc}
            when acc: term()

  @doc false
  @callback async_request(
              pid(),
              Finch.Request.t(),
              Finch.name(),
              list()
            ) :: request_ref()

  @doc false
  @callback cancel_async_request(request_ref()) :: :ok

  @doc false
  @callback get_pool_status(finch_name :: atom(), pool_name(), pos_integer) ::
              {:ok, list(map)} | {:error, :not_found}

  @doc false
  defguard is_request_ref(ref) when tuple_size(ref) == 2 and is_atom(elem(ref, 0))

  @type config() :: %{
          registry_name: atom(),
          supervisor_name: atom(),
          supervisor_registry_name: atom(),
          default_pool_config: map(),
          pools: %{Finch.Pool.t() => map()}
        }

  @mint_tls_opts [
    :cacertfile,
    :cacerts,
    :ciphers,
    :depth,
    :eccs,
    :hibernate_after,
    :partial_chain,
    :reuse_sessions,
    :secure_renegotiate,
    :server_name_indication,
    :signature_algs,
    :signature_algs_cert,
    :supported_groups,
    :verify,
    :verify_fun,
    :versions
  ]

  @default_conn_hostname "localhost"

  @spec supervisor_name(atom()) :: atom()
  def supervisor_name(name), do: :"#{name}.PoolSupervisor"

  @spec supervisor_registry_name(atom()) :: atom()
  def supervisor_registry_name(name), do: :"#{name}.SupervisorRegistry"

  @spec start_link(config()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    Enum.each(config.pools, fn {pool, _} ->
      pool_name = Finch.Pool.to_name(pool)
      start_pool(pool, pool_name, config)
    end)

    :ignore
  end

  @spec get_pool(atom(), Finch.Pool.t(), Access.t()) ::
          {pid(), module()} | :not_found | :not_ready
  def get_pool(registry_name, %Finch.Pool{} = pool, opts \\ [start_pool?: true]) do
    start_pool? = Access.get(opts, :start_pool?, true)
    do_get_pool(registry_name, pool, start_pool?, opts)
  end

  defp do_get_pool(registry_name, pool, start_pool?, opts) do
    pool_name = Finch.Pool.to_name(pool)

    case Registry.lookup(registry_name, pool_name) do
      [] when start_pool? ->
        maybe_start_pool(registry_name, pool, pool_name, opts)

      [] ->
        :not_found

      [single] ->
        single

      [_ | _] = entries ->
        select_pool(entries, opts[:pool_strategy])
    end
  end

  defp select_pool(entries, nil), do: Enum.random(entries)
  defp select_pool(entries, {fun, state}) when is_function(fun, 2), do: fun.(entries, state)
  defp select_pool(entries, {mod, state}) when is_atom(mod), do: mod.select(entries, state)
  defp select_pool(entries, fun) when is_function(fun, 1), do: fun.(entries)
  defp select_pool(entries, mod) when is_atom(mod), do: mod.select(entries, nil)

  @spec maybe_start_pool(atom(), Finch.Pool.t(), term(), Access.t()) ::
          {pid(), module()} | :not_found | :not_ready
  defp maybe_start_pool(registry_name, pool, pool_name, opts) do
    case Registry.lookup(supervisor_registry_name(registry_name), pool_name) do
      [] ->
        # No supervisor — pool not configured yet, create on demand
        {:ok, config} = Registry.meta(registry_name, :config)
        start_pool(pool, pool_name, config)
        do_get_pool(registry_name, pool, false, opts)

      [_ | _] ->
        # Supervisor exists but no ready workers
        :not_ready
    end
  end

  @spec get_pool_supervisor(Finch.name(), Finch.Pool.t()) ::
          {pid(), pool_name(), module(), pos_integer(), map()} | :not_found
  def get_pool_supervisor(finch_name, %Finch.Pool{} = pool) do
    pool_name = Finch.Pool.to_name(pool)

    # Checks if a finch instance exists by verifying the registry config exists.
    # This prevents atom creation when checking non-existent instances.
    if Process.whereis(finch_name) do
      case Registry.lookup(supervisor_registry_name(finch_name), pool_name) do
        [] ->
          :not_found

        [{pid, {pool_mod, _pool_count, pool_config}}] ->
          # Derive current worker count from supervisor children for accurate
          # count after runtime resize via set_pool_count/3
          try do
            pool_count = Supervisor.count_children(pid).workers
            {pid, pool_name, pool_mod, pool_count, pool_config}
          catch
            :exit, _ -> :not_found
          end
      end
    else
      :not_found
    end
  end

  @spec get_default_pools(atom()) :: [{pid(), {pool_name(), module(), pos_integer()}}]
  def get_default_pools(registry_name) do
    Registry.lookup(registry_name, :default)
  end

  @doc false
  @spec pool_child_spec(Finch.name(), Finch.Pool.t(), map()) :: Supervisor.child_spec()
  def pool_child_spec(finch_name, pool, opts) do
    {:ok, config} = Registry.meta(finch_name, :config)
    pool_name = Finch.Pool.to_name(pool)
    pool_config = sanitize_pool_config(opts, pool)
    data = {pool_config.mod, pool_config.count, pool_config}
    name = {:via, Registry, {config.supervisor_registry_name, pool_name, data}}

    Supervisor.child_spec(
      {Finch.Pool.Supervisor, {name, {config.registry_name, pool, pool_config, false}}},
      id: {Finch.Pool.Supervisor, pool_name}
    )
  end

  @spec set_pool_count(Finch.name(), Finch.Pool.t(), pos_integer()) :: :ok | {:error, term()}
  def set_pool_count(finch_name, %Finch.Pool{} = pool, count) do
    case get_pool_supervisor(finch_name, pool) do
      :not_found ->
        {:error, :not_found}

      {pid, _pool_name, _pool_mod, old_count, pool_config} ->
        Finch.Pool.Supervisor.set_count(pid, pool, finch_name, pool_config, old_count, count)
    end
  end

  ## Callbacks

  defp start_pool(pool, pool_name, config) do
    pool_config = pool_config(config, pool)
    track_default? = pool_config.start_pool_metrics? and not Map.has_key?(config.pools, pool)

    data = {pool_config.mod, pool_config.count, pool_config}
    name = {:via, Registry, {config.supervisor_registry_name, pool_name, data}}

    config.supervisor_name
    |> DynamicSupervisor.start_child(
      {Finch.Pool.Supervisor, {name, {config.registry_name, pool, pool_config, track_default?}}}
    )
    # In case of races, it will return it has already been started
    |> case do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp pool_config(%{pools: config, default_pool_config: default}, %Finch.Pool{} = pool) do
    config
    |> Map.get(pool, default)
    |> sanitize_pool_config(pool)
  end

  defp sanitize_pool_config(pool_config, pool) do
    pool_config
    |> maybe_drop_tls_options(pool)
    |> maybe_add_hostname(pool)
  end

  # Drop TLS options from :conn_opts for default pools with :http scheme,
  # otherwise you will get :badarg error from :gen_tcp
  defp maybe_drop_tls_options(config, %Finch.Pool{scheme: :http}) when is_map(config) do
    with conn_opts when is_list(conn_opts) <- config[:conn_opts],
         trns_opts when is_list(trns_opts) <- conn_opts[:transport_opts] do
      trns_opts = Keyword.drop(trns_opts, @mint_tls_opts)
      conn_opts = Keyword.put(conn_opts, :transport_opts, trns_opts)
      Map.put(config, :conn_opts, conn_opts)
    else
      _ -> config
    end
  end

  defp maybe_drop_tls_options(config, _), do: config

  # Hostname is required when the address is not a URL (binary) so we need to specify
  # a default value in case the configuration does not specify one.
  defp maybe_add_hostname(config, %Finch.Pool{host: {:local, _path}}) when is_map(config) do
    conn_opts =
      config |> Map.get(:conn_opts, []) |> Keyword.put_new(:hostname, @default_conn_hostname)

    Map.put(config, :conn_opts, conn_opts)
  end

  defp maybe_add_hostname(config, _), do: config
end
