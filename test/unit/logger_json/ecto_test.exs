defmodule LoggerJSON.EctoTest do
  use Logger.Case
  import ExUnit.CaptureIO
  require Logger


  setup do
    on_exit fn ->
      :ok = Logger.configure_backend(LoggerJSON, [device: :user, level: nil, metadata: [], json_encoder: Poison])
    end

    diff = :erlang.convert_time_unit(1, :micro_seconds, :native)
    entry = %Ecto.LogEntry{
      query: fn -> "done" end,
      result: {:ok, []},
      params: [1, 2, 3, %Ecto.Query.Tagged{value: 1}],
      query_time: 2100 * diff,
      decode_time: 500 * diff,
      queue_time: 100 * diff,
      source: "test",
    }

    %{log_entry: entry}
  end


  test "logs ecto queries", %{log_entry: entry} do
    Logger.configure_backend(LoggerJSON, device: :standard_error, metadata: :all)

    log = capture_io(:standard_error, fn ->
      LoggerJSON.Ecto.log(entry)
      Logger.flush()
    end)

    %{
      "jsonPayload" => %{
        "message" => "done",
        "metadata" => %{
          "application" => "logger_json",
          "connection_pid" => nil,
          "decode_time" => 0.5,
          "duration" => 2.7,
          "query_time" => 2.1,
          "queue_time" => 0.1
        }
      }
    } = Poison.decode!(log)
  end
end
