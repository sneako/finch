defmodule LoggerJSON.Formatters.DatadogLogger do
  @moduledoc """
  DataDog formatter.

  Adhere to the
  [default standard attribute list](https://docs.datadoghq.com/logs/processing/attributes_naming_convention/#default-standard-attribute-list).
  """
  import Jason.Helpers, only: [json_map: 1]

  alias LoggerJSON.{FormatterUtils, JasonSafeFormatter}

  @behaviour LoggerJSON.Formatter

  @processed_metadata_keys ~w[pid file line function module application]a

  def format_event(level, msg, ts, md, md_keys) do
    Map.merge(
      %{
        logger:
          json_map(
            thread_name: inspect(Keyword.get(md, :pid)),
            method_name: method_name(md)
          ),
        message: IO.chardata_to_string(msg),
        syslog:
          json_map(
            hostname: node_hostname(),
            severity: Atom.to_string(level),
            timestamp: FormatterUtils.format_timestamp(ts)
          )
      },
      format_metadata(md, md_keys)
    )
  end

  defp format_metadata(md, md_keys) do
    LoggerJSON.take_metadata(md, md_keys, @processed_metadata_keys)
    |> JasonSafeFormatter.format()
    |> FormatterUtils.maybe_put(:error, FormatterUtils.format_process_crash(md))
  end

  defp method_name(metadata) do
    function = Keyword.get(metadata, :function)
    module = Keyword.get(metadata, :module)

    FormatterUtils.format_function(module, function)
  end

  defp node_hostname do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  end
end
