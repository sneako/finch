defmodule Finch.Pool do
  @moduledoc false
  @behaviour NimblePool

  alias Finch.Conn
  alias Finch.Telemetry

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link({shp, registry_name, pool_size, conn_opts}) do
    opts = [worker: {__MODULE__, {registry_name, shp, conn_opts}}, pool_size: pool_size]
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
        fn {conn, pool} ->
          Telemetry.stop(:queue, start_time, metadata)
          conn = Conn.connect(conn)

          case Conn.request(conn, req, receive_timeout) do
            {:ok, conn, response} ->
              {{:ok, response}, transfer_conn(conn, pool)}

            {:error, conn, error} ->
              {{:error, error}, conn}
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
  def init_pool({registry, shp, _} = pool_state) do
    {:ok, _} = Registry.register(registry, shp, [])
    {:ok, pool_state}
  end

  @impl NimblePool
  def init_worker({_, {scheme, host, port}, opts} = pool_state) do
    parent = self()

    async = fn ->
      conn = Conn.new(scheme, host, port, opts, parent)
      Conn.connect(conn)
    end

    {:async, async, pool_state}
  end

  @impl NimblePool
  # Transfer the conn to the caller.
  # If we lost the connection, then we remove it to try again.
  def handle_checkout(:checkout, {pid, _}, conn) do
    case Conn.transfer(conn, pid) do
      {:ok, conn} -> {:ok, {conn, self()}, conn}
      _ -> {:remove, :closed}
    end
  end

  @impl NimblePool
  def handle_checkin(conn, _from, _old_conn) do
    case Conn.set_mode(conn, :active) do
      {:ok, conn} -> {:ok, conn}
      {:error, _} -> {:remove, :closed}
    end
  end

  @impl NimblePool
  def handle_info(message, conn) do
    case Conn.stream(conn, message) do
      {:ok, _, _} -> {:ok, conn}
      {:error, _, _, _} -> {:remove, :closed}
      {:error, _} -> {:remove, :closed}
      :unknown -> {:ok, conn}
    end
  end

  @impl NimblePool
  # On terminate, effectively close it.
  # This will succeed even if it was already closed or if we don't own it.
  def terminate_worker(_reason, conn, pool_state) do
    Conn.close(conn)
    {:ok, pool_state}
  end

  defp transfer_conn(conn, pid) do
    if Conn.open?(conn) do
      {:ok, conn} = Conn.transfer(conn, pid)
      conn
    else
      conn
    end
  end
end
