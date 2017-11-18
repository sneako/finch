defmodule LoggerJSON.Plug do
  @moduledoc """
  Implements Plug behaviour and sends connection stats to Logger with metadata:

    * `connection.type` - type of connection (Sent or Chunked);
    * `connection.method` - HTTP request method;
    * `connection.request_path` - HTTP request path;
    * `connection.request_id` - value of `X-Request-ID` response header (see `Plug.RequestId`);
    * `connection.status` - HTTP status code sent to a client;
    * `client.user_agent' - value of `User-Agent` header;
    * `client.ip' - value of `X-Forwarded-For` header if present, otherwise - remote IP of a connected client;
    * `client.version' - value of `X-API-Version` header;
    * `system.hostname` - system hostname;
    * `system.pid` - Erlang VM process identifier;
    * `runtime.controller` - Phoenix controller that processed the request;
    * `runtime.action` - Phoenix action that processed the request;
    * `time` - time in microseconds taken to process the request.
  """
  alias Plug.Conn
  require Logger

  @behaviour Plug

  @impl true
  def init(opts) do
    Keyword.get(opts, :log, :info)
  end

  @impl true
  def call(conn, level) do
    start = System.monotonic_time()
    Conn.register_before_send(conn, fn conn ->
      diff = format_time(System.monotonic_time() - start)
      Logger.log(level, "", request_metadata(conn, diff))
      conn
    end)
  end

  defp request_metadata(conn, diff) do
    [
      connection: %{
        type: connection_type(conn),
        method: conn.method,
        request_path: conn.request_path,
        request_id: request_id(conn),
        status: conn.status,
      },
      client: client_info(conn),
      system: system_info(),
      runtime: runtime_info(conn),
      latency: diff,
    ]
  end

  defp format_time(nil), do: nil
  defp format_time(time), do: div(System.convert_time_unit(time, :native, :micro_seconds), 100) / 10

  defp connection_type(%{state: :set_chunked}), do: "chunked"
  defp connection_type(_), do: "sent"

  defp system_info do
    hostname =
      case :inet.gethostname() do
        {:ok, hostname} -> to_string(hostname)
        _else -> nil
      end

    pid =
      case Integer.parse(System.get_pid()) do
        {pid, _units} -> pid
        _ -> nil
      end

    %{hostname: hostname, pid: pid}
  end

  defp request_id(conn) do
    case Conn.get_resp_header(conn, "x-request-id") do
      [] -> nil
      [val | _] -> val
    end
  end

  defp client_info(conn) do
    %{
      user_agent: get_header(conn, "user-agent"),
      ip: get_header(conn, "x-forwarded-for") || to_string(:inet_parse.ntoa(conn.remote_ip)),
      version: get_header(conn, "x-api-version"),
    }
  end

  defp runtime_info(%{private: %{phoenix_controller: controller, phoenix_action: action}}),
    do: %{controller: Atom.to_string(controller), action: Atom.to_string(action)}
  defp runtime_info(_conn),
    do: %{}

  defp get_header(conn, header) do
    case Conn.get_req_header(conn, header) do
      [] -> nil
      [val | _] -> val
    end
  end
end
