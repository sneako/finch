{:ok, listen_socket} = :ssl.listen(0, mode: :binary)
{:ok, {_address, port}} = :ssl.sockname(listen_socket)
:ssl.close(listen_socket)

Finch.HTTP2Server.start(port)
Application.put_env(:finch, :test_https_h2_url, "https://localhost:#{port}")

Mimic.copy(Mint.HTTP)

ExUnit.start()
Application.ensure_all_started(:bypass)
