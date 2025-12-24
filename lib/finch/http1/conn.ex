defmodule Finch.HTTP1.Conn do
  @moduledoc false

  alias Finch.SSL
  alias Finch.Telemetry

  def new(scheme, host, port, opts, parent) do
    %{
      scheme: scheme,
      host: host,
      port: port,
      opts: opts.conn_opts,
      parent: parent,
      last_checkin: System.monotonic_time(),
      max_idle_time: opts.conn_max_idle_time,
      mint: nil
    }
  end

  def connect(%{mint: mint} = conn, name) when not is_nil(mint) do
    meta = %{
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port,
      name: name
    }

    Telemetry.event(:reused_connection, %{}, meta)
    {:ok, conn}
  end

  def connect(%{mint: nil} = conn, name) do
    meta = %{
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port,
      name: name
    }

    start_time = Telemetry.start(:connect, meta)

    # By default we force HTTP1, but we allow someone to set
    # custom protocols in case they don't know if a connection
    # is HTTP1/HTTP2, but they are fine as treating HTTP2
    # connections has HTTP2.

    conn_opts =
      conn.opts
      |> Keyword.put(:mode, :passive)
      |> Keyword.put_new(:protocols, [:http1])

    case Mint.HTTP.connect(conn.scheme, conn.host, conn.port, conn_opts) do
      {:ok, mint} ->
        Telemetry.stop(:connect, start_time, meta)
        SSL.maybe_log_secrets(conn.scheme, conn_opts, mint)
        {:ok, %{conn | mint: mint}}

      {:error, error} ->
        meta = Map.put(meta, :error, error)
        Telemetry.stop(:connect, start_time, meta)
        {:error, conn, error}
    end
  end

  def transfer(conn, pid) do
    case Mint.HTTP.controlling_process(conn.mint, pid) do
      # Mint.HTTP.controlling_process causes a side-effect, but it doesn't actually
      # change the conn, so we can ignore the value returned above.
      {:ok, _} -> {:ok, conn}
      {:error, error} -> {:error, conn, error}
    end
  end

  def open?(%{mint: nil}), do: false
  def open?(%{mint: mint}), do: Mint.HTTP.open?(mint)

  def idle_time(conn, unit \\ :native) do
    idle_time = System.monotonic_time() - conn.last_checkin

    System.convert_time_unit(idle_time, :native, unit)
  end

  def reusable?(%{max_idle_time: :infinity}, _idle_time), do: true
  def reusable?(%{max_idle_time: max_idle_time}, idle_time), do: idle_time <= max_idle_time

  def set_mode(conn, mode) when mode in [:active, :passive] do
    case Mint.HTTP.set_mode(conn.mint, mode) do
      {:ok, mint} -> {:ok, %{conn | mint: mint}}
      _ -> {:error, "Connection is dead"}
    end
  end

  def discard(%{mint: nil}, _), do: :unknown

  def discard(conn, message) do
    case Mint.HTTP.stream(conn.mint, message) do
      {:ok, mint, _responses} -> {:ok, %{conn | mint: mint}}
      {:error, _, reason, _} -> {:error, reason}
      :unknown -> :unknown
    end
  end

  def request(%{mint: nil} = conn, _, _, _, _, _, _, _), do: {:error, conn, "Could not connect"}

  def request(conn, req, acc, fun, name, receive_timeout, request_timeout, idle_time) do
    request(conn, req, acc, fun, name, receive_timeout, request_timeout, idle_time, nil)
  end

  def request(conn, req, acc, fun, name, receive_timeout, request_timeout, idle_time, update_fun) do
    full_path = Finch.Request.request_path(req)

    metadata = %{request: req, name: name}

    extra_measurements = %{idle_time: idle_time}

    start_time = Telemetry.start(:send, metadata, extra_measurements)

    try do
      case Mint.HTTP.request(
             conn.mint,
             req.method,
             full_path,
             req.headers,
             stream_or_body(req.body)
           ) do
        {:ok, mint, ref} ->
          case maybe_stream_request_body(mint, ref, req.body) do
            {:ok, mint} ->
              maybe_update(update_fun, mint)
              Telemetry.stop(:send, start_time, metadata, extra_measurements)
              start_time = Telemetry.start(:recv, metadata, extra_measurements)
              resp_metadata = %{status: nil, headers: [], trailers: []}
              timeouts = %{receive_timeout: receive_timeout, request_timeout: request_timeout}

              response =
                receive_response(
                  [],
                  acc,
                  fun,
                  mint,
                  ref,
                  timeouts,
                  :headers,
                  resp_metadata,
                  update_fun
                )

              handle_response(response, conn, metadata, start_time, extra_measurements)

            {:error, mint, error} ->
              handle_request_error(
                conn,
                mint,
                error,
                acc,
                metadata,
                start_time,
                extra_measurements
              )
          end

        {:error, mint, error} ->
          handle_request_error(conn, mint, error, acc, metadata, start_time, extra_measurements)
      end
    catch
      kind, error ->
        close(conn)
        Telemetry.exception(:recv, start_time, kind, error, __STACKTRACE__, metadata)
        :erlang.raise(kind, error, __STACKTRACE__)
    end
  end

  defp stream_or_body({:stream, _}), do: :stream
  defp stream_or_body(body), do: body

  defp handle_request_error(conn, mint, error, acc, metadata, start_time, extra_measurements) do
    metadata = Map.put(metadata, :error, error)
    Telemetry.stop(:send, start_time, metadata, extra_measurements)
    {:error, %{conn | mint: mint}, error, acc}
  end

  defp maybe_stream_request_body(mint, ref, {:stream, stream}) do
    with {:ok, mint} <- stream_request_body(mint, ref, stream) do
      Mint.HTTP.stream_request_body(mint, ref, :eof)
    end
  end

  defp maybe_stream_request_body(mint, _, _), do: {:ok, mint}

  defp stream_request_body(mint, ref, stream) do
    Enum.reduce_while(stream, {:ok, mint}, fn
      chunk, {:ok, mint} -> {:cont, Mint.HTTP.stream_request_body(mint, ref, chunk)}
      _chunk, error -> {:halt, error}
    end)
  end

  def close(%{mint: nil} = conn), do: conn

  def close(conn) do
    try do
      {:ok, mint} = Mint.HTTP.close(conn.mint)
      %{conn | mint: mint}
    catch
      _kind, _reason ->
        conn
    end
  end

  defp handle_response(response, conn, metadata, start_time, extra_measurements) do
    case response do
      {:ok, mint, acc, resp_metadata} ->
        metadata = Map.merge(metadata, resp_metadata)
        Telemetry.stop(:recv, start_time, metadata, extra_measurements)
        {:ok, %{conn | mint: mint}, acc}

      {:error, mint, error, acc, resp_metadata} ->
        metadata = Map.merge(metadata, Map.put(resp_metadata, :error, error))
        Telemetry.stop(:recv, start_time, metadata, extra_measurements)
        {:error, %{conn | mint: mint}, error, acc}
    end
  end

  defp receive_response(
         entries,
         acc,
         fun,
         mint,
         ref,
         timeouts,
         fields,
         resp_metadata,
         update_fun
       )

  defp receive_response(
         [{:done, ref} | _],
         acc,
         _fun,
         mint,
         ref,
         _timeouts,
         _fields,
         resp_metadata,
         _update_fun
       ) do
    {:ok, mint, acc, resp_metadata}
  end

  defp receive_response(
         _,
         acc,
         _fun,
         mint,
         _ref,
         timeouts,
         _fields,
         resp_metadata,
         _update_fun
       )
       when timeouts.request_timeout < 0 do
    # Keep the connection open on request timeouts.
    {:error, mint, %Mint.TransportError{reason: :timeout}, acc, resp_metadata}
  end

  defp receive_response(
         [],
         acc,
         fun,
         mint,
         ref,
         timeouts,
         fields,
         resp_metadata,
         update_fun
       ) do
    start_time = System.monotonic_time(:millisecond)

    case Mint.HTTP.recv(mint, 0, timeouts.receive_timeout) do
      {:ok, mint, entries} ->
        maybe_update(update_fun, mint)

        timeouts =
          if is_integer(timeouts.request_timeout) do
            elapsed_time = System.monotonic_time(:millisecond) - start_time
            update_in(timeouts.request_timeout, &(&1 - elapsed_time))
          else
            timeouts
          end

        receive_response(
          entries,
          acc,
          fun,
          mint,
          ref,
          timeouts,
          fields,
          resp_metadata,
          update_fun
        )

      {:error, mint, error, _responses} ->
        {:error, mint, error, acc, resp_metadata}
    end
  end

  defp receive_response(
         [entry | entries],
         acc,
         fun,
         mint,
         ref,
         timeouts,
         fields,
         resp_metadata,
         update_fun
       ) do
    case entry do
      {:status, ^ref, value} ->
        case fun.({:status, value}, acc) do
          {:cont, acc} ->
            receive_response(
              entries,
              acc,
              fun,
              mint,
              ref,
              timeouts,
              fields,
              %{resp_metadata | status: value},
              update_fun
            )

          {:halt, acc} ->
            {:ok, mint} = Mint.HTTP.close(mint)
            {:ok, mint, acc, resp_metadata}

          other ->
            raise ArgumentError, "expected {:cont, acc} or {:halt, acc}, got: #{inspect(other)}"
        end

      {:headers, ^ref, value} ->
        resp_metadata = update_in(resp_metadata, [fields], &(&1 ++ value))

        case fun.({fields, value}, acc) do
          {:cont, acc} ->
            receive_response(
              entries,
              acc,
              fun,
              mint,
              ref,
              timeouts,
              fields,
              resp_metadata,
              update_fun
            )

          {:halt, acc} ->
            {:ok, mint} = Mint.HTTP.close(mint)
            {:ok, mint, acc, resp_metadata}

          other ->
            raise ArgumentError, "expected {:cont, acc} or {:halt, acc}, got: #{inspect(other)}"
        end

      {:data, ^ref, value} ->
        case fun.({:data, value}, acc) do
          {:cont, acc} ->
            receive_response(
              entries,
              acc,
              fun,
              mint,
              ref,
              timeouts,
              :trailers,
              resp_metadata,
              update_fun
            )

          {:halt, acc} ->
            {:ok, mint} = Mint.HTTP.close(mint)
            {:ok, mint, acc, resp_metadata}

          other ->
            raise ArgumentError, "expected {:cont, acc} or {:halt, acc}, got: #{inspect(other)}"
        end

      {:error, ^ref, error} ->
        {:error, mint, error, acc, resp_metadata}

      {:done, _other_ref} ->
        # Ignore responses for other refs (e.g., a previous request that timed out).
        receive_response(entries, acc, fun, mint, ref, timeouts, fields, resp_metadata, update_fun)

      {kind, _other_ref, _value} when kind in [:status, :headers, :data, :error] ->
        # Ignore responses for other refs (e.g., a previous request that timed out).
        receive_response(entries, acc, fun, mint, ref, timeouts, fields, resp_metadata, update_fun)
    end
  end

  def drain(%{mint: nil} = conn, _timeout), do: {:ok, conn}

  def drain(conn, timeout) do
    deadline =
      case timeout do
        :infinity -> :infinity
        ms when is_integer(ms) and ms >= 0 -> System.monotonic_time(:millisecond) + ms
      end

    case drain_mint(conn.mint, deadline) do
      {:ok, mint} -> {:ok, %{conn | mint: mint}}
      {:timeout, mint} -> {:timeout, %{conn | mint: mint}}
      {:error, mint, reason} -> {:error, %{conn | mint: mint}, reason}
    end
  end

  defp drain_mint(mint, deadline) do
    if Mint.HTTP.open_request_count(mint) == 0 do
      {:ok, mint}
    else
      timeout =
        case deadline do
          :infinity ->
            :infinity

          _ ->
            remaining = deadline - System.monotonic_time(:millisecond)
            if remaining > 0, do: remaining, else: 0
        end

      if timeout == 0 do
        {:timeout, mint}
      else
        case Mint.HTTP.recv(mint, 0, timeout) do
          {:ok, mint, _entries} ->
            drain_mint(mint, deadline)

          {:error, mint, %Mint.TransportError{reason: :ealready}, _responses} ->
            Process.sleep(min(5, timeout))
            drain_mint(mint, deadline)

          {:error, mint, reason, _responses} ->
            {:error, mint, reason}
        end
      end
    end
  end

  defp maybe_update(nil, _mint), do: :ok
  defp maybe_update(fun, mint), do: fun.(mint)
end
