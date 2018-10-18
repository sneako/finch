defmodule LoggerJSON.Formatters.GoogleCloudLogger do
  @moduledoc """
  Google Cloud Logger formatter.
  """
  @behaviour LoggerJSON.Formatter

  @processed_metadata_keys ~w[pid file line function module application]a

  @doc """
  Builds a map that corresponds to Google Cloud Logger
  [`LogEntry`](https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry) format.
  """
  def format_event(level, msg, ts, md, md_keys) do
    %{
      timestamp: format_timestamp(ts),
      severity: format_severity(level),
      jsonPayload: %{
        message: IO.iodata_to_binary(msg),
        metadata: format_metadata(md, md_keys)
      },
      labels: format_labels(md),
      sourceLocation: format_source_location(md)
    }
  end

  defp format_labels(md) do
    if application = Keyword.get(md, :application) do
      application_version = IO.iodata_to_binary(Application.spec(application, :vsn))

      %{
        type: "elixir-application",
        application_name: application,
        application_version: application_version
      }
    end
  end

  defp format_metadata(md, md_keys) do
    md
    |> LoggerJSON.take_metadata(md_keys, @processed_metadata_keys)
    |> maybe_put_initial_call(md[:initial_call])
    |> maybe_put_crash_reason(md[:crash_reason])
  end

  defp maybe_put_initial_call(md, nil), do: md

  defp maybe_put_initial_call(md, {module, fun, arity}) do
    Map.put(md, :initial_call, "#{module}.#{fun}/#{arity}")
  end

  defp maybe_put_crash_reason(md, nil), do: md

  defp maybe_put_crash_reason(md, {reason, stacktrace}) do
    md
    |> Map.put(:crash_reason, inspect(reason))
    |> Map.put(:crash_reason_stacktrace, inspect(stacktrace))
  end

  # RFC3339 UTC "Zulu" format
  defp format_timestamp({date, time}) do
    [format_date(date), format_time(time)]
    |> Enum.map(&IO.iodata_to_binary/1)
    |> Enum.join("T")
    |> Kernel.<>("Z")
  end

  # Description can be found in Google Cloud Logger docs;
  # https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry#LogEntrySourceLocation
  defp format_source_location(metadata) do
    file = Keyword.get(metadata, :file)
    line = Keyword.get(metadata, :line, 0)
    function = Keyword.get(metadata, :function)
    module = Keyword.get(metadata, :module)

    %{
      file: file,
      line: line,
      function: format_function(module, function)
    }
  end

  defp format_function(nil, function), do: function
  defp format_function(module, function), do: to_string(module) <> "." <> to_string(function)

  # Severity levels can be found in Google Cloud Logger docs:
  # https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry#LogSeverity
  defp format_severity(:debug), do: "DEBUG"
  defp format_severity(:info), do: "INFO"
  defp format_severity(:warn), do: "WARNING"
  defp format_severity(:error), do: "ERROR"
  defp format_severity(nil), do: "DEFAULT"

  defp format_time({hh, mi, ss, ms}) do
    [pad2(hh), ?:, pad2(mi), ?:, pad2(ss), ?., pad3(ms)]
  end

  defp format_date({yy, mm, dd}) do
    [Integer.to_string(yy), ?-, pad2(mm), ?-, pad2(dd)]
  end

  defp pad3(int) when int < 10, do: [?0, ?0, Integer.to_string(int)]
  defp pad3(int) when int < 100, do: [?0, Integer.to_string(int)]
  defp pad3(int), do: Integer.to_string(int)

  defp pad2(int) when int < 10, do: [?0, Integer.to_string(int)]
  defp pad2(int), do: Integer.to_string(int)
end
