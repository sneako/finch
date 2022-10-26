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
  @impl true
  def request(pool, request, acc, fun, opts) do
    opts = Keyword.put_new(opts, :receive_timeout, @default_receive_timeout)
    timeout = opts[:receive_timeout]

    metadata = %{request: request}

    start_time = Telemetry.start(:send, metadata)

    with {:ok, ref} <- :gen_statem.call(pool, {:request, request, opts}) do
      Telemetry.stop(:send, start_time, metadata)
      monitor = Process.monitor(pool)
      # If the timeout is an integer, we add a fail-safe "after" clause that fires
      # after a timeout that is double the original timeout (min 2000ms). This means
      # that if there are no bugs in our code, then the normal :request_timeout is
      # returned, but otherwise we have a way to escape this code, raise an error, and
      # get the process unstuck.
      fail_safe_timeout = if is_integer(timeout), do: max(2000, timeout * 2), else: :infinity
      start_time = Telemetry.start(:recv, metadata)

      try do
        result = response_waiting_loop(acc, fun, ref, monitor, fail_safe_timeout)

        case result do
          {:ok, acc, {status, headers}} ->
            metadata = Map.merge(metadata, %{status: status, headers: headers})
            Telemetry.stop(:recv, start_time, metadata)
            {:ok, acc}

          {:error, error, {status, headers}} ->
            metadata = Map.merge(metadata, %{error: error, status: status, headers: headers})
            Telemetry.stop(:recv, start_time, metadata)
            {:error, error}
        end
      catch
        kind, error ->
          Telemetry.exception(:recv, start_time, kind, error, __STACKTRACE__, metadata)

          :gen_statem.call(pool, {:cancel, ref})
          clean_responses(ref)
          Process.demonitor(monitor)

          :erlang.raise(kind, error, __STACKTRACE__)
      end
    end
  end

  defp response_waiting_loop(
         acc,
         fun,
         ref,
         monitor_ref,
         fail_safe_timeout,
         status \\ nil,
         headers \\ []
       )

  defp response_waiting_loop(acc, fun, ref, monitor_ref, fail_safe_timeout, status, headers) do
    receive do
      {:status, ^ref, value} ->
        response_waiting_loop(
          fun.({:status, value}, acc),
          fun,
          ref,
          monitor_ref,
          fail_safe_timeout,
          value,
          headers
        )

      {:headers, ^ref, value} ->
        response_waiting_loop(
          fun.({:headers, value}, acc),
          fun,
          ref,
          monitor_ref,
          fail_safe_timeout,
          status,
          headers ++ value
        )

      {:data, ^ref, value} ->
        response_waiting_loop(
          fun.({:data, value}, acc),
          fun,
          ref,
          monitor_ref,
          fail_safe_timeout,
          status,
          headers
        )

      {:done, ^ref} ->
        Process.demonitor(monitor_ref)
        {:ok, acc, {status, headers}}

      {:error, ^ref, error} ->
        Process.demonitor(monitor_ref)
        {:error, error, {status, headers}}

      {:DOWN, ^monitor_ref, _, _, _} ->
        {:error, :connection_process_went_down, {status, headers}}
    after
      fail_safe_timeout ->
        Process.demonitor(monitor_ref)

        raise "no response was received even after waiting #{fail_safe_timeout}ms. " <>
                "This is likely a bug in Finch, but we're raising so that your system doesn't " <>
                "get stuck in an infinite receive."
    end
  end

  defp clean_responses(ref) do
    receive do
      {kind, ^ref, _value} when kind in [:status, :headers, :data] ->
        clean_responses(ref)

      {:done, ^ref} ->
        :ok

      {:error, ^ref, _error} ->
        :ok
    after
      0 ->
        :ok
    end
  end

  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @impl true
  def init({{scheme, host, port} = shp, registry, _pool_size, pool_opts}) do
    {:ok, _} = Registry.register(registry, shp, __MODULE__)

    data = %{
      conn: nil,
      scheme: scheme,
      host: host,
      port: port,
      requests: %{},
      backoff_base: 500,
      backoff_max: 10_000,
      connect_opts: pool_opts[:conn_opts] || []
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
      Enum.each(data.requests, fn {ref, request} ->
        send(request.from_pid, {:error, ref, Error.exception(:connection_closed)})
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
      port: data.port
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

        Logger.error([
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
  def disconnected({:call, from}, {:request, _, _}, _data) do
    {:keep_state_and_data, {:reply, from, {:error, Error.exception(:disconnected)}}}
  end

  # Ignore cancel requests if we are disconnected
  def disconnected({:call, _from}, {:cancel, _ref}, _data) do
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
  def connected({:call, from}, {:request, req, opts}, data) do
    request = RequestStream.new(req.body, from)

    with {:ok, data, ref} <- request(data, req),
         data = put_in(data.requests[ref], request),
         {:ok, data, actions} <- continue_request(data, ref) do
      # Set a timeout to close the request after a given timeout
      request_timeout = {{:timeout, {:request_timeout, ref}}, opts[:receive_timeout], nil}

      {:keep_state, data, actions ++ [request_timeout]}
    else
      {:error, data, %HTTPError{reason: :closed_for_writing}} ->
        actions = [{:reply, from, {:error, "read_only"}}]

        if HTTP2.open?(data.conn, :read) && Enum.any?(data.requests) do
          {:next_state, :connected_read_only, data, actions}
        else
          {:next_state, :disconnected, data, actions}
        end

      {:error, data, error} ->
        actions = [{:reply, from, {:error, error}}]

        if HTTP2.open?(data.conn) do
          {:keep_state, data, actions}
        else
          {:next_state, :disconnected, data, actions}
        end
    end
  end

  def connected({:call, from}, {:cancel, ref}, data) do
    conn =
      case HTTP2.cancel_request(data.conn, ref) do
        {:ok, conn} -> conn
        {:error, conn, _error} -> conn
      end

    data = put_in(data.conn, conn)
    {_from, data} = pop_in(data.requests[ref])
    {:keep_state, data, {:reply, from, :ok}}
  end

  def connected(:info, message, data) do
    case HTTP2.stream(data.conn, message) do
      {:ok, conn, responses} ->
        data = put_in(data.conn, conn)
        {data, response_actions} = handle_responses(data, responses)

        cond do
          HTTP2.open?(data.conn, :write) ->
            {data, streaming_actions} = continue_requests(data)
            {:keep_state, data, response_actions ++ streaming_actions}

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
        Logger.warn(["Received unknown message: ", inspect(message)])
        :keep_state_and_data
    end
  end

  def connected({:timeout, {:request_timeout, ref}}, _content, data) do
    with {:pop, {request, data}} when not is_nil(request) <- {:pop, pop_in(data.requests[ref])},
         {:ok, conn} <- HTTP2.cancel_request(data.conn, ref) do
      data = put_in(data.conn, conn)
      send(request.from_pid, {:error, ref, Error.exception(:request_timeout)})
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
    {actions, data} =
      Enum.flat_map_reduce(data.requests, data, fn
        # request is awaiting a response and should stay in state
        {_ref, %{status: :done}}, data ->
          {[], data}

        # request is still sending data and should be discarded
        {ref, %{status: :streaming} = request}, data ->
          {^request, data} = pop_in(data.requests[ref])
          {[{:reply, request.from, {:error, Error.exception(:read_only)}}], data}
      end)

    {:keep_state, data, actions}
  end

  # If we're in a read only state than respond with an error immediately
  def connected_read_only({:call, from}, {:request, _, _}, _) do
    {:keep_state_and_data, {:reply, from, {:error, Error.exception(:read_only)}}}
  end

  def connected_read_only({:call, from}, {:cancel, ref}, data) do
    {_from, data} = pop_in(data.requests[ref])
    {:keep_state, data, {:reply, from, :ok}}
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
        Logger.warn(["Received unknown message: ", inspect(message)])
        :keep_state_and_data
    end
  end

  # In this state, we don't need to call HTTP2.cancel_request/2 since the connection
  # is closed for writing, so we can't tell the server to cancel the request anymore.
  def connected_read_only({:timeout, {:request_timeout, ref}}, _content, data) do
    # We might get a request timeout that fired in the moment when we received the
    # whole request, so we don't have the request in the state but we get the
    # timer event anyways. In those cases, we don't do anything.
    {request, data} = pop_in(data.requests[ref])

    # Its possible that the request doesn't exist so we guard against that here.
    if request != nil do
      send(request.from_pid, {:error, ref, Error.exception(:request_timeout)})
    end

    # If we're out of requests then we should enter the disconnected state.
    # Otherwise wait for the remaining responses.
    if Enum.empty?(data.requests) do
      {:next_state, :disconnected, data}
    else
      {:keep_state, data}
    end
  end

  defp handle_responses(data, responses) do
    Enum.reduce(responses, {data, _actions = []}, fn response, {data, actions} ->
      handle_response(data, response, actions)
    end)
  end

  defp handle_response(data, {kind, ref, _value} = response, actions)
       when kind in [:status, :headers, :data] do
    if request = data.requests[ref] do
      send(request.from_pid, response)
    end

    {data, actions}
  end

  defp handle_response(data, {:done, ref} = response, actions) do
    {request, data} = pop_in(data.requests[ref])
    if request, do: send(request.from_pid, response)
    {data, [cancel_request_timeout_action(ref) | actions]}
  end

  defp handle_response(data, {:error, ref, _error} = response, actions) do
    {request, data} = pop_in(data.requests[ref])
    if request, do: send(request.from_pid, response)
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

  # a wrapper around Mint.HTTP2.request/5
  # wrapping allows us to more easily encapsulate the conn within `data`
  defp request(data, req) do
    body = if req.body == nil, do: nil, else: :stream

    case HTTP2.request(data.conn, req.method, Finch.Request.request_path(req), req.headers, body) do
      {:ok, conn, ref} -> {:ok, put_in(data.conn, conn), ref}
      {:error, conn, reason} -> {:error, put_in(data.conn, conn), reason}
    end
  end

  # this is also a wrapper (Mint.HTTP2.stream_request_body/3)
  defp stream_request_body(data, ref, body) do
    case HTTP2.stream_request_body(data.conn, ref, body) do
      {:ok, conn} -> {:ok, put_in(data.conn, conn)}
      {:error, conn, reason} -> {:error, put_in(data.conn, conn), reason}
    end
  end

  defp stream_chunks(data, ref, body) do
    with {:ok, data} <- stream_request_body(data, ref, body) do
      if data.requests[ref].status == :done do
        stream_request_body(data, ref, :eof)
      else
        {:ok, data}
      end
    end
  end

  defp continue_requests(data) do
    Enum.reduce(data.requests, {data, []}, fn {ref, request}, {data, actions} ->
      with true <- request.status == :streaming,
           true <- HTTP2.open?(data.conn, :write),
           {:ok, data, new_actions} <- continue_request(data, ref) do
        {data, new_actions ++ actions}
      else
        false ->
          {data, actions}

        {:error, data, %HTTPError{reason: :closed_for_writing}} ->
          {data, [{:reply, request.from, {:error, "read_only"}} | actions]}

        {:error, data, reason} ->
          {data, [{:reply, request.from, {:error, reason}} | actions]}
      end
    end)
  end

  defp continue_request(data, ref) do
    request = data.requests[ref]
    reply_action = {:reply, request.from, {:ok, ref}}

    with :streaming <- request.status,
         window = smallest_window(data.conn, ref),
         {request, chunks} = RequestStream.next_chunk(request, window),
         data = put_in(data.requests[ref], request),
         {:ok, data} <- stream_chunks(data, ref, chunks) do
      actions = if request.status == :done, do: [reply_action], else: []

      {:ok, data, actions}
    else
      :done ->
        {:ok, data, [reply_action]}

      {:error, data, reason} ->
        {_from, data} = pop_in(data.requests[ref])

        {:error, data, reason}
    end
  end

  defp smallest_window(conn, ref) do
    min(
      HTTP2.get_window_size(conn, :connection),
      HTTP2.get_window_size(conn, {:request, ref})
    )
  end
end
