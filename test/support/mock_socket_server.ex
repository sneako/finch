defmodule Finch.MockSocketServer do
  @moduledoc false

  @fixtures_dir Path.expand("../fixtures", __DIR__)

  @socket_opts [
    active: false,
    mode: :binary,
    packet: :raw
  ]

  @ssl_opts [
    reuseaddr: true,
    nodelay: true,
    certfile: Path.join([@fixtures_dir, "selfsigned.pem"]),
    keyfile: Path.join([@fixtures_dir, "selfsigned_key.pem"])
  ]

  @http_response "HTTP/1.1 200 OK\r\n\r\n"

  def start(opts \\ []) do
    ssl? = Keyword.get(opts, :ssl?, false)

    socket_address = build_socket_address()
    delete_existing_sockets(socket_address)

    {:ok, socket} = listen(socket_address, ssl?)

    spawn_link(fn ->
      {:ok, client} = accept(socket, ssl?)

      serve(client, ssl?)
    end)

    {:ok, socket_address}
  end

  defp build_socket_address do
    name = "finch_mock_socket_server.sock"
    socket_path = System.tmp_dir!() |> Path.join(name)

    {:local, socket_path}
  end

  defp delete_existing_sockets({:local, socket_path}) do
    File.rm(socket_path)
  end

  defp listen(socket_address, false = _ssl?) do
    opts = [{:ifaddr, socket_address} | @socket_opts]

    :gen_tcp.listen(0, opts)
  end

  defp listen(socket_address, true = _ssl?) do
    base_opts = @socket_opts ++ @ssl_opts
    opts = [{:ifaddr, socket_address} | base_opts]

    :ssl.listen(0, opts)
  end

  defp accept(socket, false = _ssl?) do
    {:ok, _client} = :gen_tcp.accept(socket)
  end

  defp accept(socket, true = _ssl?) do
    {:ok, client} = :ssl.transport_accept(socket)

    if function_exported?(:ssl, :handshake, 1) do
      {:ok, _} = apply(:ssl, :handshake, [client])
    else
      :ok = apply(:ssl, :ssl_accept, [client])
    end

    {:ok, client}
  end

  defp serve(client, false = ssl?) do
    case :gen_tcp.recv(client, 0) do
      {:ok, _data} ->
        :gen_tcp.send(client, @http_response)
        :gen_tcp.close(client)

      _ ->
        serve(client, ssl?)
    end
  end

  defp serve(client, true = ssl?) do
    case :ssl.recv(client, 0) do
      {:ok, _data} ->
        :ssl.send(client, @http_response)
        :ssl.close(client)

      _ ->
        serve(client, ssl?)
    end
  end
end
