defmodule Finch.Conn do
  @moduledoc false

  alias Finch.Response
  alias Mint.HTTP
  alias Finch.Telemetry

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

  def connect(%{mint: mint} = conn) when not is_nil(mint) do
    meta = %{
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port,
    }
    Telemetry.event(:reused_connection, %{}, meta)
    conn
  end

  def connect(conn) do
    meta = %{
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port,
    }
    start_time = Telemetry.start(:connect, meta)

    # TODO add back-off
    with {:ok, mint} <- HTTP.connect(conn.scheme, conn.host, conn.port, conn.opts),
         {:ok, mint} <- HTTP.controlling_process(mint, conn.parent) do
      Telemetry.stop(:connect, start_time, meta)
      %{conn | mint: mint}
    else
      {:error, error} ->
        meta = Map.put(meta, :error, error)
        Telemetry.stop(:connect, start_time, meta)
        conn
    end
  end

  def open?(%{mint: nil}), do: false
  def open?(%{mint: mint}), do: HTTP.open?(mint)

  def set_mode(%{mint: nil}, _), do: {:error, "Connection is dead"}

  def set_mode(conn, mode) when mode in [:active, :passive] do
    case HTTP.set_mode(conn.mint, mode) do
      {:ok, mint} -> {:ok, %{conn | mint: mint}}
      _ -> {:error, "Connection is dead"}
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
    end
  end

  def request(%{mint: nil} = conn, _, _), do: {:error, conn, "Could not connect"}

  def request(conn, req, receive_timeout) do
    full_path = request_path(req)

    metadata = %{
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port,
      path: full_path
    }
    start_time = Telemetry.start(:request, metadata)

    case HTTP.request(conn.mint, req.method, full_path, req.headers, req.body) do
      {:ok, mint, ref} ->
        Telemetry.stop(:request, start_time, metadata)
        receive_response(%{conn | mint: mint}, ref, receive_timeout, metadata)

      {:error, mint, error} ->
        metadata = Map.put(metadata, :error, error)
        Telemetry.stop(:request, start_time, metadata)
        {:error, %{conn | mint: mint}, error}
    end
  end

  def close(%{mint: nil} = conn), do: conn

  def close(conn) do
    {:ok, mint} = HTTP.close(conn.mint)
    %{conn | mint: mint}
  end

  defp request_path(%{path: path, query: nil}), do: path
  defp request_path(%{path: path, query: query}), do: "#{path}?#{query}"

  defp receive_response(conn, ref, timeout, metadata) do
    start_time = Telemetry.start(:response, metadata)

    case receive_response([], conn, ref, %Response{}, timeout) do
      {:ok, _, _}=resp ->
        Telemetry.stop(:response, start_time, metadata)
        resp

      {:error, _, error}=resp ->
        metadata = Map.put(metadata, :error, error)
        Telemetry.stop(:response, start_time, metadata)
        resp
    end
  end

  defp receive_response([], conn, ref, response, timeout) do
    case HTTP.recv(conn.mint, 0, timeout) do
      {:ok, mint, entries} ->
        receive_response(entries, %{conn | mint: mint}, ref, response, timeout)

      {:error, mint, error, _responses} ->
        {:error, %{conn | mint: mint}, error}
    end
  end

  defp receive_response([entry | entries], conn, ref, response, timeout) do
    case entry do
      {:status, ^ref, value} ->
        response = %{response | status: value}
        receive_response(entries, conn, ref, response, timeout)

      {:headers, ^ref, value} ->
        response = %{response | headers: value}
        receive_response(entries, conn, ref, response, timeout)

      {:data, ^ref, data} ->
        response = append_data_chunk(response, data)
        receive_response(entries, conn, ref, response, timeout)

      {:done, ^ref} ->
        {:ok, conn, response}

      {:error, ^ref, error} ->
        {:error, conn, error}
    end
  end

  defp append_data_chunk(%Response{body: nil} = response, data_chunk) do
    %{response | body: data_chunk}
  end

  defp append_data_chunk(%Response{body: body} = response, data_chunk) when is_binary(body) do
    %{response | body: body <> data_chunk}
  end
end
