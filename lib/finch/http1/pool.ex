defmodule Finch.HTTP1.Pool do
  @moduledoc false
  @behaviour NimblePool
  @behaviour Finch.Pool.Manager

  defmodule State do
    @moduledoc false
    defstruct [
      :registry,
      :pool,
      :pool_idx,
      :metric_ref,
      :opts,
      :activity_info,
      :idle_stop
    ]
  end

  alias Finch.HTTP1.Conn
  alias Finch.Telemetry
  alias Finch.HTTP1.PoolMetrics

  # How long an idle pool stays out of the registry before it stops. A caller
  # that found the pool just before it left the registry reaches it within
  # this window, and its checkout brings the pool back.
  @idle_stop_grace_ms 1000

  def child_spec(opts) do
    {_pool, _pool_name, _registry_name, pool_config, _pool_idx} = opts

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: restart_option(pool_config.pool_max_idle_time)
    }
  end

  def start_link({_pool, _pool_name, _registry_name, pool_config, _pool_idx} = arg) do
    NimblePool.start_link(
      worker: {__MODULE__, arg},
      pool_size: pool_config.size,
      lazy: true
    )
  end

  @impl Finch.Pool.Manager
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

  @impl Finch.Pool.Manager
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

  @impl Finch.Pool.Manager
  def cancel_async_request({_, pid} = _request_ref) do
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
    :ok
  end

  @impl Finch.Pool.Manager
  defdelegate get_pool_status(finch_name, pool_name), to: PoolMetrics

  # A pool that is about to stop on idle is no longer registered. Asking it
  # whether it is ready brings it back, and a pool that already stopped never
  # answers.
  @impl Finch.Pool.Manager
  def ready?(pool, timeout) do
    tag = :erlang.monitor(:process, pool, alias: :reply_demonitor)
    :ok = NimblePool.pool_cast(pool, {:ready?, tag})

    receive do
      {^tag, :ready} ->
        true

      {:DOWN, ^tag, _, _, _} ->
        :retry
    after
      timeout ->
        :erlang.demonitor(tag, [:flush])
        false
    end
  end

  @impl NimblePool
  def init_pool({pool, pool_name, registry, pool_config, pool_idx}) do
    {:ok, metric_ref} =
      if pool_config.start_pool_metrics?,
        do: PoolMetrics.init(registry, pool_name, pool_idx, pool_config.size),
        else: {:ok, nil}

    # Register our pool with our module name as the key. This allows the caller
    # to determine the correct pool module to use to make the request
    {:ok, _} = Registry.register(registry, pool_name, __MODULE__)

    acitivity_info =
      case pool_config.pool_max_idle_time do
        :infinity ->
          nil

        max_idle_time ->
          NimblePool.pool_cast_after(self(), :check_idle, max_idle_time)
          init_activity_info()
      end

    state = %__MODULE__.State{
      registry: registry,
      pool: pool,
      pool_idx: pool_idx,
      metric_ref: metric_ref,
      opts: pool_config,
      activity_info: acitivity_info
    }

    {:ok, state}
  end

  @impl NimblePool
  def init_worker(%__MODULE__.State{pool: pool, opts: opts} = pool_state) do
    {:ok, Conn.new(pool.scheme, pool.host, pool.port, opts, self()), pool_state}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _, %{mint: nil} = conn, %__MODULE__.State{} = pool_state) do
    idle_time = System.monotonic_time() - conn.last_checkin
    PoolMetrics.maybe_add(pool_state.metric_ref, :in_use_connections, 1)
    {:ok, {:fresh, conn, idle_time}, conn, update_activity_info(:checkout, pool_state)}
  end

  def handle_checkout(:checkout, _from, conn, %__MODULE__.State{} = pool_state) do
    idle_time = System.monotonic_time() - conn.last_checkin

    %__MODULE__.State{
      pool: pool,
      metric_ref: metric_ref
    } = pool_state

    with true <- Conn.reusable?(conn, idle_time),
         {:ok, conn} <- Conn.set_mode(conn, :passive) do
      PoolMetrics.maybe_add(metric_ref, :in_use_connections, 1)
      {:ok, {:reuse, conn, idle_time}, conn, update_activity_info(:checkout, pool_state)}
    else
      false ->
        meta = %{
          scheme: pool.scheme,
          host: pool.host,
          port: pool.port
        }

        Telemetry.event(:conn_max_idle_time_exceeded, %{idle_time: idle_time}, meta)

        {:remove, :closed, pool_state}

      _ ->
        {:remove, :closed, pool_state}
    end
  end

  @impl NimblePool
  def handle_checkin(checkin, _from, _old_conn, %__MODULE__.State{} = pool_state) do
    %__MODULE__.State{metric_ref: metric_ref} = pool_state
    PoolMetrics.maybe_add(metric_ref, :in_use_connections, -1)

    with {:ok, conn} <- checkin,
         {:ok, conn} <- Conn.set_mode(conn, :active) do
      {
        :ok,
        %{conn | last_checkin: System.monotonic_time()},
        update_activity_info(:checkin, pool_state)
      }
    else
      _ ->
        {:remove, :closed, update_activity_info(:checkin, pool_state)}
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
  def handle_pool_cast(:check_idle, %__MODULE__.State{} = pool_state) do
    case idle_time_left(pool_state) do
      0 ->
        # Need to unregister first to prevent the race condition described in
        # https://github.com/sneako/finch/issues/384
        Registry.unregister(pool_state.registry, Finch.Pool.to_name(pool_state.pool))
        ref = make_ref()
        NimblePool.pool_cast_after(self(), {:stop_idle, ref}, @idle_stop_grace_ms)
        {:noreply, %{pool_state | idle_stop: ref}}

      time_left ->
        NimblePool.pool_cast_after(self(), :check_idle, time_left)
        {:noreply, pool_state}
    end
  end

  def handle_pool_cast({:stop_idle, ref}, %__MODULE__.State{idle_stop: ref} = pool_state) do
    if idle_time_left(pool_state) == 0 do
      %__MODULE__.State{pool: pool} = pool_state
      meta = %{scheme: pool.scheme, host: pool.host, port: pool.port}
      Telemetry.event(:pool_max_idle_time_exceeded, %{}, meta)
      {:stop, {:shutdown, :idle_timeout}, pool_state}
    else
      # If we endup here, it means some checkout happened during the
      # termination grace period, so we need to revive the pool
      {:noreply, revive(pool_state)}
    end
  end

  # A request brought the pool back after this stop was scheduled.
  def handle_pool_cast({:stop_idle, _ref}, %__MODULE__.State{} = pool_state) do
    {:noreply, pool_state}
  end

  def handle_pool_cast({:ready?, tag}, %__MODULE__.State{} = pool_state) do
    send(tag, {tag, :ready})
    {:noreply, revive(pool_state)}
  end

  @impl NimblePool
  # Closing succeeds even if the connection was already closed or we don't
  # own it. It runs in its own process: closing a TLS socket waits up to 5 s
  # for the peer's close_notify, and this callback runs in the pool process,
  # where that wait would hold up every checkout.
  def terminate_worker(_reason, conn, %__MODULE__.State{} = pool_state) do
    spawn(fn -> Conn.close(conn) end)
    {:ok, pool_state}
  end

  @impl NimblePool
  def handle_cancelled(:checked_out, %__MODULE__.State{} = pool_state) do
    %__MODULE__.State{metric_ref: metric_ref} = pool_state
    PoolMetrics.maybe_add(metric_ref, :in_use_connections, -1)
    {:ok, update_activity_info(:checkin, pool_state)}
  end

  def handle_cancelled(:queued, _pool_state), do: :ok

  @impl NimblePool
  def terminate_pool(_reason, %{state: %__MODULE__.State{} = state}) do
    Finch.Pool.cleanup(state.registry, Finch.Pool.to_name(state.pool), state.metric_ref)
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

  defp init_activity_info() do
    %{in_use_count: 0, last_checkout_ts: System.monotonic_time(:millisecond)}
  end

  defp update_activity_info(
         _checkout_or_checkin,
         %__MODULE__.State{activity_info: nil} = pool_state
       ) do
    pool_state
  end

  defp update_activity_info(:checkout, %__MODULE__.State{} = pool_state) do
    update_in(pool_state.activity_info, fn %{in_use_count: count} ->
      %{in_use_count: count + 1, last_checkout_ts: System.monotonic_time(:millisecond)}
    end)
  end

  defp update_activity_info(:checkin, %__MODULE__.State{} = pool_state) do
    update_in(pool_state.activity_info.in_use_count, &max(&1 - 1, 0))
  end

  defp idle_time_left(%__MODULE__.State{activity_info: activity_info, opts: opts}) do
    max_idle_time = opts.pool_max_idle_time

    if activity_info.in_use_count > 0 do
      max_idle_time
    else
      idle_time = System.monotonic_time(:millisecond) - activity_info.last_checkout_ts
      max(max_idle_time - idle_time, 0)
    end
  end

  defp revive(%__MODULE__.State{idle_stop: nil} = pool_state), do: pool_state

  defp revive(%__MODULE__.State{} = pool_state) do
    %__MODULE__.State{registry: registry, pool: pool, opts: opts} = pool_state
    {:ok, _} = Registry.register(registry, Finch.Pool.to_name(pool), __MODULE__)
    NimblePool.pool_cast_after(self(), :check_idle, opts.pool_max_idle_time)
    now = System.monotonic_time(:millisecond)
    pool_state = put_in(pool_state.activity_info.last_checkout_ts, now)
    %{pool_state | idle_stop: nil}
  end
end
