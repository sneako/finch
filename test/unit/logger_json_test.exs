defmodule LoggerJSONTest do
  use Logger.Case
  import ExUnit.CaptureIO
  require Logger

  setup do
    on_exit(fn ->
      :ok = Logger.configure_backend(LoggerJSON, device: :user, level: nil, metadata: [], json_encoder: Jason)
    end)
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

      Logger.metadata(user_id: 11)
      Logger.metadata(user_id: 13)

      log =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Jason.decode!()

      assert %{"jsonPayload" => %{"metadata" => %{"user_id" => 13}}} = log
    end

    test "can be configured to :all" do
      Logger.configure_backend(LoggerJSON, metadata: :all)

      Logger.metadata(user_id: 11)
      Logger.metadata(dynamic_metadata: 5)

      log =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Jason.decode!()

      assert %{"jsonPayload" => %{"metadata" => %{"user_id" => 11}}} = log
      assert %{"jsonPayload" => %{"metadata" => %{"dynamic_metadata" => 5}}} = log
    end

    test "can be empty" do
      Logger.configure_backend(LoggerJSON, metadata: [])

      %{"jsonPayload" => %{"metadata" => meta}} =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Jason.decode!()

      assert %{} == meta
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
      Logger.configure_backend(LoggerJSON, metadata: [], on_init: {LoggerJSONTest, :on_init_cb, []})

      Logger.metadata(user_id: 11)

      log =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Jason.decode!()

      assert %{"jsonPayload" => %{"metadata" => %{"user_id" => 11}}} = log
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
             "sourceLocation" => %{
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

  test "logs crash reason when present" do
    Logger.configure_backend(LoggerJSON, metadata: [:crash_reason])
    Logger.metadata(crash_reason: {%RuntimeError{message: "oops"}, []})

    log =
      capture_log(fn -> Logger.debug("hello") end)
      |> Jason.decode!()

    assert log["jsonPayload"]["metadata"]["crash_reason"] == "%RuntimeError{message: \"oops\"}"
    assert log["jsonPayload"]["metadata"]["crash_reason_stacktrace"] == "[]"
  end

  test "logs initial call when present" do
    Logger.configure_backend(LoggerJSON, metadata: [:initial_call])
    Logger.metadata(initial_call: {Foo, :bar, 3})

    log =
      capture_log(fn -> Logger.debug("hello") end)
      |> Jason.decode!()

    assert log["jsonPayload"]["metadata"]["initial_call"] == "Elixir.Foo.bar/3"
  end

  # TODO: This flaky test should be rewritten for custom IO handler implementation that proxies events to test pid
  # test "buffers events" do
  #   Logger.configure_backend(LoggerJSON, max_buffer: 10)
  #
  #   fun = fn -> Logger.debug("hello") end
  #
  #   logs =
  #     capture_log(fn ->
  #       tasks = for _ <- 1..1000, do: Task.async(fun)
  #       Enum.map(tasks, &Task.await/1)
  #     end)
  #
  #   assert 1001 ==
  #            logs
  #            |> String.split("\n")
  #            |> length()
  # end

  # Sets metadata to :all for test purposes
  def on_init_cb(conf) do
    {:ok, Keyword.put(conf, :metadata, :all)}
  end
end
