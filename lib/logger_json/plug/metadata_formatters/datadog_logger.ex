if Code.ensure_loaded?(Plug) do
  defmodule LoggerJSON.Plug.MetadataFormatters.DatadogLogger do
    @moduledoc """
    This formatter builds a metadata which is natively supported by Datadog:

      * `http` - see [DataDog](https://docs.datadoghq.com/logs/processing/attributes_naming_convention/#http-requests);
      * `phoenix.controller` - Phoenix controller that processed the request;
      * `phoenix.action` - Phoenix action that processed the request;
    """
    import Jason.Helpers, only: [json_map: 1]

    @doc false
    def build_metadata(conn, latency, client_version_header) do
      client_metadata(conn, client_version_header) ++
        phoenix_metadata(conn) ++
        [
          duration: native_to_nanoseconds(latency),
          http:
            json_map(
              url: request_url(conn),
              status_code: conn.status,
              method: conn.method,
              referer: LoggerJSON.PlugUtils.get_header(conn, "referer"),
              request_id: Keyword.get(Logger.metadata(), :request_id),
              useragent: LoggerJSON.PlugUtils.get_header(conn, "user-agent"),
              url_details:
                json_map(
                  host: conn.host,
                  port: conn.port,
                  path: conn.request_path,
                  queryString: conn.query_string,
                  scheme: conn.scheme
                )
            ),
          network: json_map(client: json_map(ip: LoggerJSON.PlugUtils.remote_ip(conn)))
        ]
    end

    defp native_to_nanoseconds(nil) do
      nil
    end

    defp native_to_nanoseconds(native) do
      System.convert_time_unit(native, :native, :nanosecond)
    end

    defp request_url(%{request_path: "/"} = conn), do: "#{conn.scheme}://#{conn.host}/"
    defp request_url(conn), do: "#{conn.scheme}://#{Path.join(conn.host, conn.request_path)}"

    defp client_metadata(conn, client_version_header) do
      if api_version = LoggerJSON.PlugUtils.get_header(conn, client_version_header) do
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
  end
end
