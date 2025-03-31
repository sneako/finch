defmodule Finch.HTTP1.Pool do
  @moduledoc false
  @behaviour NimblePool
  @behaviour Finch.Pool

  defmodule State do
    @moduledoc false
    defstruct [
      :registry,
      :shp,
      :pool_idx,
      :metric_ref,
      :opts
    ]
  end

  alias Finch.HTTP1.Conn
  alias Finch.Telemetry
  alias Finch.HTTP1.PoolMetrics

  def child_spec(opts) do
    {
      _shp,
      _registry_name,
      _pool_size,
      _conn_opts,
      pool_max_idle_time,
      _start_pool_metrics?,
      _pool_idx
    } = opts

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: restart_option(pool_max_idle_time)
    }
  end

  def start_link(
        {shp, registry_name, pool_size, conn_opts, pool_max_idle_time, start_pool_metrics?,
         pool_idx}
      ) do
    NimblePool.start_link(
      worker:
        {__MODULE__, {registry_name, shp, pool_idx, pool_size, start_pool_metrics?, conn_opts}},
      pool_size: pool_size,
      lazy: true,
      worker_idle_timeout: pool_idle_timeout(pool_max_idle_time)
    )
  end

  @impl Finch.Pool
  def request(pool, req, acc, fun, name, opts) do
    pool_timeout = Keyword.get(opts, :pool_timeout, 5_000)
    receive_timeout = Keyword.get(opts, :receive_timeout, 15_000)
    request_timeout = Keyword.get(opts, :request_timeout, :infinity)

    metadata = %{request: req, pool: pool, name: name}

    start_time = Telemetry.start(:queue, metadata)

    try do
      NimblePool.checkout!(
        pool,
        :checkout,
        fn from, {state, conn, idle_time} ->
          Telemetry.stop(:queue, start_time, metadata, %{idle_time: idle_time})

          case Conn.connect(conn, name) do
            {:ok, conn} ->
              Conn.request(conn, req, acc, fun, name, receive_timeout, request_timeout, idle_time)
              |> case do
                {:ok, conn, acc} ->
                  {{:ok, acc}, transfer_if_open(conn, state, from)}

                {:error, conn, error, acc} ->
                  {{:error, error, acc}, transfer_if_open(conn, state, from)}
              end

            {:error, conn, error} ->
              {{:error, error, acc}, transfer_if_open(conn, state, from)}
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

  @impl Finch.Pool
  def async_request(pool, req, name, opts) do
    owner = self()

    pid =
      spawn_link(fn ->
        monitor = Process.monitor(owner)
        request_ref = {__MODULE__, self()}

        case request(
               pool,
               req,
               {owner, monitor, request_ref},
               &send_async_response/2,
               name,
               opts
             ) do
          {:ok, _} -> send(owner, {request_ref, :done})
          {:error, error, _acc} -> send(owner, {request_ref, {:error, error}})
        end
      end)

    {__MODULE__, pid}
  end

  defp send_async_response(response, {owner, monitor, request_ref}) do
    if process_down?(monitor) do
      exit(:shutdown)
    end

    send(owner, {request_ref, response})
    {:cont, {owner, monitor, request_ref}}
  end

  defp process_down?(monitor) do
    receive do
      {:DOWN, ^monitor, _, _, _} -> true
    after
      0 -> false
    end
  end

  @impl Finch.Pool
  def cancel_async_request({_, pid} = _request_ref) do
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
    :ok
  end

  @impl Finch.Pool
  def get_pool_status(finch_name, shp) do
    case Finch.PoolManager.get_pool_count(finch_name, shp) do
      nil ->
        {:error, :not_found}

      count ->
        1..count
        |> Enum.map(&PoolMetrics.get_pool_status(finch_name, shp, &1))
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(&elem(&1, 1))
        |> case do
          [] -> {:error, :not_found}
          result -> {:ok, result}
        end
    end
  end

  @impl NimblePool
  def init_pool({registry, shp, pool_idx, pool_size, start_pool_metrics?, opts}) do
    {:ok, metric_ref} =
      if start_pool_metrics?,
        do: PoolMetrics.init(registry, shp, pool_idx, pool_size),
        else: {:ok, nil}

    # Register our pool with our module name as the key. This allows the caller
    # to determine the correct pool module to use to make the request
    {:ok, _} = Registry.register(registry, shp, __MODULE__)

    state = %__MODULE__.State{
      registry: registry,
      shp: shp,
      pool_idx: pool_idx,
      metric_ref: metric_ref,
      opts: opts
    }

    {:ok, state}
  end

  @impl NimblePool
  def init_worker(%__MODULE__.State{shp: {scheme, host, port}, opts: opts} = pool_state) do
    {:ok, Conn.new(scheme, host, port, opts, self()), pool_state}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _, %{mint: nil} = conn, %__MODULE__.State{} = pool_state) do
    idle_time = System.monotonic_time() - conn.last_checkin
    PoolMetrics.maybe_add(pool_state.metric_ref, in_use_connections: 1)
    {:ok, {:fresh, conn, idle_time}, conn, pool_state}
  end

  def handle_checkout(:checkout, _from, conn, %__MODULE__.State{} = pool_state) do
    idle_time = System.monotonic_time() - conn.last_checkin

    %__MODULE__.State{
      shp: {scheme, host, port},
      metric_ref: metric_ref
    } = pool_state

    with true <- Conn.reusable?(conn, idle_time),
         {:ok, conn} <- Conn.set_mode(conn, :passive) do
      PoolMetrics.maybe_add(metric_ref, in_use_connections: 1)
      {:ok, {:reuse, conn, idle_time}, conn, pool_state}
    else
      false ->
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
  def handle_checkin(checkin, _from, _old_conn, %__MODULE__.State{} = pool_state) do
    %__MODULE__.State{metric_ref: metric_ref} = pool_state
    PoolMetrics.maybe_add(metric_ref, in_use_connections: -1)

    with {:ok, conn} <- checkin,
         {:ok, conn} <- Conn.set_mode(conn, :active) do
      {:ok, %{conn | last_checkin: System.monotonic_time()}, pool_state}
    else
      _ ->
        {:remove, :closed, pool_state}
    end
  end

  @impl NimblePool
  def handle_update(new_conn, _old_conn, %__MODULE__.State{} = pool_state) do
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
  def handle_ping(_conn, %__MODULE__.State{} = pool_state) do
    %__MODULE__.State{shp: {scheme, host, port}} = pool_state

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
  def terminate_worker(_reason, conn, %__MODULE__.State{} = pool_state) do
    Conn.close(conn)
    {:ok, pool_state}
  end

  @impl NimblePool
  def handle_cancelled(:checked_out, %__MODULE__.State{} = pool_state) do
    %__MODULE__.State{metric_ref: metric_ref} = pool_state
    PoolMetrics.maybe_add(metric_ref, in_use_connections: -1)
    :ok
  end

  def handle_cancelled(:queued, _pool_state), do: :ok

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

  defp pool_idle_timeout(:infinity), do: nil
  defp pool_idle_timeout(pool_max_idle_time), do: pool_max_idle_time
end
