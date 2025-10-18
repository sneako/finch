defmodule Finch.ALPNServer do
  @moduledoc false
  # A test server that supports ALPN negotiation between HTTP/1 and HTTP/2

  @fixtures_dir Path.expand("../fixtures", __DIR__)

  def child_spec(opts) do
    Plug.Cowboy.child_spec(
      scheme: :https,
      plug: Finch.ALPNServer.PlugRouter,
      options: [
        port: Keyword.fetch!(opts, :port),
        cipher_suite: :strong,
        certfile: Path.join([@fixtures_dir, "selfsigned.pem"]),
        keyfile: Path.join([@fixtures_dir, "selfsigned_key.pem"]),
        # Enable ALPN negotiation between HTTP/2 and HTTP/1.1
        alpn_preferred_protocols: ["h2", "http/1.1"],
        otp_app: :finch,
        protocol_options: [
          idle_timeout: 3_000,
          inactivity_timeout: 5_000,
          max_keepalive: 1_000,
          request_timeout: 10_000,
          shutdown_timeout: 10_000
        ]
      ]
    )
  end

  def start(port) do
    Supervisor.start_link([child_spec(port: port)], strategy: :one_for_one)
  end
end

defmodule Finch.ALPNServer.PlugRouter do
  @moduledoc false

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> send_resp(200, "Hello world!")
    |> halt()
  end

  post "/echo" do
    {:ok, body, conn} = read_body(conn)
    body_size = byte_size(body)

    response = Jason.encode!(%{received_bytes: body_size})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, response)
    |> halt()
  end
end
