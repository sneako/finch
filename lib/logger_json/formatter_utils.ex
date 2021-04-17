defmodule LoggerJSON.FormatterUtils do
  @moduledoc """
  This module contains functions that can be used across different
  `LoggerJSON.Formatter` implementations to provide common functionality.
  """

  import Jason.Helpers, only: [json_map: 1]

  @doc """
  Format an exception for use within a log entry.
  """
  def format_process_crash(md) do
    if crash_reason = Keyword.get(md, :crash_reason) do
      initial_call = Keyword.get(md, :initial_call)

      json_map(
        initial_call: format_initial_call(initial_call),
        reason: format_crash_reason(crash_reason)
      )
    end
  end

  @doc """
  RFC3339 UTC "Zulu" format.
  """
  def format_timestamp({date, time}) do
    [format_date(date), ?T, format_time(time), ?Z]
    |> IO.iodata_to_binary()
  end

  @doc """
  Provide a string output of the MFA log entry.
  """
  def format_function(nil, function), do: function
  def format_function(module, function), do: "#{module}.#{function}"
  def format_function(module, function, arity), do: "#{module}.#{function}/#{arity}"

  @doc """
  Optionally put a value to a map.
  """
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_initial_call(nil), do: nil
  defp format_initial_call({module, function, arity}), do: format_function(module, function, arity)

  defp format_crash_reason({:throw, reason}) do
    Exception.format(:throw, reason)
  end

  defp format_crash_reason({:exit, reason}) do
    Exception.format(:exit, reason)
  end

  defp format_crash_reason({%{} = exception, stacktrace}) do
    Exception.format(:error, exception, stacktrace)
  end

  defp format_crash_reason(other) do
    inspect(other)
  end

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
