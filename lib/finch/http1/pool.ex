defmodule Finch.HTTP1.Pool do
  @moduledoc false
  @behaviour NimblePool
  @behaviour Finch.Pool

  alias Finch.Conn
  alias Finch.Telemetry

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link({shp, registry_name, pool_config}) do
    state = %{
      shp: shp,
      conn_opts: pool_config.conn_opts,
      registry_value: pool_config.registry_value
    }

    opts = [worker: {__MODULE__, {registry_name, state}}, pool_size: pool_config.size]
    NimblePool.start_link(opts)
  end

  def request(pool, req, opts) do
    pool_timeout = Keyword.get(opts, :pool_timeout, 5_000)
    receive_timeout = Keyword.get(opts, :receive_timeout, 15_000)

    metadata = %{
      scheme: req.scheme,
      host: req.host,
      port: req.port,
      pool: pool
    }

    start_time = Telemetry.start(:queue, metadata)

    try do
      NimblePool.checkout!(
        pool,
        :checkout,
        fn from, {conn, idle_time} ->
          Telemetry.stop(:queue, start_time, metadata, %{idle_time: idle_time})

          with {:ok, conn} <- Conn.connect(conn),
               {:ok, conn, response} <- Conn.request(conn, req, receive_timeout) do
            {{:ok, response}, transfer_if_open(conn, from)}
          else
            {:error, conn, error} ->
              {{:error, error}, transfer_if_open(conn, from)}
          end
        end,
        pool_timeout
      )
    catch
      :exit, data ->
        Telemetry.exception(:queue, start_time, :exit, data, System.stacktrace(), metadata)
        exit(data)
    end
  end

  @impl NimblePool
  def init_pool({registry, state}) do
    {:ok, _} = Registry.register(registry, state.shp, state.registry_value)
    {:ok, state}
  end

  @impl NimblePool
  def init_worker(%{shp: {scheme, host, port}} = pool_state) do
    {:ok, Conn.new(scheme, host, port, pool_state.conn_opts, self()), pool_state}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _, %{mint: nil} = conn, pool_state) do
    idle_time = System.monotonic_time() - conn.last_checkin
    {:ok, {conn, idle_time}, conn, pool_state}
  end

  def handle_checkout(:checkout, {pid, _}, conn, pool_state) do
    idle_time = System.monotonic_time() - conn.last_checkin

    with {:ok, conn} <- Conn.set_mode(conn, :passive),
         :ok <- Conn.transfer(conn, pid) do
      {:ok, {conn, idle_time}, conn, pool_state}
    else
      {:error, _error} ->
        {:remove, :closed, pool_state}
    end
  end

  @impl NimblePool
  def handle_checkin(state, _from, conn, pool_state) do
    with :prechecked <- state,
         {:ok, conn} <- Conn.set_mode(conn, :active) do
      {:ok, %{conn | last_checkin: System.monotonic_time()}, pool_state}
    else
      _ ->
        {:remove, :closed, pool_state}
    end
  end

  @impl NimblePool
  def handle_info(message, conn) do
    case Conn.stream(conn, message) do
      {:ok, conn, _} -> {:ok, conn}
      :unknown -> {:ok, conn}
      {:error, _mint, _error, _responses} -> {:remove, :closed}
      {:error, _error} -> {:remove, :closed}
    end
  end

  @impl NimblePool
  def handle_enqueue(command, %{registry_value: %{strategy: strategy} = config} = pool_state) do
    strategy.handle_enqueue(config)
    {:ok, command, pool_state}
  end

  @impl NimblePool
  # On terminate, effectively close it.
  # This will succeed even if it was already closed or if we don't own it.
  def terminate_worker(_reason, conn, pool_state) do
    Conn.close(conn)
    {:ok, pool_state}
  end

  defp transfer_if_open(conn, {pid, _} = from) do
    if Conn.open?(conn) do
      NimblePool.precheckin(from, conn)

      case Conn.transfer(conn, pid) do
        :ok -> conn
        {:error, _} -> Conn.close(conn)
      end

      :prechecked
    else
      :closed
    end
  end
end
