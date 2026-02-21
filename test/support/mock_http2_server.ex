defmodule Finch.MockHTTP2Server do
  @moduledoc false
  import ExUnit.Assertions
  alias Mint.HTTP2.Frame

  defstruct [
    :socket,
    :listen_socket,
    :server_settings,
    :encode_table,
    :decode_table,
    :pending_settings
  ]

  @fixtures_dir Path.expand("../fixtures", __DIR__)

  @ssl_opts [
    mode: :binary,
    packet: :raw,
    active: false,
    reuseaddr: true,
    next_protocols_advertised: ["h2"],
    alpn_preferred_protocols: ["h2"],
    certfile: Path.join([@fixtures_dir, "selfsigned.pem"]),
    keyfile: Path.join([@fixtures_dir, "selfsigned_key.pem"])
  ]

  def start_and_connect_with(options, fun) when is_list(options) and is_function(fun, 1) do
    parent = self()
    server_settings = Keyword.get(options, :server_settings, [])
    defer_settings? = Keyword.get(options, :defer_settings, false)

    {:ok, listen_socket} = :ssl.listen(0, @ssl_opts)
    {:ok, {_address, port}} = :ssl.sockname(listen_socket)

    task = Task.async(fn -> accept(listen_socket, parent, server_settings, defer_settings?) end)

    result = fun.(port)

    {:ok, server_socket} = Task.await(task)
    :ok = :ssl.setopts(server_socket, active: true)

    server = %__MODULE__{
      socket: server_socket,
      listen_socket: listen_socket,
      server_settings: server_settings,
      encode_table: HPAX.new(4096),
      decode_table: HPAX.new(4096),
      pending_settings: if(defer_settings?, do: server_settings, else: nil)
    }

    {result, server}
  end

  @spec recv_next_frames(%__MODULE__{}, pos_integer()) :: [frame :: term(), ...]
  def recv_next_frames(%__MODULE__{} = server, frame_count) when frame_count > 0 do
    recv_next_frames(server, frame_count, [], "")
  end

  defp recv_next_frames(_server, 0, frames, buffer) do
    if buffer == "" do
      Enum.reverse(frames)
    else
      flunk("Expected no more data, got: #{inspect(buffer)}")
    end
  end

  defp recv_next_frames(%{socket: server_socket} = server, n, frames, buffer) do
    assert_receive {:ssl, ^server_socket, data}, 100
    decode_next_frames(server, n, frames, buffer <> data)
  end

  defp decode_next_frames(_server, 0, frames, buffer) do
    if buffer == "" do
      Enum.reverse(frames)
    else
      flunk("Expected no more data, got: #{inspect(buffer)}")
    end
  end

  defp decode_next_frames(server, n, frames, data) do
    case Frame.decode_next(data) do
      {:ok, frame, rest} ->
        decode_next_frames(server, n - 1, [frame | frames], rest)

      :more ->
        recv_next_frames(server, n, frames, data)

      other ->
        flunk("Error decoding frame: #{inspect(other)}")
    end
  end

  @spec encode_headers(%__MODULE__{}, Mint.Types.headers()) :: {%__MODULE__{}, hbf :: binary()}
  def encode_headers(%__MODULE__{} = server, headers) when is_list(headers) do
    headers = for {name, value} <- headers, do: {:store_name, name, value}
    {hbf, encode_table} = HPAX.encode(headers, server.encode_table)
    server = put_in(server.encode_table, encode_table)
    {server, IO.iodata_to_binary(hbf)}
  end

  @spec decode_headers(%__MODULE__{}, binary()) :: {%__MODULE__{}, Mint.Types.headers()}
  def decode_headers(%__MODULE__{} = server, hbf) when is_binary(hbf) do
    assert {:ok, headers, decode_table} = HPAX.decode(hbf, server.decode_table)
    server = put_in(server.decode_table, decode_table)
    {server, headers}
  end

  def send_frames(%__MODULE__{socket: socket}, frames) when is_list(frames) and frames != [] do
    # TODO: split the data at random places to increase fuzziness.
    data = Enum.map(frames, &Frame.encode/1)
    :ok = :ssl.send(socket, data)
  end

  @spec get_socket(%__MODULE__{}) :: :ssl.sslsocket()
  def get_socket(server) do
    server.socket
  end

  @doc """
  Accept a new connection on the same listen socket (for reconnect tests).
  Returns a new server struct with fresh HPAX tables and the new socket.
  """
  @spec accept_socket(%__MODULE__{}) :: %__MODULE__{}
  def accept_socket(
        %__MODULE__{listen_socket: listen_socket, server_settings: server_settings} = server
      ) do
    {:ok, socket} = :ssl.transport_accept(listen_socket, 5_000)
    {:ok, socket} = :ssl.handshake(socket)
    :ok = perform_http2_handshake(socket, server_settings)
    :ok = :ssl.setopts(socket, active: true)

    %__MODULE__{
      server
      | socket: socket,
        encode_table: HPAX.new(4096),
        decode_table: HPAX.new(4096),
        pending_settings: nil
    }
  end

  defp accept(listen_socket, parent, server_settings, defer_settings?) do
    {:ok, socket} = :ssl.transport_accept(listen_socket)
    {:ok, socket} = :ssl.handshake(socket)

    if defer_settings? do
      :ok = perform_http2_handshake_deferred(socket)
    else
      :ok = perform_http2_handshake(socket, server_settings)
    end

    # We transfer ownership of the socket to the parent so that this task can die.
    :ok = :ssl.controlling_process(socket, parent)
    {:ok, socket}
  end

  connection_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  defp perform_http2_handshake_deferred(socket) do
    import Mint.HTTP2.Frame, only: [settings: 1]

    no_flags = Frame.set_flags(:settings, [])

    # Receive connection preface (and possibly client SETTINGS in same packet).
    {:ok, data} = :ssl.recv(socket, 0, 5_000)
    assert String.starts_with?(data, unquote(connection_preface))

    rest =
      binary_part(
        data,
        byte_size(unquote(connection_preface)),
        byte_size(data) - byte_size(unquote(connection_preface))
      )

    # Receive and decode the client SETTINGS frame (may need more data).
    {frame, _rest} = recv_settings_frame(socket, rest)
    assert settings(flags: ^no_flags, params: _params) = frame

    # We do not send our SETTINGS yet; the test will call send_server_settings/1 later.
    :ok
  end

  defp recv_settings_frame(socket, buffer) do
    case Frame.decode_next(buffer) do
      {:ok, frame, rest} ->
        {frame, rest}

      :more ->
        {:ok, more} = :ssl.recv(socket, 0, 5_000)
        recv_settings_frame(socket, buffer <> more)
    end
  end

  defp perform_http2_handshake(socket, server_settings) do
    import Mint.HTTP2.Frame, only: [settings: 1]

    no_flags = Frame.set_flags(:settings, [])
    ack_flags = Frame.set_flags(:settings, [:ack])

    # First we get the connection preface.
    {:ok, unquote(connection_preface) <> rest} = :ssl.recv(socket, 0, 100)

    # Then we get a SETTINGS frame.
    assert {:ok, frame, ""} = Frame.decode_next(rest)
    assert settings(flags: ^no_flags, params: _params) = frame

    # We reply with our SETTINGS.
    :ok = :ssl.send(socket, Frame.encode(settings(params: server_settings)))

    # We get the SETTINGS ack.
    {:ok, data} = :ssl.recv(socket, 0, 100)
    assert {:ok, frame, ""} = Frame.decode_next(data)
    assert settings(flags: ^ack_flags, params: []) = frame

    # We send the SETTINGS ack back.
    :ok = :ssl.send(socket, Frame.encode(settings(flags: ack_flags, params: [])))

    :ok
  end

  @doc """
  Send the server SETTINGS frame that was deferred during handshake.
  Receives the client's SETTINGS ack and sends our ack. Only valid when
  the server was started with `defer_settings: true`.
  """
  @spec send_server_settings(%__MODULE__{}) :: :ok
  def send_server_settings(%__MODULE__{socket: socket, pending_settings: settings})
      when is_list(settings) do
    import Mint.HTTP2.Frame, only: [settings: 1]

    ack_flags = Frame.set_flags(:settings, [:ack])

    :ok = :ssl.send(socket, Frame.encode(settings(params: settings)))

    assert_receive {:ssl, ^socket, data}, 1_000
    assert {:ok, frame, ""} = Frame.decode_next(data)
    assert settings(flags: ^ack_flags, params: []) = frame

    :ok = :ssl.send(socket, Frame.encode(settings(flags: ack_flags, params: [])))

    :ok
  end
end
