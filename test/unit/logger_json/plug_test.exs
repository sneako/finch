defmodule LoggerJSON.PlugTest do
  use Logger.Case
  use Plug.Test
  import ExUnit.CaptureIO
  require Logger

  defmodule MyPlug do
    use Plug.Builder

    plug(LoggerJSON.Plug)
    plug(:passthrough)

    defp passthrough(conn, _) do
      Plug.Conn.send_resp(conn, 200, "Passthrough")
    end
  end

  setup do
    on_exit(fn ->
      :ok = Logger.configure_backend(LoggerJSON, device: :user, level: nil, metadata: [], json_encoder: Jason)
    end)

    Logger.configure_backend(LoggerJSON, device: :standard_error, metadata: :all)
  end

  test "logs request information" do
    Logger.metadata(request_id: "request_id")

    log =
      capture_io(:standard_error, fn ->
        call(conn(:get, "/"))
        Logger.flush()
      end)

    assert %{
             "message" => "",
             "httpRequest" => %{
               "latency" => latency,
               "referer" => nil,
               "remoteIp" => "127.0.0.1",
               "requestMethod" => "GET",
               "requestPath" => "/",
               "requestUrl" => "http://www.example.com/",
               "status" => 200,
               "userAgent" => nil
             },
             "logging.googleapis.com/operation" => %{"id" => "request_id"},
             "severity" => "INFO"
           } = Jason.decode!(log)

    assert {latency_number, "s"} = Float.parse(latency)
    assert latency_number > 0

    conn = %{conn(:get, "/hello/world") | private: %{phoenix_controller: MyController, phoenix_action: :foo}}

    log =
      capture_io(:standard_error, fn ->
        call(conn)
        Logger.flush()
      end)

    assert %{
             "httpRequest" => %{
               "requestUrl" => "http://www.example.com/hello/world"
             },
             "phoenix" => %{
               "action" => "foo",
               "controller" => "Elixir.MyController"
             }
           } = Jason.decode!(log)
  end

  test "takes values from request headers" do
    request_id = Ecto.UUID.generate()

    conn =
      :get
      |> conn("/")
      |> Plug.Conn.put_resp_header("x-request-id", request_id)
      |> Plug.Conn.put_req_header("user-agent", "chrome")
      |> Plug.Conn.put_req_header("referer", "http://google.com")
      |> Plug.Conn.put_req_header("x-forwarded-for", "127.0.0.10")
      |> Plug.Conn.put_req_header("x-api-version", "2017-01-01")

    log =
      capture_io(:standard_error, fn ->
        call(conn)
        Logger.flush()
      end)

    assert %{
             "httpRequest" => %{
               "referer" => "http://google.com",
               "remoteIp" => "127.0.0.10",
               "userAgent" => "chrome"
             }
           } = Jason.decode!(log)
  end

  defp call(conn) do
    MyPlug.call(conn, [])
  end
end
