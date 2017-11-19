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
      :ok = Logger.configure_backend(LoggerJSON, device: :user, level: nil, metadata: [], json_encoder: Poison)
    end)

    Logger.configure_backend(LoggerJSON, device: :standard_error, metadata: :all)
  end

  test "logs proper message" do
    log =
      capture_io(:standard_error, fn ->
        call(conn(:get, "/"))
        Logger.flush()
      end)

    assert %{
             "jsonPayload" => %{
               "message" => "",
               "metadata" => %{
                 "application" => "logger_json",
                 "client" => %{"ip" => "127.0.0.1", "user_agent" => nil, "version" => nil},
                 "connection" => %{
                   "method" => "GET",
                   "request_id" => nil,
                   "request_path" => "/",
                   "status" => 200,
                   "type" => "sent"
                 },
                 "latency" => _,
                 "runtime" => %{},
                 "system" => %{"hostname" => _, "pid" => _}
               }
             }
           } = Poison.decode!(log)

    conn = %{conn(:get, "/hello/world") | private: %{phoenix_controller: MyController, phoenix_action: :foo}}

    log =
      capture_io(:standard_error, fn ->
        call(conn)
        Logger.flush()
      end)

    assert %{
             "jsonPayload" => %{
               "message" => "",
               "metadata" => %{
                 "application" => "logger_json",
                 "client" => %{"ip" => "127.0.0.1", "user_agent" => nil, "version" => nil},
                 "connection" => %{
                   "method" => "GET",
                   "request_id" => nil,
                   "request_path" => "/hello/world",
                   "status" => 200,
                   "type" => "sent"
                 },
                 "latency" => _,
                 "runtime" => %{"controller" => "Elixir.MyController", "action" => "foo"},
                 "system" => %{"hostname" => _, "pid" => _}
               }
             }
           } = Poison.decode!(log)
  end

  test "logs message with values from headers" do
    request_id = Ecto.UUID.generate()
    conn =
      :get
      |> conn("/")
      |> Plug.Conn.put_resp_header("x-request-id", request_id)
      |> Plug.Conn.put_req_header("user-agent", "chrome")
      |> Plug.Conn.put_req_header("x-forwarded-for", "127.0.0.10")
      |> Plug.Conn.put_req_header("x-api-version", "2017-01-01")

    log =
      capture_io(:standard_error, fn ->
        call(conn)
        Logger.flush()
      end)

    assert %{
             "jsonPayload" => %{
               "message" => "",
               "metadata" => %{
                 "application" => "logger_json",
                 "client" => %{"ip" => "127.0.0.10", "user_agent" => "chrome", "version" => "2017-01-01"},
                 "connection" => %{
                   "method" => "GET",
                   "request_id" => ^request_id,
                   "request_path" => "/",
                   "status" => 200,
                   "type" => "sent"
                 },
                 "latency" => _,
                 "runtime" => %{},
                 "system" => %{"hostname" => _, "pid" => _}
               }
             }
           } = Poison.decode!(log)
  end

  defp call(conn) do
    MyPlug.call(conn, [])
  end
end
