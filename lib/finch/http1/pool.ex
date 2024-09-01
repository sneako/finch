defmodule Finch.HTTP1.Pool do
  @moduledoc false
  @behaviour NimblePool
  @behaviour Finch.Pool

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

  defp spawn_holder(pool, req, name, opts) do
    metadata = %{request: req, pool: pool, name: name}
    fail_safe_timeout = Keyword.get(opts, :fail_safe_timeout, 15 * 60_000)
    stop_notify = Keyword.get(opts, :stop_notify, nil)
    pool_timeout = Keyword.get(opts, :pool_timeout, 5_000)

    owner = self()
    ref = make_ref()

    start_time = Telemetry.start(:queue, metadata)

    holder =
      spawn_link(fn ->
        try do
          NimblePool.checkout!(
            pool,
            :checkout,
            fn from, {state, conn, idle_time} ->
              if fail_safe_timeout != :infinity do
                Process.send_after(self(), :fail_safe_timeout, fail_safe_timeout)
              end

              Telemetry.stop(:queue, start_time, metadata, %{idle_time: idle_time})

              return =
                case Conn.connect(conn, name) do
                  {:ok, conn} ->
                    send(owner, {ref, :ok, {conn, idle_time}})

                    receive do
                      {^ref, :stop, conn} ->
                        with :closed <- transfer_if_open(conn, state, from) do
                          {:ok, :closed}
                        end

                      :fail_safe_timeout ->
                        Conn.close(conn)
                        {:ok, :closed}
                    end

                  {:error, conn, error} ->
                    {{:error, error}, transfer_if_open(conn, state, from)}
                end

              with {to, message} <- stop_notify do
                send(to, message)
              end

              return
            end,
            pool_timeout
          )
        rescue
          x ->
            IO.inspect(x)
        catch
          :exit, data ->
            Telemetry.exception(:queue, start_time, :exit, data, __STACKTRACE__, metadata)
            send(owner, {ref, :exit, {data, __STACKTRACE__}})
        end
      end)

    receive do
      {^ref, :ok, {conn, idle_time}} ->
        Process.link(holder)
        {:ok, holder, ref, conn, idle_time}

      {^ref, :error, reason} ->
        {:error, reason}

      {^ref, :exit, data_trace} ->
        {data, trace} = data_trace

        case data do
          {:timeout, {NimblePool, :checkout, _affected_pids}} ->
            # Provide helpful error messages for known errors
            reraise(
              """
              Finch was unable to provide a connection within the timeout due to excess queuing \
              for connections. Consider adjusting the pool size, count, timeout or reducing the \
              rate of requests if it is possible that the downstream service is unable to keep up \
              with the current rate.
              """,
              trace
            )

          _ ->
            exit(data)
        end
    after
      pool_timeout ->
        # Cleanup late messages
        receive do
          {^ref, _, _} -> :ok
        after
          0 -> :ok
        end

        raise "Has not received message from pool yet"
    end
  rescue
    x ->
      IO.inspect({x, __STACKTRACE__})
  end

  @impl Finch.Pool
  def stream(pool, req, name, opts) do
    receive_timeout = Keyword.get(opts, :receive_timeout, 15_000)
    request_timeout = Keyword.get(opts, :request_timeout, 30_000)

    stream =
      fn
        {:cont, acc}, function ->
          case spawn_holder(pool, req, name, opts) do
            {:ok, holder, ref, conn, idle_time} ->
              function = fn x, y ->
                with {:suspend, acc} <- function.(x, y) do
                  {:__finch_suspend__, acc, {holder, ref, conn}}
                end
              end

              try do
                with {:ok, conn, acc} <-
                       Conn.request(
                         conn,
                         req,
                         acc,
                         function,
                         name,
                         receive_timeout,
                         request_timeout,
                         idle_time
                       ) do
                  send(holder, {ref, :stop, conn})
                  {:done, acc}
                else
                  {:error, conn, error} ->
                    send(holder, {ref, :stop, conn})
                    raise error

                  {:suspended, _, _} = suspended ->
                    suspended
                end
              catch
                class, reason ->
                  send(holder, {ref, :stop, conn})
                  :erlang.raise(class, reason, __STACKTRACE__)
              end

            other ->
              other
          end

        {:halt, acc}, _function ->
          {:halted, acc}
      end

    {:ok, stream}
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

          with {:ok, conn} <- Conn.connect(conn, name),
               {:ok, conn, acc} <-
                 Conn.request(
                   conn,
                   req,
                   acc,
                   fun,
                   name,
                   receive_timeout,
                   request_timeout,
                   idle_time
                 ) do
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
          {:error, error} -> send(owner, {request_ref, {:error, error}})
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
    {:ok, {registry, shp, pool_idx, metric_ref, opts}}
  end

  @impl NimblePool
  def init_worker({_name, {scheme, host, port}, _pool_idx, _metric_ref, opts} = pool_state) do
    {:ok, Conn.new(scheme, host, port, opts, self()), pool_state}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _, %{mint: nil} = conn, pool_state) do
    {_name, _shp, _pool_idx, metric_ref, _opts} = pool_state
    idle_time = System.monotonic_time() - conn.last_checkin
    PoolMetrics.maybe_add(metric_ref, in_use_connections: 1)
    {:ok, {:fresh, conn, idle_time}, conn, pool_state}
  end

  def handle_checkout(:checkout, _from, conn, pool_state) do
    idle_time = System.monotonic_time() - conn.last_checkin
    {_name, {scheme, host, port}, _pool_idx, metric_ref, _opts} = pool_state

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
  def handle_checkin(checkin, _from, _old_conn, pool_state) do
    {_name, _shp, _pool_idx, metric_ref, _opts} = pool_state
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
    {_name, {scheme, host, port}, _pool_idx, _metric_ref, _opts} = pool_state

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

  @impl NimblePool
  def handle_cancelled(:checked_out, pool_state) do
    {_name, _shp, _pool_idx, metric_ref, _opts} = pool_state
    PoolMetrics.maybe_add(metric_ref, in_use_connections: -1)
    :ok
  end

  def handle_cancelled(:queued, _pool_state), do: :ok

  defp transfer_if_open(conn, state, {pid, _} = from) do
    transfer_if_open(conn, state, from, pid)
  end

  defp transfer_if_open(conn, state, from, pid) do
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
