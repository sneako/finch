defmodule Finch.HTTP2Conn do
  use GenServer

  alias Mint.HTTP2, as: HTTP

  require Logger

  def start_link() do
    GenServer.start_link(__MODULE__, [])
  end

  def multi(pid) do
    (0..49)
    |> Enum.map(fn _ -> Task.async(fn -> GenServer.call(pid, :go) end) end)
    |> Enum.map(& Task.await(&1))
  end

  def init(opts) do
    {:ok, conn} = HTTP.connect(:https, "localhost", 4000, [transport_opts: [verify: :verify_none]])
    # Process.send_after(self(), :send_ping, 50)

    data = %{
      # scheme: :https,
      # host: "keathley.io",
      # port: 443,
      # path: "/",
      conn: conn,
      requests: %{},
      pings: %{},
    }

    {:ok, data}
  end

  def handle_call(:go, from, data) do
    {:ok, conn, ref} = HTTP.request(data.conn, "GET", "/wait/100", [], nil)

    data =
      data
      |> put_in([:conn], conn)
      |> put_in([:requests, ref],  %{from: from, data: ""})

    {:noreply, data}
  end

  def handle_info(:send_ping, data) do
    {:ok, conn, ref} = HTTP.ping(data.conn)

    Process.send_after(self(), :send_ping, 50)

    data =
      data
      |> put_in([:conn], conn)
      |> put_in([:pings, ref], %{}) # TODO - Track latency

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
        Logger.debug("Unknown message: #{inspect message}")
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
        IO.inspect(unhandled, label: "Unhandled")
        handle_responses(rs, data)
    end
  end
end
