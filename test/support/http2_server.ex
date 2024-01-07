defmodule Finch.HTTP2Server do
  @moduledoc false

  @fixtures_dir Path.expand("../fixtures", __DIR__)

  def child_spec(opts) do
    Plug.Cowboy.child_spec(
      scheme: :https,
      plug: Finch.HTTP2Server.PlugRouter,
      options: [
        port: Keyword.fetch!(opts, :port),
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
  end

  def start(port) do
    Supervisor.start_link([child_spec(port: port)], strategy: :one_for_one)
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

  get "/query" do
    conn = fetch_query_params(conn)
    response = URI.encode_query(conn.query_params)

    conn
    |> send_resp(200, response)
    |> halt()
  end

  get "/wait/:delay" do
    delay = conn.params["delay"] |> String.to_integer()
    Process.sleep(delay)
    send_resp(conn, 200, "ok")
  end

  get "/stream/:num/:delay" do
    num = conn.params["num"] |> String.to_integer()
    delay = conn.params["delay"] |> String.to_integer()
    conn = send_chunked(conn, 200)

    Enum.reduce(1..num, conn, fn i, conn ->
      Process.sleep(delay)
      {:ok, conn} = chunk(conn, "chunk-#{i}\n")
      conn
    end)
  end
end
