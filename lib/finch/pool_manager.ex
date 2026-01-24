defmodule Finch.PoolManager do
  @moduledoc false
  use GenServer

  @type config() :: %{
          registry_name: atom(),
          manager_name: atom(),
          supervisor_name: atom(),
          default_pool_config: map(),
          pools: %{Finch.Pool.t() => map()}
        }

  @type pool_result() :: {pid(), module()} | :none | :not_found

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

  @spec start_link(config()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: config.manager_name)
  end

  @impl true
  @spec init(config()) :: {:ok, config()}
  def init(config) do
    if config.default_pool_config.start_pool_metrics? do
      :ets.new(default_pool_table(config.registry_name), [
        :set,
        :public,
        :named_table
      ])
    end

    Enum.each(config.pools, fn {pool, _} ->
      do_start_pools(pool, config)
    end)

    {:ok, config}
  end

  @spec get_pool(atom(), Finch.Pool.t(), Keyword.t()) :: pool_result()
  def get_pool(registry_name, %Finch.Pool{} = pool, opts \\ []) do
    case lookup_pool(registry_name, pool) do
      {pid, _} = pool_result when is_pid(pid) ->
        pool_result

      :none ->
        if Keyword.get(opts, :auto_start?, true),
          do: start_pools(registry_name, pool),
          else: :not_found
    end
  end

  @spec lookup_pool(atom(), Finch.Pool.t()) :: {pid(), module()} | :none
  defp lookup_pool(registry, pool) do
    case all_pool_instances(registry, pool) do
      [] ->
        :none

      [pool_result] ->
        pool_result

      pools ->
        # TODO implement alternative strategies
        Enum.random(pools)
    end
  end

  @spec all_pool_instances(atom(), Finch.Pool.t()) :: [{pid(), module()}]
  def all_pool_instances(registry, pool), do: Registry.lookup(registry, Finch.Pool.to_shp(pool))

  @spec start_pools(atom(), Finch.Pool.t()) :: {pid(), module()}
  defp start_pools(registry_name, pool) do
    {:ok, config} = Registry.meta(registry_name, :config)
    GenServer.call(config.manager_name, {:start_pools, pool})
  end

  @impl true
  @spec handle_call({:start_pools, Finch.Pool.t()}, GenServer.from(), config()) ::
          {:reply, {pid(), module()}, config()}
  def handle_call({:start_pools, pool}, _from, state) do
    reply =
      case lookup_pool(state.registry_name, pool) do
        :none -> do_start_pools(pool, state)
        pool -> pool
      end

    {:reply, reply, state}
  end

  defp do_start_pools(pool, config) do
    pool_config = pool_config(config, pool)

    if pool_config.start_pool_metrics? do
      maybe_track_default_pool(config, pool)
      put_pool_count(config, pool, pool_config.count)
    end

    Enum.map(1..pool_config.count, fn pool_idx ->
      pool_args = pool_args(pool, config, pool_config, pool_idx)
      # Choose pool type here...
      {:ok, pid} =
        DynamicSupervisor.start_child(config.supervisor_name, {pool_config.mod, pool_args})

      {pid, pool_config.mod}
    end)
    |> hd()
  end

  defp put_pool_count(%{registry_name: name}, %Finch.Pool{} = pool, val),
    do: :persistent_term.put({__MODULE__, :pool_count, name, pool}, val)

  @spec get_pool_count(atom(), Finch.Pool.t()) :: non_neg_integer() | nil
  def get_pool_count(finch_name, pool),
    do: :persistent_term.get({__MODULE__, :pool_count, finch_name, pool}, nil)

  defp maybe_track_default_pool(%{pools: pools, registry_name: name}, pool) do
    if Map.has_key?(pools, pool),
      do: :ok,
      else: add_default_pool(name, pool)
  end

  defp default_pool_table(name), do: :"#{name}.default_pool_table"

  defp add_default_pool(name, pool) do
    true =
      name
      |> default_pool_table()
      |> :ets.insert({pool})

    :ok
  end

  @spec get_default_pools(atom()) :: [Finch.Pool.t()]
  def get_default_pools(name) do
    tname = default_pool_table(name)

    if :ets.whereis(tname) == :undefined do
      []
    else
      tname
      |> :ets.tab2list()
      |> Enum.map(fn {pool} -> pool end)
    end
  end

  @spec maybe_remove_default_pool(atom(), Finch.Pool.t()) :: :ok
  def maybe_remove_default_pool(name, pool) do
    tname = default_pool_table(name)

    if :ets.whereis(tname) == :undefined do
      :ok
    else
      true = :ets.delete(tname, pool)
      :ok
    end
  end

  defp pool_config(%{pools: config, default_pool_config: default}, pool) do
    config
    |> Map.get(pool, default)
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

  defp pool_args(pool, config, %{mod: Finch.HTTP1.Pool} = pool_config, pool_idx),
    do: {
      pool,
      config.registry_name,
      pool_config.size,
      pool_config,
      pool_config.pool_max_idle_time,
      pool_config.start_pool_metrics?,
      pool_idx
    }

  defp pool_args(pool, config, %{mod: Finch.HTTP2.Pool} = pool_config, pool_idx),
    do: {
      pool,
      config.registry_name,
      pool_config,
      pool_config.start_pool_metrics?,
      pool_idx
    }
end
