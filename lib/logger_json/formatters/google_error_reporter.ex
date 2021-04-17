defmodule LoggerJSON.Formatters.GoogleErrorReporter do
  @moduledoc """
  Google Error Reporter formatter.
  """
  require Logger
  @googleErrorType "type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ReportedErrorEvent"

  def report(kind, reason, stacktrace, metadata \\ []) do
    [format_banner(kind, reason, stacktrace) | format_stacktrace(stacktrace)]
    |> Enum.join("\n")
    |> Logger.error(Keyword.merge(build_metadata(), metadata))
  end

  defp format_banner(kind, reason, stacktrace) do
    Exception.format_banner(kind, reason, stacktrace)
  end

  defp format_stacktrace(stacktrace) do
    lines =
      Exception.format_stacktrace(stacktrace)
      |> String.trim_trailing()
      |> String.split("\n")
      |> Enum.map(&format_line/1)
      |> Enum.group_by(fn {kind, _line} -> kind end)

    format_lines(:trace, lines[:trace]) ++ format_lines(:context, lines[:context]) ++ [""]
  end

  defp format_line(line) do
    case Regex.run(~r/(.+)\:(\d+)\: (.*)/, line) do
      [_, file, line, function] -> {:trace, "#{file}:#{line}:in `#{function}'"}
      _ -> {:context, line}
    end
  end

  defp format_lines(_kind, nil) do
    []
  end

  defp format_lines(:trace, lines) do
    Enum.map(lines, fn {:trace, line} -> line end)
  end

  defp format_lines(:context, lines) do
    ["Context:" | Enum.map(lines, fn {:context, line} -> line end)]
  end

  defp build_metadata() do
    ["@type": @googleErrorType]
    |> with_service_context()
  end

  defp with_service_context(metadata) do
    if service_context = config()[:service_context] do
      Keyword.merge(metadata, serviceContext: service_context)
    else
      metadata
    end
  end

  defp config do
    Application.get_env(:logger_json, :google_error_reporter, [])
  end
end
