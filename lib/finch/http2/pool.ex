defmodule Finch.HTTP2.Pool do
  @moduledoc false

  @behaviour :gen_statem

  alias Mint.HTTP2, as: HTTP

  require Logger

  def start_link(config) do
    :gen_statem.start_link(__MODULE__, config)
  end

  def request(pid, req, opts) do
    :gen_statem.call(pid, {:request, req, opts})
  end

  @impl true
  def callback_mode(), do: [:state_functions, :state_enter]

  def init(config) do
    {:ok, _} = Registry.register(config.registry, config.shp, __MODULE__)
    {s, h, p} = config.shp
    # TODO - Make transport opts configurable
    {:ok, conn} = HTTP.connect(s, h, p, [transport_opts: [verify: :verify_none]])

    data = %{
      scheme: s,
      host: h,
      port: p,
      conn: conn,
      requests: %{},
      pings: %{},
    }

    {:ok, data}
    # {:ok, disconnected, data, {:next_event, :
  end

  def disconnected(event, content, data)

  def disconnected(:enter, :disconnected, _data) do
    :keep_state_and_data
  end

  # If we enter a disconnected state, cancel all pending requests
  def disconnected(:enter, _, data) do
    resps = Enum.map(data.requests, fn from ->
      {:reply, from, {:error, :connection_closed}}
    end)

    data = put_in(data.requests, %{})
    data = put_in(data.conn, nil)

    actions = [{{:timeout, :reconnect}, data.backoff_initial, data.backoff_initial}]
    {:keep_state, data, actions}
  end

  def connected(:enter, _, _) do
    :keep_state_and_data
  end

  def connected({:call, from}, {:request, req, opts}, data) do
    case HTTP2.request(data.conn, req.method, req.path, req.headers, req.body) do
      {:ok, conn, ref} ->
    end
  end

  def handle_call({:request, req, opts}, from, data) do
    {:ok, conn, ref} = HTTP.request(data.conn, req.method, req.path, req.headers, req.body)

    data =
      data
      |> put_in([:conn], conn)
      |> put_in([:requests, ref],  %{from: from, data: ""})

    {:noreply, data}
  end

  def handle_info(message, data) do
    case HTTP.stream(data.conn, message) do
      {:ok, conn, responses} ->
        data = handle_responses(responses, data)
        {:noreply, %{data | conn: conn}}

      {:error, conn, reason, responses} ->
        Logger.error("Error: #{inspect reason}")
        data = handle_responses(responses, data)
        {:noreply, %{data | conn: conn}}

      :unknown ->
        {:noreply, data}
    end
  end

  def handle_responses([], data), do: data
  def handle_responses([response | rs], data) do
    case response do
      {:status, ref, code} ->
        handle_responses(rs, put_in(data, [:requests, ref, :status_code], code))

      {:headers, ref, headers} ->
        handle_responses(rs, put_in(data, [:requests, ref, :resp_headers], headers))

      {:data, ref, binary} ->
        handle_responses(rs, update_in(data, [:requests, ref, :data], & &1 <> binary))

      {:done, ref} ->
        {req, data} = pop_in(data, [:requests, ref])
        GenServer.reply(req.from, {:ok, Map.delete(req, :from)})
        handle_responses(rs, data)

      {:error, ref, reason} ->
        {req, data} = pop_in(data, [:requests, ref])
        GenServer.reply(req.from, {:error, reason})
        handle_responses(rs, data)

      {:pong, ref} ->
        {ping, data} = pop_in(data, [:pings, ref])
        # TODO - Measure latency to get a response back
        handle_responses(rs, data)

      unhandled ->
        # IO.inspect(unhandled, label: "Unhandled")
        handle_responses(rs, data)
    end
  end
end
