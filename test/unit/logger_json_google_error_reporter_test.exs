defmodule LoggerJSONGoogleErrorReporterTest do
  use Logger.Case, async: false
  alias LoggerJSON.Formatters.GoogleCloudLogger
  alias LoggerJSON.Formatters.GoogleErrorReporter

  setup do
    :ok =
      Logger.configure_backend(
        LoggerJSON,
        device: :user,
        level: nil,
        metadata: :all,
        json_encoder: Jason,
        on_init: :disabled,
        formatter: GoogleCloudLogger
      )

    :ok = Logger.reset_metadata([])
  end

  test "metadata" do
    log =
      capture_log(fn -> GoogleErrorReporter.report(:error, %RuntimeError{message: "oops"}, []) end)
      |> Jason.decode!()

    assert log["severity"] == "ERROR"
    assert log["@type"] == "type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ReportedErrorEvent"
  end

  test "google_error_reporter metadata" do
    :ok =
      Application.put_env(:logger_json, :google_error_reporter, service_context: [service: "myapp", version: "abc123"])

    log =
      capture_log(fn -> GoogleErrorReporter.report(:error, %RuntimeError{message: "oops"}, []) end)
      |> Jason.decode!()

    assert log["serviceContext"]["service"] == "myapp"
    assert log["serviceContext"]["version"] == "abc123"
  after
    Application.delete_env(:logger_json, :google_error_reporter)
  end

  test "optional metadata" do
    log =
      capture_log(fn -> GoogleErrorReporter.report(:error, %RuntimeError{message: "oops"}, [], foo: "bar") end)
      |> Jason.decode!()

    assert log["foo"] == "bar"
  end

  test "logs elixir error" do
    error = %RuntimeError{message: "oops"}

    stacktrace = [
      {Foo, :bar, 0, [file: 'foo/bar.ex', line: 123]},
      {Foo.Bar, :baz, 1, [file: 'foo/bar/baz.ex', line: 456]}
    ]

    log =
      capture_log(fn -> GoogleErrorReporter.report(:error, error, stacktrace) end)
      |> Jason.decode!()

    assert log["message"] ==
             """
             ** (RuntimeError) oops
                 foo/bar.ex:123:in `Foo.bar/0'
                 foo/bar/baz.ex:456:in `Foo.Bar.baz/1'
             """
  end

  test "logs erlang error" do
    error = :undef

    stacktrace = [
      {Foo, :bar, [123, 456], []},
      {Foo, :bar, 2, [file: 'foo/bar.ex', line: 123]},
      {Foo.Bar, :baz, 1, [file: 'foo/bar/baz.ex', line: 456]}
    ]

    log =
      capture_log(fn -> GoogleErrorReporter.report(:error, error, stacktrace) end)
      |> Jason.decode!()

    assert log["message"] ==
             """
             ** (UndefinedFunctionError) function Foo.bar/2 is undefined (module Foo is not available)
                 foo/bar.ex:123:in `Foo.bar/2'
                 foo/bar/baz.ex:456:in `Foo.Bar.baz/1'
             Context:
                 Foo.bar(123, 456)
             """
  end
end
