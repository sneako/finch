defmodule Finch.MockSocketServer do
  @moduledoc false

  @http_response "HTTP/1.1 200 OK\r\n\r\n"

  def start do
    socket_address = build_socket_address()
    delete_existing_sockets(socket_address)

    {:ok, socket} = listen(socket_address)

    spawn_link(fn ->
      {:ok, client} = accept(socket)

      serve(client)
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

  defp listen(socket_address) do
    opts = [active: false, mode: :binary, packet: :raw, ifaddr: socket_address]

    :gen_tcp.listen(0, opts)
  end

  defp accept(socket) do
    {:ok, _client} = :gen_tcp.accept(socket)
  end

  defp serve(client) do
    case :gen_tcp.recv(client, 0) do
      {:ok, _data} ->
        :gen_tcp.send(client, @http_response)
        :gen_tcp.close(client)

      _ ->
        serve(client)
    end
  end
end
