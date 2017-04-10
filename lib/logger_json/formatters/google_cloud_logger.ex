defmodule LoggerJSON.Formatters.GoogleCloudLogger do
  @moduledoc """
  Google Cloud Logger formatter.
  """
  @behaviour LoggerJSON.Formatter

  @doc """
  Builds a map that corresponds to Google Cloud Logger
  [`LogLine`](https://cloud.google.com/logging/docs/reference/v1beta3/rest/v1beta3/LogLine) format.
  """
  def format_event(level, msg, ts, md, md_keys) do
    %{
      time: format_time(ts),
      severity: format_severity(level),
      logMessage: IO.iodata_to_binary(msg),
      sourceLocation: format_source_location(md),
      metadata: format_metadata(md, md_keys)
    }
  end

  defp format_metadata(md, md_keys) do
    md
    |> Keyword.drop([:pid, :file, :line, :function, :module])
    |> LoggerJSON.take_metadata(md_keys)
  end

  # RFC3339 UTC "Zulu" format
  defp format_time({date, time}) do
    [Logger.Utils.format_date(date), Logger.Utils.format_time(time)]
    |> Enum.map(&IO.iodata_to_binary/1)
    |> Enum.join("T")
    |> Kernel.<>("Z")
  end

  # Description can be found in Google Cloud Logger docs;
  # https://cloud.google.com/logging/docs/reference/v1beta3/rest/v1beta3/LogLine#SourceLocation
  defp format_source_location(metadata) do
    file = Keyword.get(metadata, :file)
    line = Keyword.get(metadata, :line)
    function = Keyword.get(metadata, :function)
    module = Keyword.get(metadata, :module)

    %{
      file: file,
      line: line,
      functionName: function,
      moduleName: module
    }
  end

  # Severity levels can be found in Google Cloud Logger docs:
  # https://cloud.google.com/logging/docs/reference/v1beta3/rest/v1beta3/projects.logs.entries/write#LogSeverity
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
