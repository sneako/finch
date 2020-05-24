defmodule Finch.HTTP2Server do
  @moduledoc false

  @fixtures_dir Path.expand("../fixtures", __DIR__)

  def start(port) do
    children = [
      Plug.Adapters.Cowboy.child_spec(
        scheme: :https,
        plug: Finch.HTTP2Server.PlugRouter,
        options: [
          port: port,
          cipher_suite: :strong,
          certfile: Path.join([@fixtures_dir, "selfsigned.pem"]),
          keyfile: Path.join([@fixtures_dir, "selfsigned_key.pem"]),
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
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

defmodule Finch.HTTP2Server.PlugRouter do
  @moduledoc false

  use Plug.Router

  plug(:match)

  plug(:dispatch)

  get "/" do
    name = conn.params["name"] || "world"
    conn
    |> send_resp(200, "Hello #{name}!")
    |> halt()
  end

  get "/wait/:delay" do
    delay = conn.params["delay"] |> String.to_integer()
    Process.sleep(delay)
    send_resp(conn, 200, "ok")
  end
end
