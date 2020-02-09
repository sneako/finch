defmodule Finch.Conn do
  @moduledoc false

  alias Mint.HTTP

  def new(scheme, host, port, opts, parent) do
    %{
      scheme: scheme,
      host: host,
      port: port,
      opts: opts,
      parent: parent,
      mint: nil,
    }
  end

  def connect(%{mint: mint}=conn) when not is_nil(mint), do: conn
  def connect(conn) do
    with {:ok, mint_conn} <- HTTP.connect(conn.scheme, conn.host, conn.port, conn.opts),
         {:ok, mint_conn} <- HTTP.controlling_process(mint_conn, conn.parent) do
      %{conn | mint: mint_conn}
    else
      _ ->
        conn
    end
  end

  def set_mode(conn, mode) when mode in [:active, :passive] do
    with true <- conn.mint != nil,
         {:ok, mint} <- HTTP.set_mode(conn.mint, mode) do
      {:ok, %{conn | mint: mint}}
    else
      _ ->
        {:error, "Connection is dead"}
    end
  end

  def stream(%{mint: nil}, _), do: {:error, "Connection is dead"}
  def stream(conn, message) do
    HTTP.stream(conn.mint, message)
  end

  def transfer(%{mint: nil}=conn, _pid), do: {:ok, conn}
  def transfer(conn, pid) do
    with {:ok, mint} <- HTTP.set_mode(conn.mint, :passive),
         {:ok, mint} <- HTTP.controlling_process(mint, pid) do
      {:ok, %{conn | mint: mint}}
    end
  end

  def request(%{mint: nil}, _, _), do: {:error, "Could not connect"}
  def request(conn, req, receive_timeout) do
    with {:ok, mint, ref} <- HTTP.request(conn.mint, req.method, req.path, req.headers, req.body) do
      receive_response([], mint, ref, %{}, receive_timeout)
    end
  end

  def close(%{mint: nil}=conn), do: conn
  def close(conn) do
    {:ok, mint} = HTTP.close(conn.mint)
    %{conn | mint: mint}
  end

  defp receive_response([], mint, ref, response, timeout) do
    {:ok, mint, entries} = HTTP.recv(mint, 0, timeout)
    receive_response(entries, mint, ref, response, timeout)
  end

  defp receive_response([entry | entries], mint, ref, response, timeout) do
    case entry do
      {kind, ^ref, value} when kind in [:status, :headers] ->
        response = Map.put(response, kind, value)
        receive_response(entries, mint, ref, response, timeout)

      {:data, ^ref, data} ->
        response = Map.update(response, :data, data, &(&1 <> data))
        receive_response(entries, mint, ref, response, timeout)

      {:done, ^ref} ->
        {:ok, mint, response}

      {:error, ^ref, error} ->
        {:error, mint, error}
    end
  end
end

