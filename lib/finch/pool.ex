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

          with {:ok, conn} <- Conn.connect(conn),
               {:ok, conn, response} <- Conn.request(conn, req, receive_timeout) do
            {{:ok, response}, transfer_if_open(conn, pool)}
          else
            {:error, conn, error} ->
              {{:error, error}, transfer_if_open(conn, pool)}
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
    {:ok, Conn.new(scheme, host, port, opts, self()), pool_state}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _, %{mint: nil} = conn) do
    {:ok, {conn, self()}, conn}
  end

  def handle_checkout(:checkout, {pid, _}, conn) do
    with {:ok, conn} <- Conn.set_mode(conn, :passive),
         {:ok, conn} <- Conn.transfer(conn, pid) do
      {:ok, {conn, self()}, conn}
    else
      {:error, _error} ->
        {:remove, :closed}
    end
  end

  @impl NimblePool
  def handle_checkin(conn, _from, _old_conn) do
    with true <- Conn.open?(conn),
         {:ok, conn} <- Conn.set_mode(conn, :active) do
      {:ok, conn}
    else
      _ ->
        {:remove, :closed}
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
  # On terminate, effectively close it.
  # This will succeed even if it was already closed or if we don't own it.
  def terminate_worker(_reason, conn, pool_state) do
    Conn.close(conn)
    {:ok, pool_state}
  end

  defp transfer_if_open(conn, pid) do
    if Conn.open?(conn) do
      {:ok, conn} = Conn.transfer(conn, pid)
      conn
    else
      conn
    end
  end
end
