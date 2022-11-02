defmodule Finch.HTTP1.Pool do
  @moduledoc false
  @behaviour NimblePool
  @behaviour Finch.Pool

  alias Finch.Conn
  alias Finch.Telemetry

  def child_spec(opts) do
    {_shp, _registry_name, _pool_size, _conn_opts, pool_max_idle_time} = opts

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: restart_option(pool_max_idle_time)
    }
  end

  def start_link({shp, registry_name, pool_size, conn_opts, pool_max_idle_time}) do
    NimblePool.start_link(
      worker: {__MODULE__, {registry_name, shp, conn_opts}},
      pool_size: pool_size,
      lazy: true,
      worker_idle_timeout: pool_idle_timout(pool_max_idle_time)
    )
  end

  @impl Finch.Pool
  def request(pool, req, acc, fun, opts) do
    pool_timeout = Keyword.get(opts, :pool_timeout, 5_000)
    receive_timeout = Keyword.get(opts, :receive_timeout, 15_000)

    metadata = %{request: req, pool: pool}

    start_time = Telemetry.start(:queue, metadata)

    try do
      NimblePool.checkout!(
        pool,
        :checkout,
        fn from, {state, conn, idle_time} ->
          Telemetry.stop(:queue, start_time, metadata, %{idle_time: idle_time})

          with {:ok, conn} <- Conn.connect(conn),
               {:ok, conn, acc} <- Conn.request(conn, req, acc, fun, receive_timeout, idle_time) do
            {{:ok, acc}, transfer_if_open(conn, state, from)}
          else
            {:error, conn, error} ->
              {{:error, error}, transfer_if_open(conn, state, from)}
          end
        end,
        pool_timeout
      )
    catch
      :exit, data ->
        Telemetry.exception(:queue, start_time, :exit, data, __STACKTRACE__, metadata)

        # Provide helpful error messages for known errors
        case data do
          {:timeout, {NimblePool, :checkout, _affected_pids}} ->
            reraise(
              """
              Finch was unable to provide a connection within the timeout due to excess queuing \
              for connections. Consider adjusting the pool size, count, timeout or reducing the \
              rate of requests if it is possible that the downstream service is unable to keep up \
              with the current rate.
              """,
              __STACKTRACE__
            )

          _ ->
            exit(data)
        end
    end
  end

  @impl NimblePool
  def init_pool({registry, shp, opts}) do
    # Register our pool with our module name as the key. This allows the caller
    # to determine the correct pool module to use to make the request
    {:ok, _} = Registry.register(registry, shp, __MODULE__)
    {:ok, {shp, opts}}
  end

  @impl NimblePool
  def init_worker({{scheme, host, port}, opts} = pool_state) do
    {:ok, Conn.new(scheme, host, port, opts, self()), pool_state}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _, %{mint: nil} = conn, pool_state) do
    idle_time = System.monotonic_time() - conn.last_checkin
    {:ok, {:fresh, conn, idle_time}, conn, pool_state}
  end

  def handle_checkout(:checkout, _from, conn, pool_state) do
    idle_time = System.monotonic_time() - conn.last_checkin

    with true <- Conn.reusable?(conn, idle_time),
         {:ok, conn} <- Conn.set_mode(conn, :passive) do
      {:ok, {:reuse, conn, idle_time}, conn, pool_state}
    else
      false ->
        {{scheme, host, port}, _opts} = pool_state

        meta = %{
          scheme: scheme,
          host: host,
          port: port
        }

        # Deprecated, remember to delete when we remove the :max_idle_time pool config option!
        Telemetry.event(:max_idle_time_exceeded, %{idle_time: idle_time}, meta)

        Telemetry.event(:conn_max_idle_time_exceeded, %{idle_time: idle_time}, meta)

        {:remove, :closed, pool_state}

      _ ->
        {:remove, :closed, pool_state}
    end
  end

  @impl NimblePool
  def handle_checkin(checkin, _from, _old_conn, pool_state) do
    with {:ok, conn} <- checkin,
         {:ok, conn} <- Conn.set_mode(conn, :active) do
      {:ok, %{conn | last_checkin: System.monotonic_time()}, pool_state}
    else
      _ ->
        {:remove, :closed, pool_state}
    end
  end

  @impl NimblePool
  def handle_update(new_conn, _old_conn, pool_state) do
    {:ok, new_conn, pool_state}
  end

  @impl NimblePool
  def handle_info(message, conn) do
    case Conn.discard(conn, message) do
      {:ok, conn} -> {:ok, conn}
      :unknown -> {:ok, conn}
      {:error, _error} -> {:remove, :closed}
    end
  end

  @impl NimblePool
  def handle_ping(_conn, pool_state) do
    {{scheme, host, port}, _opts} = pool_state

    meta = %{
      scheme: scheme,
      host: host,
      port: port
    }

    Telemetry.event(:pool_max_idle_time_exceeded, %{}, meta)

    {:stop, :idle_timeout}
  end

  @impl NimblePool
  # On terminate, effectively close it.
  # This will succeed even if it was already closed or if we don't own it.
  def terminate_worker(_reason, conn, pool_state) do
    Conn.close(conn)
    {:ok, pool_state}
  end

  defp transfer_if_open(conn, state, {pid, _} = from) do
    if Conn.open?(conn) do
      if state == :fresh do
        NimblePool.update(from, conn)

        case Conn.transfer(conn, pid) do
          {:ok, conn} -> {:ok, conn}
          {:error, _, _} -> :closed
        end
      else
        {:ok, conn}
      end
    else
      :closed
    end
  end

  defp restart_option(:infinity), do: :permanent
  defp restart_option(_pool_max_idle_time), do: :transient

  defp pool_idle_timout(:infinity), do: nil
  defp pool_idle_timout(pool_max_idle_time), do: pool_max_idle_time
end
