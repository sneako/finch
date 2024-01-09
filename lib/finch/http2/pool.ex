defmodule Finch.HTTP2.Pool do
  @moduledoc false

  @behaviour :gen_statem
  @behaviour Finch.Pool

  alias Mint.HTTP2
  alias Mint.HTTPError
  alias Finch.Error
  alias Finch.Telemetry
  alias Finch.SSL
  alias Finch.HTTP2.RequestStream

  alias Finch.HTTP2.PoolMetrics

  require Logger

  @default_receive_timeout 15_000

  @impl true
  def callback_mode(), do: [:state_functions, :state_enter]

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  # Call the pool with the request. The pool will multiplex multiple requests
  # and stream the result set back to the calling process using `send`
  @impl Finch.Pool
  def request(pool, request, acc, fun, name, opts) do
    opts = Keyword.put_new(opts, :receive_timeout, @default_receive_timeout)
    timeout = opts[:receive_timeout]
    request_ref = make_request_ref(pool)

    with {:ok, recv_start} <- :gen_statem.call(pool, {:request, request_ref, request, opts}) do
      monitor = Process.monitor(pool)
      # If the timeout is an integer, we add a fail-safe "after" clause that fires
      # after a timeout that is double the original timeout (min 2000ms). This means
      # that if there are no bugs in our code, then the normal :request_timeout is
      # returned, but otherwise we have a way to escape this code, raise an error, and
      # get the process unstuck.
      fail_safe_timeout = if is_integer(timeout), do: max(2000, timeout * 2), else: :infinity

      try do
        response_waiting_loop(acc, fun, request_ref, monitor, fail_safe_timeout, :headers)
      catch
        kind, error ->
          metadata = %{request: request, name: name}
          Telemetry.exception(:recv, recv_start, kind, error, __STACKTRACE__, metadata)

          :ok = :gen_statem.call(pool, {:cancel, request_ref})
          clean_responses(request_ref)
          Process.demonitor(monitor)

          :erlang.raise(kind, error, __STACKTRACE__)
      end
    end
  end

  @impl Finch.Pool
  def async_request(pool, req, _name, opts) do
    opts = Keyword.put_new(opts, :receive_timeout, @default_receive_timeout)
    request_ref = make_request_ref(pool)

    :ok = :gen_statem.cast(pool, {:async_request, self(), request_ref, req, opts})

    request_ref
  end

  @impl Finch.Pool
  def cancel_async_request({_, {pool, _}} = request_ref) do
    :ok = :gen_statem.call(pool, {:cancel, request_ref})
    clean_responses(request_ref)
  end

  @impl Finch.Pool
  def get_pool_status(finch_name, shp) do
    case Finch.PoolManager.get_pool_count(finch_name, shp) do
      nil ->
        {:error, :not_found}

      count ->
        1..count
        |> Enum.map(&PoolMetrics.get_pool_status(finch_name, shp, &1))
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(&elem(&1, 1))
        |> case do
          [] -> {:error, :not_found}
          result -> {:ok, result}
        end
    end
  end

  defp make_request_ref(pool) do
    {__MODULE__, {pool, make_ref()}}
  end

  defp response_waiting_loop(acc, fun, request_ref, monitor_ref, fail_safe_timeout, fields)

  defp response_waiting_loop(acc, fun, request_ref, monitor_ref, fail_safe_timeout, fields) do
    receive do
      {^request_ref, {:status, value}} ->
        case fun.({:status, value}, acc) do
          {:cont, acc} ->
            response_waiting_loop(
              acc,
              fun,
              request_ref,
              monitor_ref,
              fail_safe_timeout,
              fields
            )

          {:halt, acc} ->
            cancel_async_request(request_ref)
            Process.demonitor(monitor_ref)
            {:ok, acc}

          other ->
            raise ArgumentError, "expected {:cont, acc} or {:halt, acc}, got: #{inspect(other)}"
        end

      {^request_ref, {:headers, value}} ->
        case fun.({fields, value}, acc) do
          {:cont, acc} ->
            response_waiting_loop(
              acc,
              fun,
              request_ref,
              monitor_ref,
              fail_safe_timeout,
              fields
            )

          {:halt, acc} ->
            cancel_async_request(request_ref)
            Process.demonitor(monitor_ref)
            {:ok, acc}

          other ->
            raise ArgumentError, "expected {:cont, acc} or {:halt, acc}, got: #{inspect(other)}"
        end

      {^request_ref, {:data, value}} ->
        case fun.({:data, value}, acc) do
          {:cont, acc} ->
            response_waiting_loop(
              acc,
              fun,
              request_ref,
              monitor_ref,
              fail_safe_timeout,
              :trailers
            )

          {:halt, acc} ->
            cancel_async_request(request_ref)
            Process.demonitor(monitor_ref)
            {:ok, acc}

          other ->
            raise ArgumentError, "expected {:cont, acc} or {:halt, acc}, got: #{inspect(other)}"
        end

      {^request_ref, :done} ->
        Process.demonitor(monitor_ref)
        {:ok, acc}

      {^request_ref, {:error, error}} ->
        Process.demonitor(monitor_ref)
        {:error, error}

      {:DOWN, ^monitor_ref, _, _, _} ->
        {:error, :connection_process_went_down}
    after
      fail_safe_timeout ->
        Process.demonitor(monitor_ref)

        raise "no response was received even after waiting #{fail_safe_timeout}ms. " <>
                "This is likely a bug in Finch, but we're raising so that your system doesn't " <>
                "get stuck in an infinite receive."
    end
  end

  defp clean_responses(request_ref) do
    receive do
      {^request_ref, _} -> clean_responses(request_ref)
    after
      0 -> :ok
    end
  end

  def start_link({_shp, _finch_name, _pool_config, _start_pool_metrics?, _pool_idx} = opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @impl true
  def init({{scheme, host, port} = shp, registry, pool_opts, start_pool_metrics?, pool_idx}) do
    {:ok, metrics_ref} =
      if start_pool_metrics?,
        do: PoolMetrics.init(registry, shp, pool_idx),
        else: {:ok, nil}

    {:ok, _} = Registry.register(registry, shp, __MODULE__)

    data = %{
      conn: nil,
      finch_name: registry,
      scheme: scheme,
      host: host,
      port: port,
      pool_idx: pool_idx,
      requests: %{},
      refs: %{},
      requests_by_pid: %{},
      backoff_base: 500,
      backoff_max: 10_000,
      connect_opts: pool_opts[:conn_opts] || [],
      metrics_ref: metrics_ref
    }

    {:ok, :disconnected, data, {:next_event, :internal, {:connect, 0}}}
  end

  @doc false
  def disconnected(event, content, data)

  def disconnected(:enter, :disconnected, _) do
    :keep_state_and_data
  end

  # When entering a disconnected state we need to fail all of the pending
  # requests
  def disconnected(:enter, _, data) do
    :ok =
      Enum.each(data.requests, fn {_ref, request} ->
        send(
          request.from_pid,
          {request.request_ref, {:error, Error.exception(:connection_closed)}}
        )
      end)

    # It's possible that we're entering this state before we are alerted of the
    # fact that the socket is closed. This most often happens if we're in a read
    # only state but have no pending requests to wait on. In this case we can just
    # close the connection and throw it away.
    if data.conn do
      HTTP2.close(data.conn)
    end

    data =
      data
      |> Map.put(:requests, %{})
      |> Map.put(:conn, nil)

    actions = [{{:timeout, :reconnect}, data.backoff_base, 1}]

    {:keep_state, data, actions}
  end

  def disconnected(:internal, {:connect, failure_count}, data) do
    metadata = %{
      scheme: data.scheme,
      host: data.host,
      port: data.port,
      name: data.finch_name
    }

    start = Telemetry.start(:connect, metadata)

    case HTTP2.connect(data.scheme, data.host, data.port, data.connect_opts) do
      {:ok, conn} ->
        Telemetry.stop(:connect, start, metadata)
        SSL.maybe_log_secrets(data.scheme, data.connect_opts, conn)
        data = %{data | conn: conn}
        {:next_state, :connected, data}

      {:error, error} ->
        metadata = Map.put(metadata, :error, error)
        Telemetry.stop(:connect, start, metadata)

        Logger.warning([
          "Failed to connect to #{data.scheme}://#{data.host}:#{data.port}: ",
          Exception.message(error)
        ])

        delay = backoff(data.backoff_base, data.backoff_max, failure_count)
        {:keep_state_and_data, {{:timeout, :reconnect}, delay, failure_count + 1}}
    end
  end

  # Capture timeout after trying to reconnect. Immediately attempt to reconnect
  # to the upstream server
  def disconnected({:timeout, :reconnect}, failure_count, _data) do
    {:keep_state_and_data, {:next_event, :internal, {:connect, failure_count}}}
  end

  # Immediately fail a request if we're disconnected
  def disconnected({:call, from}, {:request, _, _, _}, _data) do
    {:keep_state_and_data, {:reply, from, {:error, Error.exception(:disconnected)}}}
  end

  # Ignore cancel requests if we are disconnected
  def disconnected({:call, from}, {:cancel, _request_ref}, _data) do
    {:keep_state_and_data, {:reply, from, {:error, Error.exception(:disconnected)}}}
  end

  # Immediately fail a request if we're disconnected
  def disconnected(:cast, {:async_request, pid, request_ref, _, _}, _data) do
    send(pid, {request_ref, {:error, Error.exception(:disconnected)}})
    :keep_state_and_data
  end

  # We cancel all request timeouts as soon as we enter the :disconnected state, but
  # some timeouts might fire while changing states, so we need to handle them here.
  # Since we replied to all pending requests when entering the :disconnected state,
  # we can just do nothing here.
  def disconnected({:timeout, {:request_timeout, _ref}}, _content, _data) do
    :keep_state_and_data
  end

  # Its possible that we can receive an info message telling us that a socket
  # has been closed. This happens after we enter a disconnected state from a
  # read_only state but we don't have any requests that are open. We've already
  # closed the connection and thrown it away at this point so we can just retain
  # our current state.
  def disconnected(:info, _message, _data) do
    :keep_state_and_data
  end

  @doc false
  def connected(event, content, data)

  def connected(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  # Issue request to the upstream server. We store a ref to the request so we
  # know who to respond to when we've completed everything
  def connected({:call, {from_pid, _from_ref} = from}, {:request, request_ref, req, opts}, data) do
    send_request(from, from_pid, request_ref, req, opts, data)
  end

  def connected({:call, from}, {:cancel, request_ref}, data) do
    data = cancel_request(data, request_ref)
    {:keep_state, data, {:reply, from, :ok}}
  end

  def connected(:cast, {:async_request, pid, request_ref, req, opts}, data) do
    if is_nil(data.requests_by_pid[pid]) do
      Process.monitor(pid)
    end

    send_request(nil, pid, request_ref, req, opts, data)
  end

  def connected(:info, {:DOWN, _, :process, pid, _}, data) do
    {:keep_state, cancel_requests(data, pid)}
  end

  def connected(:info, message, data) do
    case HTTP2.stream(data.conn, message) do
      {:ok, conn, responses} ->
        data = put_in(data.conn, conn)
        {data, response_actions} = handle_responses(data, responses)

        cond do
          HTTP2.open?(data.conn, :write) ->
            data = continue_requests(data)
            {:keep_state, data, response_actions}

          HTTP2.open?(data.conn, :read) && Enum.any?(data.requests) ->
            {:next_state, :connected_read_only, data, response_actions}

          true ->
            {:next_state, :disconnected, data, response_actions}
        end

      {:error, conn, error, responses} ->
        Logger.error([
          "Received error from server #{data.scheme}:#{data.host}:#{data.port}: ",
          Exception.message(error)
        ])

        data = put_in(data.conn, conn)
        {data, actions} = handle_responses(data, responses)

        if HTTP2.open?(conn, :read) && Enum.any?(data.requests) do
          {:next_state, :connected_read_only, data, actions}
        else
          {:next_state, :disconnected, data, actions}
        end

      :unknown ->
        Logger.warning(["Received unknown message: ", inspect(message)])
        :keep_state_and_data
    end
  end

  def connected({:timeout, {:request_timeout, ref}}, _content, data) do
    with {:pop, {request, data}} when not is_nil(request) <- {:pop, pop_request(data, ref)},
         {:ok, conn} <- HTTP2.cancel_request(data.conn, ref) do
      data = put_in(data.conn, conn)
      send(request.from_pid, {request.request_ref, {:error, Error.exception(:request_timeout)}})
      {:keep_state, data}
    else
      {:error, conn, _error} ->
        data = put_in(data.conn, conn)

        cond do
          HTTP2.open?(conn, :write) ->
            {:keep_state, data}

          # Don't bother entering read only mode if we don't have any pending requests.
          HTTP2.open?(conn, :read) && Enum.any?(data.requests) ->
            {:next_state, :connected_read_only, data}

          true ->
            {:next_state, :disconnected, data}
        end

      # The timer might have fired while we were receiving :done/:error for this
      # request, so we don't have the request stored anymore but we still get the
      # timer event. In those cases, we do nothing.
      {:pop, {nil, _data}} ->
        :keep_state_and_data
    end
  end

  @doc false
  def connected_read_only(event, content, data)

  def connected_read_only(:enter, _old_state, data) do
    data =
      Enum.reduce(data.requests, data, fn
        # request is awaiting a response and should stay in state
        {_ref, %{stream: %{status: :done}}}, data ->
          data

        # request is still sending data and should be discarded
        {ref, %{stream: %{status: :streaming}} = request}, data ->
          {^request, data} = pop_request(data, ref)
          reply(request, {:error, Error.exception(:read_only)})
          data
      end)

    {:keep_state, data}
  end

  # If we're in a read only state than respond with an error immediately
  def connected_read_only({:call, from}, {:request, _, _, _}, _) do
    {:keep_state_and_data, {:reply, from, {:error, Error.exception(:read_only)}}}
  end

  def connected_read_only({:call, from}, {:cancel, request_ref}, data) do
    data = cancel_request(data, request_ref)
    {:keep_state, data, {:reply, from, :ok}}
  end

  def connected_read_only(:cast, {:async_request, pid, request_ref, _, _}, _) do
    send(pid, {request_ref, {:error, Error.exception(:read_only)}})
    :keep_state_and_data
  end

  def connected_read_only(:info, {:DOWN, _, :process, pid, _}, data) do
    {:keep_state, cancel_requests(data, pid)}
  end

  def connected_read_only(:info, message, data) do
    case HTTP2.stream(data.conn, message) do
      {:ok, conn, responses} ->
        data = put_in(data.conn, conn)
        {data, actions} = handle_responses(data, responses)

        # If the connection is still open for reading and we have pending requests
        # to receive, we should try to wait for the responses. Otherwise enter
        # the disconnected state so we can try to re-establish a connection.
        if HTTP2.open?(conn, :read) && Enum.any?(data.requests) do
          {:keep_state, data, actions}
        else
          {:next_state, :disconnected, data, actions}
        end

      {:error, conn, error, responses} ->
        Logger.error([
          "Received error from server #{data.scheme}://#{data.host}:#{data.port}: ",
          Exception.message(error)
        ])

        data = put_in(data.conn, conn)
        {data, actions} = handle_responses(data, responses)

        # Same as above, if we're still waiting on responses, we should stay in
        # this state. Otherwise, we should enter the disconnected state and try
        # to re-establish a connection.
        if HTTP2.open?(conn, :read) && Enum.any?(data.requests) do
          {:keep_state, data, actions}
        else
          {:next_state, :disconnected, data, actions}
        end

      :unknown ->
        Logger.warning(["Received unknown message: ", inspect(message)])
        :keep_state_and_data
    end
  end

  # In this state, we don't need to call HTTP2.cancel_request/2 since the connection
  # is closed for writing, so we can't tell the server to cancel the request anymore.
  def connected_read_only({:timeout, {:request_timeout, ref}}, _content, data) do
    # We might get a request timeout that fired in the moment when we received the
    # whole request, so we don't have the request in the state but we get the
    # timer event anyways. In those cases, we don't do anything.
    {request, data} = pop_request(data, ref)

    # Its possible that the request doesn't exist so we guard against that here.
    if request != nil do
      send(request.from_pid, {request.request_ref, {:error, Error.exception(:request_timeout)}})
    end

    # If we're out of requests then we should enter the disconnected state.
    # Otherwise wait for the remaining responses.
    if Enum.empty?(data.requests) do
      {:next_state, :disconnected, data}
    else
      {:keep_state, data}
    end
  end

  defp send_request(from, from_pid, request_ref, req, opts, data) do
    telemetry_metadata = %{request: req, name: data.finch_name}

    request = %{
      stream: RequestStream.new(req.body),
      from: from,
      from_pid: from_pid,
      request_ref: request_ref,
      telemetry: %{
        metadata: telemetry_metadata,
        send: Telemetry.start(:send, telemetry_metadata)
      }
    }

    body = if req.body == nil, do: nil, else: :stream

    data
    |> start_request(req.method, Finch.Request.request_path(req), req.headers, body)
    |> stream_request(request, opts)
  end

  defp start_request(data, method, path, headers, body) do
    case HTTP2.request(data.conn, method, path, headers, body) do
      {:ok, conn, ref} ->
        {:ok, put_in(data.conn, conn), ref}

      {:error, conn, reason} ->
        {:error, put_in(data.conn, conn), reason}
    end
  end

  defp stream_request({:ok, data, ref}, request, opts) do
    data = put_request(data, ref, request)

    case continue_request(data, ref, request) do
      {:ok, data} ->
        # Set a timeout to close the request after a given timeout
        request_timeout = {{:timeout, {:request_timeout, ref}}, opts[:receive_timeout], nil}

        {:keep_state, data, [request_timeout]}

      error ->
        stream_request(error, request, opts)
    end
  end

  defp stream_request({:error, data, %HTTPError{reason: :closed_for_writing}}, request, _opts) do
    reply(request, {:error, Error.exception(:read_only)})

    if HTTP2.open?(data.conn, :read) && Enum.any?(data.requests) do
      {:next_state, :connected_read_only, data}
    else
      {:next_state, :disconnected, data}
    end
  end

  defp stream_request({:error, data, error}, request, _opts) do
    reply(request, {:error, error})

    if HTTP2.open?(data.conn) do
      {:keep_state, data}
    else
      {:next_state, :disconnected, data}
    end
  end

  defp handle_responses(data, responses) do
    Enum.reduce(responses, {data, _actions = []}, fn response, {data, actions} ->
      handle_response(data, response, actions)
    end)
  end

  defp handle_response(data, {kind, ref, value}, actions)
       when kind in [:status, :headers] do
    data =
      if request = data.requests[ref] do
        send(request.from_pid, {request.request_ref, {kind, value}})
        request = put_in(request.telemetry.metadata[kind], value)
        put_in(data.requests[ref], request)
      else
        data
      end

    {data, actions}
  end

  defp handle_response(data, {:data, ref, value}, actions) do
    if request = data.requests[ref] do
      send(request.from_pid, {request.request_ref, {:data, value}})
    end

    {data, actions}
  end

  defp handle_response(data, {:done, ref}, actions) do
    {request, data} = pop_request(data, ref)

    if request do
      send(request.from_pid, {request.request_ref, :done})
      Telemetry.stop(:recv, request.telemetry.recv, request.telemetry.metadata)
    end

    {data, [cancel_request_timeout_action(ref) | actions]}
  end

  defp handle_response(data, {:error, ref, error}, actions) do
    {request, data} = pop_request(data, ref)

    if request do
      send(request.from_pid, {request.request_ref, {:error, error}})

      Telemetry.stop(
        :recv,
        request.telemetry.recv,
        Map.put(request.telemetry.metadata, :error, error)
      )
    end

    {data, [cancel_request_timeout_action(ref) | actions]}
  end

  defp cancel_request_timeout_action(request_ref) do
    # By setting the timeout to :infinity, we cancel this timeout as per
    # gen_statem documentation.
    {{:timeout, {:request_timeout, request_ref}}, :infinity, nil}
  end

  # Exponential backoff with jitter
  # The backoff algorithm optimizes for tight bounds on completing a request successfully.
  # It does this by first calculating an exponential backoff factor based on the
  # number of retries that have been performed. It then multiplies this factor against the
  # base delay. The total maximum delay is found by taking the minimum of either the calculated delay
  # or the maximum delay specified. This creates an upper bound on the maximum delay
  # we can see.
  #
  # In order to find the actual delay value we take a random number between 0 and
  # the maximum delay based on a uniform distribution. This randomness ensures that
  # our retried requests don't "harmonize" making it harder for the downstream
  # service to heal.
  defp backoff(base_backoff, max_backoff, failure_count) do
    factor = :math.pow(2, failure_count)
    max_sleep = trunc(min(max_backoff, base_backoff * factor))
    :rand.uniform(max_sleep)
  end

  # this is also a wrapper (Mint.HTTP2.stream_request_body/3)
  defp stream_request_body(data, ref, body) do
    case HTTP2.stream_request_body(data.conn, ref, body) do
      {:ok, conn} -> {:ok, put_in(data.conn, conn)}
      {:error, conn, reason} -> {:error, put_in(data.conn, conn), reason}
    end
  end

  defp stream_chunks(data, ref, body, %{stream: %{status: :done}}) do
    with {:ok, data} <- stream_request_body(data, ref, body) do
      stream_request_body(data, ref, :eof)
    end
  end

  defp stream_chunks(data, ref, body, _), do: stream_request_body(data, ref, body)

  defp continue_requests(data) do
    Enum.reduce(data.requests, data, fn {ref, request}, data ->
      with true <- request.stream.status == :streaming,
           true <- HTTP2.open?(data.conn, :write),
           {:ok, data} <- continue_request(data, ref, request) do
        data
      else
        false ->
          data

        {:error, data, %HTTPError{reason: :closed_for_writing}} ->
          reply(request, {:error, Error.exception(:read_only)})
          data

        {:error, data, reason} ->
          reply(request, {:error, reason})
          data
      end
    end)
  end

  defp continue_request(data, ref, request) do
    with :streaming <- request.stream.status,
         window = smallest_window(data.conn, ref),
         {stream, chunks} = RequestStream.next_chunk(request.stream, window),
         request = %{request | stream: stream},
         {:ok, data} <- stream_chunks(data, ref, chunks, request) do
      {:ok, complete_request_if_done(data, ref, request)}
    else
      :done ->
        {:ok, complete_request_if_done(data, ref, request)}

      {:error, data, reason} ->
        {_from, data} = pop_request(data, ref)

        {:error, data, reason}
    end
  end

  defp complete_request_if_done(data, ref, %{stream: %{status: :done}} = request) do
    %{from: from, telemetry: telemetry} = request
    Telemetry.stop(:send, telemetry.send, telemetry.metadata)
    recv_start = Telemetry.start(:recv, telemetry.metadata)
    request = put_in(request.telemetry[:recv], recv_start)

    if from do
      reply(request, {:ok, recv_start})
    end

    put_in(data.requests[ref], request)
  end

  defp complete_request_if_done(data, ref, request) do
    put_in(data.requests[ref], request)
  end

  defp smallest_window(conn, ref) do
    min(
      HTTP2.get_window_size(conn, :connection),
      HTTP2.get_window_size(conn, {:request, ref})
    )
  end

  defp cancel_requests(data, pid) do
    if request_refs = data.requests_by_pid[pid] do
      Enum.reduce(request_refs, data, fn request_ref, data ->
        cancel_request(data, request_ref)
      end)
    else
      data
    end
  end

  defp cancel_request(data, request_ref) do
    # If the Mint ref isn't present, it was removed because the request
    # already completed and there's nothing to cancel.
    if ref = data.refs[request_ref] do
      conn =
        case HTTP2.cancel_request(data.conn, ref) do
          {:ok, conn} -> conn
          {:error, conn, _error} -> conn
        end

      data = put_in(data.conn, conn)
      {_from, data} = pop_request(data, ref)
      data
    else
      data
    end
  end

  defp put_request(data, ref, request) do
    PoolMetrics.maybe_add(data.metrics_ref, in_flight_requests: 1)

    data
    |> put_in([:requests, ref], request)
    |> put_in([:refs, request.request_ref], ref)
    |> put_pid(request.from_pid, request.request_ref)
  end

  defp pop_request(data, ref) do
    PoolMetrics.maybe_add(data.metrics_ref, in_flight_requests: -1)

    case pop_in(data.requests[ref]) do
      {nil, data} ->
        {nil, data}

      {request, data} ->
        {_ref, data} =
          data
          |> pop_pid(request.from_pid, request.request_ref)
          |> pop_in([:refs, request.request_ref])

        {request, data}
    end
  end

  defp put_pid(data, pid, request_ref) do
    update_in(data.requests_by_pid, fn requests_by_pid ->
      Map.update(requests_by_pid, pid, MapSet.new([request_ref]), &MapSet.put(&1, request_ref))
    end)
  end

  defp pop_pid(data, pid, request_ref) do
    update_in(data.requests_by_pid, fn requests_by_pid ->
      requests =
        requests_by_pid
        |> Map.get(pid, MapSet.new())
        |> MapSet.delete(request_ref)

      if Enum.empty?(requests) do
        Map.delete(requests_by_pid, pid)
      else
        Map.put(requests_by_pid, pid, requests)
      end
    end)
  end

  defp reply(%{from: nil, from_pid: pid, request_ref: request_ref}, reply) do
    send(pid, {request_ref, reply})
    :ok
  end

  defp reply(%{from: from}, reply) do
    :gen_statem.reply(from, reply)
  end
end
