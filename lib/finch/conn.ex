defmodule Finch.Conn do
  @moduledoc false

  alias Mint.HTTP

  require Logger

  def new(scheme, host, port, opts, parent) do
    %{
      scheme: scheme,
      host: host,
      port: port,
      opts: opts,
      parent: parent,
      mint: nil
    }
  end

  def connect(%{mint: mint} = conn) when not is_nil(mint), do: conn

  def connect(conn) do
    # TODO add back-off
    with {:ok, mint} <- HTTP.connect(conn.scheme, conn.host, conn.port, conn.opts),
         {:ok, mint} <- HTTP.controlling_process(mint, conn.parent) do
      %{conn | mint: mint}
    else
      error ->
        Logger.error(fn -> "Connection Error: #{inspect error}" end)
        conn
    end
  end

  def set_mode(%{mint: nil}, _), do: {:error, "Connection is dead"}

  def set_mode(conn, mode) when mode in [:active, :passive] do
    case HTTP.set_mode(conn.mint, mode) do
      {:ok, mint} -> {:ok, %{conn | mint: mint}}
      error ->
        Logger.error(fn -> "Error setting mode: #{inspect error}" end)
        {:error, "Connection is dead"}
    end
  end

  def stream(%{mint: nil}, _), do: {:error, "Connection is dead"}

  def stream(conn, message) do
    HTTP.stream(conn.mint, message)
  end

  def transfer(%{mint: nil}, _), do: {:error, "Connection is dead"}

  def transfer(conn, pid) do
    with {:ok, mint} <- HTTP.set_mode(conn.mint, :passive),
         {:ok, mint} <- HTTP.controlling_process(mint, pid) do
      {:ok, %{conn | mint: mint}}
    else
      error ->
        Logger.error(fn -> "Could not transfer connection: #{inspect error}" end)
        error
    end
  end

  def request(%{mint: nil} = conn, _, _), do: {:error, conn, "Could not connect"}

  def request(conn, req, receive_timeout) do
    with {:ok, mint, ref} <- HTTP.request(conn.mint, req.method, req.path, req.headers, req.body) do
      receive_response([], %{conn | mint: mint}, ref, %{}, receive_timeout)
    else
      {:error, mint, error} ->
        Logger.error(fn -> "Request error: #{inspect error}" end)
        {:error, %{conn | mint: mint}, error}
    end
  end

  def close(%{mint: nil} = conn), do: conn

  def close(conn) do
    {:ok, mint} = HTTP.close(conn.mint)
    %{conn | mint: mint}
  end

  defp receive_response([], conn, ref, response, timeout) do
    with {:ok, mint, entries} <- HTTP.recv(conn.mint, 0, timeout) do
      receive_response(entries, %{conn | mint: mint}, ref, response, timeout)
    else
      {:error, mint, error, _responses} ->
        Logger.error(fn -> "error receiving response: #{inspect error}" end)
        {:error, %{conn | mint: mint}, error}
    end
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
        Logger.error(fn -> "error processing response: #{inspect error}" end)
        {:error, conn, error}
    end
  end
end
