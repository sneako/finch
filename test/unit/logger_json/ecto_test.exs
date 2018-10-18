defmodule LoggerJSON.EctoTest do
  use Logger.Case
  import ExUnit.CaptureIO
  require Logger

  setup do
    on_exit(fn ->
      :ok = Logger.configure_backend(LoggerJSON, device: :user, level: nil, metadata: [], json_encoder: Jason)
    end)

    diff = :erlang.convert_time_unit(1, :microsecond, :native)

    entry = %Ecto.LogEntry{
      query: fn -> "done" end,
      result: {:ok, []},
      params: [1, 2, 3, %Ecto.Query.Tagged{value: 1}],
      query_time: 2100 * diff,
      decode_time: 500 * diff,
      queue_time: 100 * diff,
      source: "test"
    }

    %{log_entry: entry}
  end

  test "logs ecto queries", %{log_entry: entry} do
    Logger.configure_backend(LoggerJSON, device: :standard_error, metadata: :all)

    log =
      capture_io(:standard_error, fn ->
        LoggerJSON.Ecto.log(entry)
        Logger.flush()
      end)

    assert %{
             "log" => "done",
             "query" => %{
               "decode_time_ms" => 500,
               "latency_ms" => 2700,
               "execution_time_ms" => 2100,
               "queue_time_ms" => 100
             }
           } = Jason.decode!(log)
  end

  test "logs ecto queries with debug level", %{log_entry: entry} do
    Logger.configure_backend(LoggerJSON, device: :standard_error, metadata: :all)

    log =
      capture_io(:standard_error, fn ->
        LoggerJSON.Ecto.log(entry, :debug)
        Logger.flush()
      end)

    assert %{
             "log" => "done",
             "query" => %{
               "decode_time_ms" => 500,
               "latency_ms" => 2700,
               "execution_time_ms" => 2100,
               "queue_time_ms" => 100
             }
           } = Jason.decode!(log)
  end
end
