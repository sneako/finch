defmodule Finch.Pool do
  @moduledoc false
  @behaviour NimblePool

  defp via_tuple(host) do
    {:via, Registry, {Finch.PoolRegistry, host}}
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
    }
  end

  def start_link({scheme, host, port}) do
    opts = [worker: {__MODULE__, {scheme, host, port}}, name: via_tuple(host)]
    NimblePool.start_link(opts)
  end

  def request(pool, req, opts \\ []) do
    pool_timeout = Keyword.get(opts, :pool_timeout, 5000)
    receive_timeout = Keyword.get(opts, :receive_timeout, 15000)

    NimblePool.checkout!(pool, :checkout, fn {conn, pool} ->
      try do
        {kind, conn, result_or_error} =
          with {:ok, conn, ref} <- Mint.HTTP.request(conn, req.method, req.path, req.headers, req.body) do
            receive_response([], conn, ref, %{}, receive_timeout)
          end

        {:ok, conn} = Mint.HTTP.controlling_process(conn, pool)
        {{kind, result_or_error}, conn}
      catch
        kind, reason ->
          _ = Mint.HTTP.close(conn)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end, pool_timeout)
  end

  defp receive_response([], conn, ref, response, timeout) do
    {:ok, conn, entries} = Mint.HTTP.recv(conn, 0, timeout)
    receive_response(entries, conn, ref, response, timeout)
  end

  defp receive_response([entry | entries], conn, ref, response, timeout) do
    case entry do
      {kind, ^ref, value} when kind in [:status, :headers] ->
        response = Map.put(response, kind, value)
        receive_response(entries, conn, ref, response, timeout)

      {:data, ^ref, data} ->
        response = Map.update(response, :data, data, &(&1 <> data))
        receive_response(entries, conn, ref, response, timeout)

      {:done, ^ref} ->
        {:ok, conn, response}

      {:error, ^ref, error} ->
        {:error, conn, error}
    end
  end

  @impl NimblePool
  def init({scheme, host, port}) do
    parent = self()

    async = fn ->
      case Mint.HTTP.connect(scheme, host, port, []) do
        {:ok, conn} ->
          {:ok, conn} = Mint.HTTP.controlling_process(conn, parent)
          conn

        {:
      end
    end

    {:async, async}
  end

  @impl NimblePool
  # Transfer the conn to the caller.
  # If we lost the connection, then we remove it to try again.
  def handle_checkout(:checkout, {pid, _}, conn) do
    with {:ok, conn} <- Mint.HTTP.set_mode(conn, :passive),
         {:ok, conn} <- Mint.HTTP.controlling_process(conn, pid) do
      {:ok, {conn, self()}, conn}
    else
      _ -> {:remove, :closed}
    end
  end

  @impl NimblePool
  # We got it back.
  def handle_checkin(conn, _from, _old_conn) do
    case Mint.HTTP.set_mode(conn, :active) do
      {:ok, conn} -> {:ok, conn}
      {:error, _} -> {:remove, :closed}
    end
  end

  @impl NimblePool
  # If it is closed, drop it.
  def handle_info(message, conn) do
    case Mint.HTTP.stream(conn, message) do
      {:ok, _, _} -> {:ok, conn}
      {:error, _, _, _} -> {:remove, :closed}
      :unknown -> {:ok, conn}
    end
  end

  @impl NimblePool
  # On terminate, effectively close it.
  # This will succeed even if it was already closed or if we don't own it.
  def terminate(_reason, conn) do
    Mint.HTTP.close(conn)
  end
end
