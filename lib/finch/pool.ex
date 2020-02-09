defmodule Finch.Pool do
  @moduledoc false
  @behaviour NimblePool

  alias Finch.Conn

  defp via_tuple(host) do
    {:via, Registry, {Finch.PoolRegistry, host}}
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
    }
  end

  def start_link(shp) do
    opts = [worker: {__MODULE__, shp}, name: via_tuple(shp)]
    NimblePool.start_link(opts)
  end

  def request(pool, req, opts \\ []) do
    pool_timeout = Keyword.get(opts, :pool_timeout, 5000)
    receive_timeout = Keyword.get(opts, :receive_timeout, 15000)

    NimblePool.checkout!(pool, :checkout, fn {conn, pool} ->
      try do
        conn = Conn.connect(conn)
        result = Conn.request(conn, req, receive_timeout)
        {:ok, conn} = Conn.transfer(conn, pool)
        {result, conn}
      catch
        kind, reason ->
          _ = Conn.close(conn)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end, pool_timeout)
  end

  @impl NimblePool
  def init({scheme, host, port}) do
    parent = self()

    async = fn ->
      Conn.connect(Conn.new(scheme, host, port, [], parent))
    end

    {:async, async}
  end

  @impl NimblePool
  # Transfer the conn to the caller.
  # If we lost the connection, then we remove it to try again.
  def handle_checkout(:checkout, {pid, _}, conn) do
    case Conn.transfer(conn, pid) do
      {:ok, conn} ->
        {:ok, {conn, self()}, conn}

      _ ->
        {:remove, :closed}
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
  def terminate(_reason, conn) do
    Conn.close(conn)
  end
end
