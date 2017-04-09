defmodule LoggerJSONTest do
  use Logger.Case

  require Logger
  import ExUnit.CaptureIO

  setup do
    on_exit fn ->
      :ok = Logger.configure_backend(LoggerJSON, [device: :user, level: nil, metadata: [], json_encoder: Poison])
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

  test "can configure metadata" do
    Logger.configure_backend(LoggerJSON, metadata: [:user_id])

    assert capture_log(fn ->
      Logger.debug("hello")
    end) =~ "hello"

    Logger.metadata(user_id: 11)
    Logger.metadata(user_id: 13)

    log =
      fn -> Logger.debug("hello") end
      |> capture_log()
      |> Poison.decode!()

    assert %{"metadata" => %{"user_id" => 13}} = log
  end

  describe "metadata" do
    test "can be configured to :all" do
      Logger.configure_backend(LoggerJSON, metadata: :all)

      Logger.metadata(user_id: 11)
      Logger.metadata(dynamic_metadata: 5)

      log =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Poison.decode!()

      assert %{"metadata" => %{"user_id" => 11}} = log
      assert %{"metadata" => %{"dynamic_metadata" => 5}} = log
    end

    test "can be empty" do
      Logger.configure_backend(LoggerJSON, metadata: [])

      %{"metadata" => meta} =
        fn -> Logger.debug("hello") end
        |> capture_log()
        |> Poison.decode!()

      assert %{} == meta
    end
  end

  test "on_init/1 callback" do
    Logger.configure_backend(LoggerJSON, metadata: [], on_init: {LoggerJSONTest, :on_init_cb, []})

    Logger.metadata(user_id: 11)

    log =
      fn -> Logger.debug("hello") end
      |> capture_log()
      |> Poison.decode!()

    assert %{"metadata" => %{"user_id" => 11}} = log
  end

  test "contains source location" do
    %{module: mod, function: {name, arity}, file: file, line: line} = __ENV__

    log =
      fn -> Logger.debug("hello") end
      |> capture_log()
      |> Poison.decode!()

    line = line + 3
    fun_name = "#{name}/#{arity}"
    mod_name = "Elixir.#{inspect(mod)}"

    assert %{"sourceLocation" => %{
      "file" => ^file,
      "line" => ^line,
      "functionName" => ^fun_name,
      "moduleName" => ^mod_name,
    }} = log
  end

  test "can configure level" do
    Logger.configure_backend(LoggerJSON, level: :info)

    assert capture_log(fn ->
      Logger.debug("hello")
    end) == ""
  end

  # Sets metadata to :all for test purposes
  def on_init_cb(conf) do
    {:ok, Keyword.put(conf, :metadata, :all)}
  end
end
