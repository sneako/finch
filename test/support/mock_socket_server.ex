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

  def start(opts \\ []) do
    transport = Keyword.get(opts, :transport, :gen_tcp)
    handler = Keyword.get(opts, :handler, &default_handler/2)
    address = Keyword.get(opts, :address)

    {:ok, socket} = listen(transport, address)

    spawn_link(fn ->
      {:ok, client} = accept(transport, socket)
      serve(transport, client, handler)
    end)

    {:ok, socket}
  end

  defp listen(transport, nil) do
    transport.listen(0, socket_opts(transport))
  end

  defp listen(transport, {:local, path}) do
    socket_opts = [ifaddr: {:local, path}] ++ socket_opts(transport)
    transport.listen(0, socket_opts)
  end

  defp socket_opts(:gen_tcp), do: @socket_opts
  defp socket_opts(:ssl), do: @socket_opts ++ @ssl_opts

  defp accept(:gen_tcp, socket) do
    {:ok, _client} = :gen_tcp.accept(socket)
  end

  defp accept(:ssl, socket) do
    {:ok, client} = :ssl.transport_accept(socket)

    if function_exported?(:ssl, :handshake, 1) do
      {:ok, _} = apply(:ssl, :handshake, [client])
    else
      :ok = apply(:ssl, :ssl_accept, [client])
    end

    {:ok, client}
  end

  defp serve(transport, client, handler) do
    case transport.recv(client, 0) do
      {:ok, _data} ->
        handler.(transport, client)
        transport.close(client)

      _ ->
        serve(transport, client, handler)
    end
  end

  defp default_handler(transport, socket) do
    :ok = transport.send(socket, "HTTP/1.1 200 OK\r\n\r\n")
  end
end
