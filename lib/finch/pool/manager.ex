defmodule Finch.Pool.Manager do
  @moduledoc false
  use GenServer

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

  @spec supervisor_registry_name(atom()) :: atom()
  def supervisor_registry_name(name), do: :"#{name}.SupervisorRegistry"

  @spec start_link(config()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    Enum.each(config.pools, fn {pool, _} -> start_pool(pool, config) end)
    :ignore
  end

  @spec get_pool(atom(), Finch.Pool.t()) :: {pid(), module()} | :not_found
  def get_pool(registry_name, %Finch.Pool{} = pool, start_pool? \\ true) do
    case Registry.lookup(registry_name, Finch.Pool.to_name(pool)) do
      [] when start_pool? ->
        {:ok, config} = Registry.meta(registry_name, :config)
        start_pool(pool, config)
        get_pool(registry_name, pool, false)

      [] ->
        :not_found

      [_ | _] = entries ->
        Enum.random(entries)
    end
  end

  @spec get_pool_supervisor(Finch.name(), Finch.Pool.t()) ::
          {pid(), Finch.Pool.name(), module(), pos_integer()} | :not_found
  def get_pool_supervisor(finch_name, %Finch.Pool{} = pool) do
    pool_name = Finch.Pool.to_name(pool)

    # Checks if a finch instance exists by verifying the registry config exists.
    # This prevents atom creation when checking non-existent instances.
    if Process.whereis(finch_name) do
      case Registry.lookup(supervisor_registry_name(finch_name), pool_name) do
        [] -> :not_found
        [{pid, {pool_mod, pool_count}}] -> {pid, pool_name, pool_mod, pool_count}
      end
    else
      :not_found
    end
  end

  @spec get_default_pools(atom()) :: [{pid(), {Finch.Pool.name(), module(), pos_integer()}}]
  def get_default_pools(registry_name) do
    Registry.lookup(registry_name, :default)
  end

  ## Callbacks

  defp start_pool(pool, config) do
    pool_name = Finch.Pool.to_name(pool)
    pool_config = pool_config(config, pool)
    track_default? = pool_config.start_pool_metrics? and not Map.has_key?(config.pools, pool)

    data = {pool_config.mod, pool_config.count}
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

  defp pool_config(%{pools: pools, default_pool_config: default}, %Finch.Pool{} = pool) do
    case Map.get(pools, pool) do
      nil -> default
      config -> config
    end
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
