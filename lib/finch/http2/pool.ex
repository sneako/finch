defmodule Finch.HTTP2.Pool do
  @moduledoc false

  @behaviour :gen_statem
  @behaviour Finch.Pool

  alias Mint.HTTP2
  alias Mint.HTTPError
  alias Finch.Telemetry

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

    metadata = %{
      scheme: request.scheme,
      host: request.host,
      port: request.port,
      method: request.method,
      path: Finch.Request.request_path(request)
    }

    # start_time = Telemetry.start(:request, metadata)

    with {:ok, ref} <- :gen_statem.call(pool, {:request, request, opts}) do
      # Telemetry.stop(:request, start_time, metadata)
      monitor = Process.monitor(pool)
      # If the timeout is an integer, we add a fail-safe "after" clause that fires
      # after a timeout that is double the original timeout (min 2000ms). This means
      # that if there are no bugs in our code, then the normal :request_timeout is
      # returned, but otherwise we have a way to escape this code, raise an error, and
      # get the process unstuck.
      fail_safe_timeout = if is_integer(timeout), do: max(2000, timeout * 2), else: :infinity
      start_time = Telemetry.start(:response, metadata)
      try do
        result = response_waiting_loop(acc, fun, ref, monitor, fail_safe_timeout)

        case result do
          {:ok, _} ->
            Telemetry.stop(:response, start_time, metadata)
            result

          {:error, error} ->
            metadata = Map.put(metadata, :error, error)
            Telemetry.stop(:response, start_time, metadata)
            result
        end
      rescue
        error ->
          Telemetry.exception(:response, start_time, :error, error, __STACKTRACE__, metadata)
          reraise error, __STACKTRACE__
      end
    end
  end

  defp response_waiting_loop(acc, fun, ref, monitor_ref, fail_safe_timeout) do
    receive do
      {:DOWN, ^monitor_ref, _, _, _} ->
        {:error, :connection_process_went_down}

      {kind, ^ref, value} when kind in [:status, :headers, :data] ->
        response_waiting_loop(fun.({kind, value}, acc), fun, ref, monitor_ref, fail_safe_timeout)

      {:done, _ref} ->
        {:ok, acc}

      {:error, ^ref, error} ->
        {:error, error}
    after
      fail_safe_timeout ->
        raise "no response was received even after waiting #{fail_safe_timeout}ms. " <>
                "This is likely a bug in Finch, but we're raising so that your system doesn't " <>
                "get stuck in an infinite receive."
    end
  end

  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @impl true
  def init({{scheme, host, port}=shp, registry, _pool_size, pool_opts}) do
    {:ok, _} = Registry.register(registry, shp, __MODULE__)

    data = %{
      conn: nil,
      scheme: scheme,
      host: host,
      port: port,
      requests: %{},
      backoff_base: 500,
      backoff_max: 10_000,
      connect_opts: pool_opts[:conn_opts] || [],
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
    :ok = Enum.each(data.requests, fn {ref, from} ->
      send(from, {:error, ref, %{reason: :connection_closed}})
    end)

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
    }
    start = Telemetry.start(:connect)
    case HTTP2.connect(data.scheme, data.host, data.port, data.connect_opts) do
      {:ok, conn} ->
        Telemetry.stop(:connect, start, metadata)
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
    {:keep_state_and_data, {:reply, from, {:error, %{reason: :disconnected}}}}
  end

 # We cancel all request timeouts as soon as we enter the :disconnected state, but
 # some timeouts might fire while changing states, so we need to handle them here.
 # Since we replied to all pending requests when entering the :disconnected state,
 # we can just do nothing here.
 def disconnected({:timeout, {:request_timeout, _ref}}, _content, _data) do
   :keep_state_and_data
 end


  @doc false
  def connected(event, content, data)

  def connected(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  # Issue request to the upstream server. We store a ref to the request so we
  # know who to respond to when we've completed everything
  def connected({:call, {from_pid, _}=from}, {:request, req, opts}, data) do
    case HTTP2.request(data.conn, req.method, Finch.Request.request_path(req), req.headers, req.body) do
      {:ok, conn, ref} ->
        data =
          data
          |> put_in([:conn], conn)
          |> put_in([:requests, ref], from_pid)

        # Set a timeout to close the request after a given timeout
        actions = [
          {:reply, from, {:ok, ref}},
          {{:timeout, {:request_timeout, ref}}, opts[:receive_timeout], nil}
        ]

        {:keep_state, data, actions}

      {:error, conn, %HTTPError{reason: :closed_for_writing}} ->
        data = put_in(data.conn, conn)
        actions = [{:reply, from, {:error, "read_only"}}]
        {:next_state, :connected_read_only, data, actions}

      {:error, conn, error} ->
        data = put_in(data.conn, conn)
        actions = [{:reply, from, {:error, error}}]

        if HTTP2.open?(conn) do
          {:keep_state, data, actions}
        else
          {:next_state, :disconnected, data, actions}
        end
    end
  end

  def connected(:info, message, data) do
    case HTTP2.stream(data.conn, message) do
      {:ok, conn, responses} ->
        data = put_in(data.conn, conn)
        {data, actions} = handle_responses(data, responses)

        cond do
          HTTP2.open?(conn, :write) ->
            {:keep_state, data, actions}

          HTTP2.open?(conn, :read) ->
            {:next_state, :connected_read_only, data, actions}

          true ->
            {:next_state, :disconnected, data, actions}
        end

      {:error, conn, error, responses} ->
        Logger.error([
          "Received error from server #{data.scheme}:#{data.host}:#{data.port}: ",
          Exception.message(error)
        ])

        data = put_in(data.conn, conn)
        {data, actions} = handle_responses(data, responses)

        if HTTP2.open?(conn, :read) do
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
    with {:pop, {from, data}} when not is_nil(from) <- {:pop, pop_in(data.requests[ref])},
         {:ok, conn} <- HTTP2.cancel_request(data.conn, ref) do
      data = put_in(data.conn, conn)
      send(from, {:error, ref, %{reason: :request_timeout}})
      {:keep_state, data}
    else
      {:error, conn, _error} ->
        data = put_in(data.conn, conn)

        cond do
          HTTP2.open?(conn, :write) ->
            {:keep_state, data}

          HTTP2.open?(conn, :read) ->
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

  def connected_read_only(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  # If we're in a read only state than respond with an error immediately
  def connected_read_only({:call, from}, {:request, _, _}, _) do
    {:keep_state_and_data, {:reply, from, {:error, %{reason: :read_only}}}}
  end

  def connected_read_only(:info, message, data) do
    case HTTP2.stream(data.conn, message) do
      {:ok, conn, responses} ->
        data = put_in(data.conn, conn)
        {data, actions} = handle_responses(data, responses)

        if HTTP2.open?(conn, :read) do
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

        if HTTP2.open?(conn, :read) do
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
    case pop_in(data.requests[ref]) do
      {nil, _data} ->
        :keep_state_and_data

      {from, data} ->
        send(from, {:error, ref, :request_timeout})
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
    send(data.requests[ref], response)
    {data, actions}
  end

  defp handle_response(data, {:done, ref} = response, actions) do
    {pid, data} = pop_in(data.requests[ref])
    send(pid, response)
    {data, [cancel_request_timeout_action(ref) | actions]}
  end

  defp handle_response(data, {:error, ref, _error} = response, actions) do
    {pid, data} = pop_in(data.requests[ref])
    send(pid, response)
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
end
