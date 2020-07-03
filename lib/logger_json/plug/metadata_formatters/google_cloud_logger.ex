if Code.ensure_loaded?(Plug) do
  defmodule LoggerJSON.Plug.MetadataFormatters.GoogleCloudLogger do
    @moduledoc """
    This formatter builds a metadata which is natively supported by Google Cloud Logger:

      * `httpRequest` - see [LogEntry#HttpRequest](https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry#HttpRequest);
      * `client.api_version` - version of API that was requested by a client;
      * `phoenix.controller` - Phoenix controller that processed the request;
      * `phoenix.action` - Phoenix action that processed the request;
      * `node.hostname` - node hostname;
      * `node.vm_pid` - Erlang VM process identifier.
    """
    import Jason.Helpers, only: [json_map: 1]

    @nanoseconds_in_second System.convert_time_unit(1, :second, :nanosecond)

    @doc false
    def build_metadata(conn, latency, client_version_header) do
      latency_seconds = native_to_seconds(latency)
      request_method = conn.method
      request_path = conn.request_path
      request_url = request_url(conn)
      status = conn.status
      user_agent = LoggerJSON.Plug.get_header(conn, "user-agent")
      remote_ip = remote_ip(conn)
      referer = LoggerJSON.Plug.get_header(conn, "referer")
      {hostname, vm_pid} = node_metadata()

      client_metadata(conn, client_version_header) ++
        phoenix_metadata(conn) ++
        [
          httpRequest:
            json_map(
              requestMethod: request_method,
              requestPath: request_path,
              requestUrl: request_url,
              status: status,
              userAgent: user_agent,
              remoteIp: remote_ip,
              referer: referer,
              latency: latency_seconds
            ),
          node: json_map(hostname: to_string(hostname), vm_pid: vm_pid)
        ]
    end

    defp native_to_seconds(nil) do
      nil
    end

    defp native_to_seconds(native) do
      seconds = System.convert_time_unit(native, :native, :nanosecond) / @nanoseconds_in_second
      :erlang.float_to_binary(seconds, [{:decimals, 8}, :compact]) <> "s"
    end

    defp request_url(%{request_path: "/"} = conn), do: "#{conn.scheme}://#{conn.host}/"
    defp request_url(conn), do: "#{conn.scheme}://#{Path.join(conn.host, conn.request_path)}"

    defp remote_ip(conn) do
      LoggerJSON.Plug.get_header(conn, "x-forwarded-for") || to_string(:inet_parse.ntoa(conn.remote_ip))
    end

    defp client_metadata(conn, client_version_header) do
      if api_version = LoggerJSON.Plug.get_header(conn, client_version_header) do
        [client: json_map(api_version: api_version)]
      else
        []
      end
    end

    defp phoenix_metadata(%{private: %{phoenix_controller: controller, phoenix_action: action}}) do
      [phoenix: json_map(controller: controller, action: action)]
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
