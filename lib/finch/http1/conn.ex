defmodule Finch.Conn do
  @moduledoc false

  alias Mint.HTTP
  alias Finch.Telemetry

  def new(scheme, host, port, opts, parent) do
    %{
      scheme: scheme,
      host: host,
      port: port,
      opts: opts.conn_opts,
      parent: parent,
      last_checkin: System.monotonic_time(),
      mint: nil
    }
  end

  def connect(%{mint: mint} = conn) when not is_nil(mint) do
    meta = %{
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port
    }

    Telemetry.event(:reused_connection, %{}, meta)
    {:ok, conn}
  end

  def connect(conn) do
    meta = %{
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port
    }

    start_time = Telemetry.start(:connect, meta)
    conn_opts = Keyword.merge(conn.opts, mode: :passive)

    case HTTP.connect(conn.scheme, conn.host, conn.port, conn_opts) do
      {:ok, mint} ->
        Telemetry.stop(:connect, start_time, meta)
        {:ok, %{conn | mint: mint}}

      {:error, error} ->
        meta = Map.put(meta, :error, error)
        Telemetry.stop(:connect, start_time, meta)
        {:error, conn, :connect, error}
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
    with {:ok, mint, responses} <- HTTP.stream(conn.mint, message) do
      {:ok, %{conn | mint: mint}, responses}
    end
  end

  def transfer(%{mint: nil}, _), do: {:error, "Connection is dead"}

  def transfer(conn, pid) do
    with {:ok, _mint} <- HTTP.controlling_process(conn.mint, pid) do
      # HTTP.controlling_process causes a side-effect, it doesn't actually change
      # the conn, so we can ignore the value returned above.
      :ok
    end
  end

  def request(%{mint: nil} = conn, _, _, _, _), do: {:error, conn, :request_mint_nil, "Could not connect"}

  def request(conn, req, acc, fun, receive_timeout) do
    full_path = Finch.Request.request_path(req)

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
        start_time = Telemetry.start(:response, metadata)

        case receive_response([], acc, fun, mint, ref, receive_timeout) do
          {:ok, mint, acc} ->
            Telemetry.stop(:response, start_time, metadata)
            {:ok, %{conn | mint: mint}, acc}

          {:error, mint, error} ->
            metadata = Map.put(metadata, :error, error)
            Telemetry.stop(:response, start_time, metadata)
            {:error, %{conn | mint: mint}, :request_receive_response, error}
        end

      {:error, mint, error} ->
        metadata = Map.put(metadata, :error, error)
        Telemetry.stop(:request, start_time, metadata)
        {:error, %{conn | mint: mint}, :request_send_request, error}
    end
  end

  def close(%{mint: nil} = conn), do: conn

  def close(conn) do
    {:ok, mint} = HTTP.close(conn.mint)
    %{conn | mint: mint}
  end

  defp receive_response([], acc, fun, mint, ref, timeout) do
    case HTTP.recv(mint, 0, timeout) do
      {:ok, mint, entries} ->
        receive_response(entries, acc, fun, mint, ref, timeout)

      {:error, mint, error, _responses} ->
        {:error, mint, error}
    end
  end

  defp receive_response([entry | entries], acc, fun, mint, ref, timeout) do
    case entry do
      {:status, ^ref, value} ->
        receive_response(entries, fun.({:status, value}, acc), fun, mint, ref, timeout)

      {:headers, ^ref, value} ->
        receive_response(entries, fun.({:headers, value}, acc), fun, mint, ref, timeout)

      {:data, ^ref, value} ->
        receive_response(entries, fun.({:data, value}, acc), fun, mint, ref, timeout)

      {:done, ^ref} ->
        {:ok, mint, acc}

      {:error, ^ref, error} ->
        {:error, mint, error}
    end
  end
end
