defmodule LoggerJSONGoogleTest do
  use Logger.Case, async: false
  import ExUnit.CaptureIO
  require Logger
  alias LoggerJSON.Formatters.GoogleCloudLogger

  setup do
    :ok =
      Logger.configure_backend(
        LoggerJSON,
        device: :user,
        level: nil,
        metadata: [],
        json_encoder: Jason,
        on_init: :disabled,
        formatter: GoogleCloudLogger
      )
  end

  describe "configure_log_level!/1" do
    test "tolerates nil values" do
      assert :ok == LoggerJSON.configure_log_level!(nil)
    end

    test "raises on invalid LOG_LEVEL" do
      assert_raise ArgumentError, fn ->
        LoggerJSON.configure_log_level!("super_critical")
      end

      assert_raise ArgumentError, fn ->
        LoggerJSON.configure_log_level!(1_337)
      end
    end

    test "configures log level with valid string value" do
      :ok = LoggerJSON.configure_log_level!("debug")
    end

    test "configures log level with valid atom value" do
      :ok = LoggerJSON.configure_log_level!(:debug)
    end
  end

  test "logs empty binary messages" do
    Logger.configure_backend(LoggerJSON, metadata: :all)

    log =
      fn -> Logger.debug("") end
      |> capture_log()
      |> Jason.decode!()

    assert %{"message" => ""} = log
  end

  test "logs binary messages" do
    Logger.configure_backend(LoggerJSON, metadata: :all)

    log =
      fn -> Logger.debug("hello") end
      |> capture_log()
      |> Jason.decode!()

    assert %{"message" => "hello"} = log
  end

  test "logs empty iodata messages" do
    Logger.configure_backend(LoggerJSON, metadata: :all)

    log =
      fn -> Logger.debug([]) end
      |> capture_log()
      |> Jason.decode!()

    assert %{"message" => ""} = log
  end

  test "logs iodata messages" do
    Logger.configure_backend(LoggerJSON, metadata: :all)

    log =
      fn -> Logger.debug([?h, ?e, ?l, ?l, ?o]) end
      |> capture_log()
      |> Jason.decode!()

    assert %{"message" => "hello"} = log
  end

  test "log message does not break escaping" do
    Logger.configure_backend(LoggerJSON, metadata: :all)

    log =
      fn -> Logger.debug([?", ?h]) end
      |> capture_log()
      |> Jason.decode!()

    assert %{"message" => "\"h"} = log

    log =
      fn -> Logger.debug("\"h") end
      |> capture_log()
      |> Jason.decode!()

    assert %{"message" => "\"h"} = log
  end

  test "does not start when there is no user" do
    :ok = Logger.remove_backend(LoggerJSON)
    user = Process.whereis(:user)

    try do
      Process.unregister(:user)
      assert {:error, :ignore} == :gen_event.add_handler(Logger, LoggerJSON, LoggerJSON)
    after
      Process.register(user, :user)
    end
  after
    {:ok, _} = Logger.add_backend(LoggerJSON)
  end

  test "may use another device" do
    Logger.configure_backend(LoggerJSON, device: :standard_error)

    assert capture_io(:standard_error, fn ->
             Logger.debug("hello")
             Logger.flush()
           end) =~ "hello"
  end

  describe "metadata" do
    test "can be configured" do
      Logger.configure_backend(LoggerJSON, metadata: [:user_id])

      assert capture_log(fn ->
               Logger.debug("hello")
             end) =~ "hello"

      Logger.metadata(user_id: 13)

      log =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Jason.decode!()

      assert %{"user_id" => 13} = log
    end

    test "can be configured to :all" do
      Logger.configure_backend(LoggerJSON, metadata: :all)

      Logger.metadata(user_id: 11)
      Logger.metadata(dynamic_metadata: 5)

      log =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Jason.decode!()

      assert %{"user_id" => 11} = log
      assert %{"dynamic_metadata" => 5} = log
    end

    test "can be empty" do
      Logger.configure_backend(LoggerJSON, metadata: [])

      log =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Jason.decode!()

      assert %{"message" => "hello"} = log
    end

    test "ignore otp's metadata unixtime" do
      Logger.configure_backend(LoggerJSON, metadata: :all)
      log =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Jason.decode!()
      assert not is_integer(log["time"])
    end
  end

  describe "on_init/1 callback" do
    test "raises when invalid" do
      assert_raise ArgumentError,
                   "invalid :on_init option for :logger_json application. " <>
                     "Expected a tuple with module, function and args, got: :atom",
                   fn ->
                     LoggerJSON.init({LoggerJSON, [on_init: :atom]})
                   end
    end

    test "is triggered" do
      Logger.configure_backend(LoggerJSON, metadata: [], on_init: {LoggerJSONGoogleTest, :on_init_cb, []})

      Logger.metadata(user_id: 11)

      log =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Jason.decode!()

      assert %{"user_id" => 11} = log
    end
  end

  test "contains source location" do
    %{module: mod, function: {name, arity}, file: file, line: line} = __ENV__

    log =
      fn -> Logger.debug("hello") end
      |> capture_log()
      |> Jason.decode!()

    line = line + 3
    function = "Elixir.#{inspect(mod)}.#{name}/#{arity}"

    assert %{
             "logging.googleapis.com/sourceLocation" => %{
               "file" => ^file,
               "line" => ^line,
               "function" => ^function
             }
           } = log
  end

  test "may configure level" do
    Logger.configure_backend(LoggerJSON, level: :info)

    assert capture_log(fn ->
             Logger.debug("hello")
           end) == ""
  end

  test "logs severity" do
    log =
      fn -> Logger.debug("hello") end
      |> capture_log()
      |> Jason.decode!()

    assert %{"severity" => "DEBUG"} = log

    log =
      fn -> Logger.warn("hello") end
      |> capture_log()
      |> Jason.decode!()

    assert %{"severity" => "WARNING"} = log
  end

  test "logs crash reason when present" do
    Logger.configure_backend(LoggerJSON, metadata: [:crash_reason])
    Logger.metadata(crash_reason: {%RuntimeError{message: "oops"}, []})

    log =
      capture_log(fn -> Logger.debug("hello") end)
      |> Jason.decode!()

    assert is_nil(log["error"]["initial_call"])
    assert log["error"]["reason"] == "** (RuntimeError) oops"
  end

  test "logs erlang style crash reasons" do
    Logger.configure_backend(LoggerJSON, metadata: [:crash_reason])
    Logger.metadata(crash_reason: {:socket_closed_unexpectedly, []})

    log =
      capture_log(fn -> Logger.debug("hello") end)
      |> Jason.decode!()

    assert is_nil(log["error"]["initial_call"])
    assert log["error"]["reason"] == "{:socket_closed_unexpectedly, []}"
  end

  test "logs initial call when present" do
    Logger.configure_backend(LoggerJSON, metadata: [:initial_call])
    Logger.metadata(crash_reason: {%RuntimeError{message: "oops"}, []}, initial_call: {Foo, :bar, 3})

    log =
      capture_log(fn -> Logger.debug("hello") end)
      |> Jason.decode!()

    assert log["error"]["initial_call"] == "Elixir.Foo.bar/3"
  end

  # Sets metadata to :all for test purposes
  def on_init_cb(conf) do
    {:ok, Keyword.put(conf, :metadata, :all)}
  end
end
