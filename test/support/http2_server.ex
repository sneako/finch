defmodule Finch.HTTP2Server do
  def start do
    children = [
      Plug.Adapters.Cowboy.child_spec(
        scheme: :https,
        plug: Finch.HTTP2Server.PlugRouter,
        options: [
          port: 4000,
          cipher_suite: :strong,
          certfile: "priv/cert/selfsigned.pem",
          keyfile: "priv/cert/selfsigned_key.pem",
          otp_app: :finch,
          protocol_options: [
            idle_timeout: 3_000,
            inactivity_timeout: 5_000,
            max_keepalive: 1_000,
            request_timeout: 10_000,
            shutdown_timeout: 10_000,
          ],
        ]
      ),
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

defmodule Finch.HTTP2Server.PlugRouter do
  use Plug.Router

  plug(:match)

  plug(:dispatch)

  get "/" do
    name = conn.params["name"] || "world"
    send_resp(conn, 200, "Hello #{name}!")
  end

  get "/wait/:delay" do
    delay = conn.params["delay"] |> String.to_integer()
    Process.sleep(delay)
    send_resp(conn, 200, "ok")
  end
end
