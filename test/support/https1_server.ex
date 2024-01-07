defmodule Finch.HTTPS1Server do
  @moduledoc false

  @fixtures_dir Path.expand("../fixtures", __DIR__)

  def start(port) do
    children = [
      Plug.Adapters.Cowboy.child_spec(
        scheme: :https,
        plug: Finch.HTTP1Server.PlugRouter,
        options: [
          port: port,
          otp_app: :finch,
          cipher_suite: :strong,
          certfile: Path.join([@fixtures_dir, "selfsigned.pem"]),
          keyfile: Path.join([@fixtures_dir, "selfsigned_key.pem"]),
          alpn_preferred_protocols: ["undefined"],
          protocol_options: [
            idle_timeout: 3_000,
            request_timeout: 10_000
          ]
        ]
      )
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

defmodule Finch.HTTPS1Server.PlugRouter do
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
end
