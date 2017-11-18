defmodule LoggerJSON.Formatters.GoogleCloudLogger do
  @moduledoc """
  Google Cloud Logger formatter.
  """
  @behaviour LoggerJSON.Formatter

  @doc """
  Builds a map that corresponds to Google Cloud Logger
  [`LogEntry`](https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry) format.
  """
  def format_event(level, msg, ts, md, md_keys) do
    %{
      timestamp: format_time(ts),
      severity: format_severity(level),
      jsonPayload: %{
        message: format_message(msg),
        metadata: format_metadata(md, md_keys),
      },
      resource: format_resource(md),
      sourceLocation: format_source_location(md),
    }
  end

  defp format_message(map) when is_map(map), do: map
  defp format_message(binary) when is_binary(binary), do: binary
  defp format_message([{_k, _v} | _] = keyword), do: keyword
  defp format_message(iolist) when is_list(iolist), do: IO.iodata_to_binary(iolist)

  defp format_resource(md) do
    application = Keyword.get(md, :application)
    if application do
      %{
        type: "elixir-application",
        labels: %{
          service: application,
          version: Application.spec(application, :vsn)
        }
      }
    end
  end

  defp format_metadata(md, md_keys) do
    md
    |> Keyword.drop([:pid, :file, :line, :function, :module, :ansi_color])
    |> LoggerJSON.take_metadata(md_keys)
  end

  # RFC3339 UTC "Zulu" format
  defp format_time({date, time}) do
    [Logger.Formatter.format_date(date), Logger.Formatter.format_time(time)]
    |> Enum.map(&IO.iodata_to_binary/1)
    |> Enum.join("T")
    |> Kernel.<>("Z")
  end

  # Description can be found in Google Cloud Logger docs;
  # https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry#LogEntrySourceLocation
  defp format_source_location(metadata) do
    file = Keyword.get(metadata, :file)
    line = Keyword.get(metadata, :line)
    function = Keyword.get(metadata, :function)
    module = Keyword.get(metadata, :module)

    %{
      file: file,
      line: line,
      function: format_function(module, function)
    }
  end

  defp format_function(nil, function),
    do: function
  defp format_function(module, function),
    do: to_string(module) <> "." <> to_string(function)

  # Severity levels can be found in Google Cloud Logger docs:
  # https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry#LogSeverity
  defp format_severity(:debug),
    do: "DEBUG"
  defp format_severity(:info),
    do: "INFO"
  defp format_severity(:warn),
    do: "WARNING"
  defp format_severity(:error),
    do: "ERROR"
  defp format_severity(nil),
    do: "DEFAULT"
end
