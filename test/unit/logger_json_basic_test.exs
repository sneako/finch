defmodule LoggerJSONBasicTest do
  use Logger.Case, async: false
  require Logger
  alias LoggerJSON.Formatters.BasicLogger

  defmodule IDStruct, do: defstruct(id: nil)

  setup do
    :ok =
      Logger.configure_backend(
        LoggerJSON,
        device: :user,
        level: nil,
        metadata: [],
        json_encoder: Jason,
        on_init: :disabled,
        formatter: BasicLogger
      )
  end

  describe "metadata" do
    test "can be configured" do
      Logger.configure_backend(LoggerJSON, metadata: [:user_id])

      assert capture_log(fn ->
               Logger.debug("hello")
             end) =~ "hello"

      Logger.metadata(user_id: 11)
      Logger.metadata(dynamic_metadata: 5)

      log =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Jason.decode!()

      assert %{"user_id" => 11} == log["metadata"]
    end

    test "can be configured to :all" do
      Logger.configure_backend(LoggerJSON, metadata: :all)

      Logger.metadata(user_id: 11)
      Logger.metadata(dynamic_metadata: 5)

      log =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Jason.decode!()

      assert %{"user_id" => 11, "dynamic_metadata" => 5} = log["metadata"]
    end

    test "can be empty" do
      Logger.configure_backend(LoggerJSON, metadata: [])

      Logger.metadata(user_id: 11)
      Logger.metadata(dynamic_metadata: 5)

      log =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Jason.decode!()

      assert %{"message" => "hello"} = log
      assert %{} == log["metadata"]
    end

    test "converts Struct metadata to maps" do
      Logger.configure_backend(LoggerJSON, metadata: :all)

      Logger.metadata(id_struct: %IDStruct{id: "test"})

      log =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Jason.decode!()

      assert %{"metadata" => %{"id_struct" => %{"id" => "test"}}} = log
    end
  end

  test "logs chardata messages" do
    Logger.configure_backend(LoggerJSON, metadata: :all)

    log =
      fn -> Logger.debug([?α, ?β, ?ω]) end
      |> capture_log()
      |> Jason.decode!()

    assert %{"message" => "αβω"} = log
  end
end
