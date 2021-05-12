if Code.ensure_loaded?(Plug) do
  defmodule LoggerJSON.Plug.MetadataFormatters.ELK do
    @moduledoc """
    Formats connection into Logger metadata:

      * `connection.type` - type of connection (Sent or Chunked);
      * `connection.method` - HTTP request method;
      * `connection.request_path` - HTTP request path;
      * `connection.status` - HTTP status code sent to a client;
      * `client.user_agent` - value of `User-Agent` header;
      * `client.ip' - value of `X-Forwarded-For` header if present, otherwise - remote IP of a connected client;
      * `client.api_version' - version of API that was requested by a client;
      * `node.hostname` - system hostname;
      * `node.vm_pid` - Erlang VM process identifier;
      * `phoenix.controller` - Phoenix controller that processed the request;
      * `phoenix.action` - Phoenix action that processed the request;
      * `latency_μs` - time in microseconds taken to process the request.
    """
    import Jason.Helpers, only: [json_map: 1]

    @doc false
    def build_metadata(conn, latency, client_version_header) do
      latency_μs = System.convert_time_unit(latency, :native, :microsecond)
      user_agent = LoggerJSON.PlugUtils.get_header(conn, "user-agent")
      ip = LoggerJSON.PlugUtils.remote_ip(conn)
      api_version = LoggerJSON.PlugUtils.get_header(conn, client_version_header)
      {hostname, vm_pid} = node_metadata()

      phoenix_metadata(conn) ++
        [
          connection:
            json_map(
              type: connection_type(conn),
              method: conn.method,
              request_path: conn.request_path,
              status: conn.status
            ),
          client:
            json_map(
              user_agent: user_agent,
              ip: ip,
              api_version: api_version
            ),
          node: json_map(hostname: to_string(hostname), vm_pid: vm_pid),
          latency_μs: latency_μs
        ]
    end

    defp connection_type(%{state: :set_chunked}), do: "chunked"
    defp connection_type(_), do: "sent"

    defp phoenix_metadata(%{private: %{phoenix_controller: controller, phoenix_action: action}}) do
      [phoenix: %{controller: controller, action: action}]
    end

    defp phoenix_metadata(_conn) do
      []
    end

    defp node_metadata do
      {:ok, hostname} = :inet.gethostname()

      vm_pid =
        case Integer.parse(System.get_pid()) do
          {pid, _units} -> pid
          _ -> nil
        end

      {hostname, vm_pid}
    end
  end
end
