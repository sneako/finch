defmodule Finch.PoolManager do
  @moduledoc false
  use GenServer

  @mint_tls_opts [
    :cacertfile,
    :ciphers,
    :depth,
    :partial_chain,
    :reuse_sessions,
    :secure_renegotiate,
    :server_name_indication,
    :verify,
    :verify_fun,
    :versions
  ]

  @default_conn_hostname "localhost"

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: config.manager_name)
  end

  @impl true
  def init(config) do
    Enum.each(config.pools, fn {shp, _} ->
      do_start_pools(shp, config)
    end)

    {:ok, config}
  end

  def get_pool(registry_name, {_scheme, _host, _port} = key, opts \\ []) do
    case lookup_pool(registry_name, key) do
      {pid, _} = pool when is_pid(pid) ->
        pool

      :none ->
        if Keyword.get(opts, :auto_start?, true),
          do: start_pools(registry_name, key),
          else: :not_found
    end
  end

  def lookup_pool(registry, key) do
    case Registry.lookup(registry, key) do
      [] ->
        :none

      [pool] ->
        pool

      pools ->
        # TODO implement alternative strategies
        Enum.random(pools)
    end
  end

  def start_pools(registry_name, shp) do
    {:ok, config} = Registry.meta(registry_name, :config)
    GenServer.call(config.manager_name, {:start_pools, shp})
  end

  @impl true
  def handle_call({:start_pools, shp}, _from, state) do
    reply =
      case lookup_pool(state.registry_name, shp) do
        :none -> do_start_pools(shp, state)
        pool -> pool
      end

    {:reply, reply, state}
  end

  defp do_start_pools(shp, config) do
    pool_config = pool_config(config, shp)

    if pool_config.start_pool_metrics? do
      put_pool_count(config, shp, pool_config.count)
    end

    Enum.map(1..pool_config.count, fn pool_idx ->
      pool_args = pool_args(shp, config, pool_config, pool_idx)
      # Choose pool type here...
      {:ok, pid} =
        DynamicSupervisor.start_child(config.supervisor_name, {pool_config.mod, pool_args})

      {pid, pool_config.mod}
    end)
    |> hd()
  end

  defp put_pool_count(%{registry_name: name}, shp, val),
    do: :persistent_term.put({__MODULE__, :pool_count, name, shp}, val)

  def get_pool_count(finch_name, shp),
    do: :persistent_term.get({__MODULE__, :pool_count, finch_name, shp}, nil)

  defp pool_config(%{pools: config, default_pool_config: default}, shp) do
    config
    |> Map.get(shp, default)
    |> maybe_drop_tls_options(shp)
    |> maybe_add_hostname(shp)
  end

  # Drop TLS options from :conn_opts for default pools with :http scheme,
  # otherwise you will get :badarg error from :gen_tcp
  defp maybe_drop_tls_options(config, {:http, _, _} = _shp) when is_map(config) do
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

  # Hostname is required when the address is not a url (binary) so we need to specify
  # a default value in case the configuration does not specify one.
  defp maybe_add_hostname(config, {_scheme, {:local, _path}, _port} = _shp) when is_map(config) do
    conn_opts =
      config |> Map.get(:conn_opts, []) |> Keyword.put_new(:hostname, @default_conn_hostname)

    Map.put(config, :conn_opts, conn_opts)
  end

  defp maybe_add_hostname(config, _), do: config

  defp pool_args(shp, config, %{mod: Finch.HTTP1.Pool} = pool_config, pool_idx),
    do: {
      shp,
      config.registry_name,
      pool_config.size,
      pool_config,
      pool_config.pool_max_idle_time,
      pool_config.start_pool_metrics?,
      pool_idx
    }

  defp pool_args(shp, config, %{mod: Finch.HTTP2.Pool} = pool_config, pool_idx),
    do: {
      shp,
      config.registry_name,
      pool_config,
      pool_config.start_pool_metrics?,
      pool_idx
    }
end
