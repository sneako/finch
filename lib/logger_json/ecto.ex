if Code.ensure_loaded?(Ecto) do
  defmodule LoggerJSON.Ecto do
    @moduledoc """
    Implements the behaviour of `Ecto.LogEntry` and sends query as a string
    to Logger with additional metadata:

      * query.execution_time_μs - the time spent executing the query in microseconds;
      * query.decode_time_μs - the time spent decoding the result in microseconds (it may be 0);
      * query.queue_time_μs - the time spent to check the connection out in microseconds (it may be 0);
      * query.duration_μs - time the query taken (sum of `query_time`, `decode_time` and `queue_time`);
      * connection_pid - the connection process that executed the query;
      * ansi_color - the color that should be used when logging the entry.

    For more information see [LogEntry](https://github.com/elixir-ecto/ecto/blob/master/lib/ecto/log_entry.ex)
    source code.
    """
    require Logger

    @doc """
    Logs query string with metadata from `Ecto.LogEntry` in with debug level.
    """
    @spec log(entry :: map()) :: map()
    def log(entry) do
      {query, metadata} = query_and_metadata(entry)

      # The logger call will be removed at compile time if
      # `compile_time_purge_level` is set to higher than debug.
      Logger.debug(query, metadata)

      entry
    end

    @doc """
    Overwritten to use JSON.

    Logs the given entry in the given level.
    """
    @spec log(entry :: map(), level :: Logger.level()) :: map()
    def log(entry, level) do
      {query, metadata} = query_and_metadata(entry)

      # The logger call will not be removed at compile time,
      # because we use level as a variable
      Logger.log(level, query, metadata)

      entry
    end

    defp query_and_metadata(%{
           query: query,
           query_time: query_time,
           decode_time: decode_time,
           queue_time: queue_time
         }) do
      query_time = format_time(query_time, :native)
      decode_time = format_time(decode_time, :native)
      queue_time = format_time(queue_time, :native)

      metadata = [
        query: %{
          execution_time_μs: query_time,
          decode_time_μs: decode_time,
          queue_time_μs: queue_time,
          latency_μs: query_time + decode_time + queue_time
        }
      ]

      {query, metadata}
    end

    @spec telemetry_logging_handler(
            event_name :: [atom()],
            query_time :: %{
              query_time: non_neg_integer(),
              queue_time: non_neg_integer(),
              decode_time: non_neg_integer(),
              total_time: non_neg_integer()
            },
            log_entry :: map(),
            level :: Logger.level()
          ) :: :ok
    def telemetry_logging_handler(_event_name, time, %{query: query, repo: repo}, level) do
      query_time = Map.get(time, :query_time) |> format_time(:nanosecond)
      queue_time = Map.get(time, :queue_time) |> format_time(:nanosecond)
      decode_time = Map.get(time, :decode_time) |> format_time(:nanosecond)
      latency = Map.get(time, :total_time) |> format_time(:nanosecond)

      metadata = [
        query: %{
          repo: inspect(repo),
          execution_time_μs: query_time,
          decode_time_μs: decode_time,
          queue_time_μs: queue_time,
          latency_μs: latency
        }
      ]

      Logger.log(level, query, metadata)
    end

    defp format_time(nil, _unit), do: 0
    defp format_time(time, unit), do: System.convert_time_unit(time, unit, :microsecond)
  end
end
