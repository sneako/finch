defmodule Finch.HTTP1.TelemetryTest do
  use FinchCase, async: false

  @moduletag :capture_log

  setup %{bypass: bypass, finch_name: finch_name} do
    Bypass.expect(bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    start_supervised!(
      {Finch, name: finch_name, pools: %{default: [protocol: :http1, conn_max_idle_time: 10]}}
    )

    :ok
  end

  test "reports request and response headers", %{bypass: bypass, finch_name: finch_name} do
    self = self()

    :telemetry.attach_many(
      to_string(finch_name),
      [[:finch, :send, :start], [:finch, :recv, :stop]],
      fn name, _, metadata, _ -> send(self, {:telemetry_event, name, metadata}) end,
      nil
    )

    Bypass.expect(bypass, "GET", "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-foo-response", "bar-response")
      |> Plug.Conn.send_resp(200, "OK")
    end)

    request = Finch.build(:get, endpoint(bypass), [{"x-foo-request", "bar-request"}])
    assert {:ok, %{status: 200}} = Finch.request(request, finch_name)

    assert_receive {:telemetry_event, [:finch, :send, :start],
                    %{request: %{headers: [{"x-foo-request", "bar-request"}]}}}

    assert_receive {:telemetry_event, [:finch, :recv, :stop], %{headers: headers}}
    assert {"x-foo-response", "bar-response"} in headers

    :telemetry.detach(to_string(finch_name))
  end

  test "reports response status code", %{bypass: bypass, finch_name: finch_name} do
    self = self()

    :telemetry.attach(
      to_string(finch_name),
      [:finch, :recv, :stop],
      fn name, _, metadata, _ -> send(self, {:telemetry_event, name, metadata}) end,
      nil
    )

    Bypass.expect(bypass, "GET", "/", fn conn -> Plug.Conn.send_resp(conn, 201, "OK") end)

    request = Finch.build(:get, endpoint(bypass))
    assert {:ok, %{status: 201}} = Finch.request(request, finch_name)

    assert_receive {:telemetry_event, [:finch, :recv, :stop], %{status: 201}}

    :telemetry.detach(to_string(finch_name))
  end

  test "reports reused connections", %{bypass: bypass, finch_name: finch_name} do
    parent = self()
    ref = make_ref()

    handler = fn event, _measurements, meta, _config ->
      case event do
        [:finch, :connect, :start] ->
          send(parent, {ref, :start})

        [:finch, :connect, :stop] ->
          send(parent, {ref, :stop})

        [:finch, :reused_connection] ->
          assert is_atom(meta.scheme)
          assert is_binary(meta.host)
          assert is_integer(meta.port)
          send(parent, {ref, :reused})

        _ ->
          flunk("Unknown event")
      end
    end

    :telemetry.attach_many(
      to_string(finch_name),
      [
        [:finch, :connect, :start],
        [:finch, :connect, :stop],
        [:finch, :reused_connection]
      ],
      handler,
      nil
    )

    request = Finch.build(:get, endpoint(bypass))
    assert {:ok, %{status: 200}} = Finch.request(request, finch_name)
    assert_receive {^ref, :start}
    assert_receive {^ref, :stop}

    assert {:ok, %{status: 200}} = Finch.request(request, finch_name)
    assert_receive {^ref, :reused}

    :telemetry.detach(to_string(finch_name))
  end

  test "reports conn_max_idle_time_exceeded", %{bypass: bypass, finch_name: finch_name} do
    parent = self()
    ref = make_ref()

    handler = fn event, measurements, meta, _config ->
      case event do
        [:finch, :conn_max_idle_time_exceeded] ->
          assert is_integer(measurements.idle_time)
          assert is_atom(meta.scheme)
          assert is_binary(meta.host)
          assert is_integer(meta.port)
          send(parent, {ref, :conn_max_idle_time_exceeded})

        _ ->
          flunk("Unknown event")
      end
    end

    :telemetry.attach_many(
      to_string(finch_name),
      [
        [:finch, :conn_max_idle_time_exceeded]
      ],
      handler,
      nil
    )

    request = Finch.build(:get, endpoint(bypass))
    assert {:ok, %{status: 200}} = Finch.request(request, finch_name)
    Process.sleep(15)
    assert {:ok, %{status: 200}} = Finch.request(request, finch_name)
    assert_receive {^ref, :conn_max_idle_time_exceeded}

    :telemetry.detach(to_string(finch_name))
  end

  test "reports max_idle_time_exceeded", %{bypass: bypass, finch_name: finch_name} do
    parent = self()
    ref = make_ref()

    handler = fn event, measurements, meta, _config ->
      case event do
        [:finch, :max_idle_time_exceeded] ->
          assert is_integer(measurements.idle_time)
          assert is_atom(meta.scheme)
          assert is_binary(meta.host)
          assert is_integer(meta.port)
          send(parent, {ref, :max_idle_time_exceeded})

        _ ->
          flunk("Unknown event")
      end
    end

    :telemetry.attach_many(
      to_string(finch_name),
      [
        [:finch, :max_idle_time_exceeded]
      ],
      handler,
      nil
    )

    request = Finch.build(:get, endpoint(bypass))
    assert {:ok, %{status: 200}} = Finch.request(request, finch_name)
    Process.sleep(15)
    assert {:ok, %{status: 200}} = Finch.request(request, finch_name)
    assert_receive {^ref, :max_idle_time_exceeded}

    :telemetry.detach(to_string(finch_name))
  end

  test "reports request spans", %{bypass: bypass, finch_name: finch_name} do
    parent = self()
    ref = make_ref()

    handler = fn event, measurements, meta, _config ->
      case event do
        [:finch, :request, :start] ->
          assert is_integer(measurements.system_time)
          assert meta.name == finch_name
          assert %Finch.Request{} = meta.request

          send(parent, {ref, :start})

        [:finch, :request, :stop] ->
          assert is_integer(measurements.duration)
          assert meta.name == finch_name
          assert %Finch.Request{} = meta.request

          assert {:ok, %Finch.Response{body: "OK", status: 200}} = meta.result

          send(parent, {ref, :stop})

        [:finch, :request, :exception] ->
          assert is_integer(measurements.duration)
          assert meta.name == finch_name
          assert %Finch.Request{} = meta.request
          assert meta.kind == :exit
          assert {:timeout, _} = meta.reason
          assert meta.stacktrace != nil

          send(parent, {ref, :exception})

        _ ->
          flunk("Unknown event")
      end
    end

    :telemetry.attach_many(
      to_string(finch_name),
      [
        [:finch, :request, :start],
        [:finch, :request, :stop],
        [:finch, :request, :exception]
      ],
      handler,
      nil
    )

    assert {:ok, %{status: 200}} =
             Finch.build(:get, endpoint(bypass)) |> Finch.request(finch_name)

    assert_receive {^ref, :start}
    assert_receive {^ref, :stop}

    Bypass.down(bypass)

    assert_raise RuntimeError,
                 ~r/Finch was unable to provide a connection within the timeout/,
                 fn ->
                   Finch.build(:get, endpoint(bypass))
                   |> Finch.request(finch_name, pool_timeout: 0)
                 end

    assert_receive {^ref, :start}

    :telemetry.detach(to_string(finch_name))
  end

  test "reports queue spans", %{bypass: bypass, finch_name: finch_name} do
    parent = self()
    ref = make_ref()

    handler = fn event, measurements, meta, _config ->
      case event do
        [:finch, :queue, :start] ->
          assert is_integer(measurements.system_time)
          assert is_pid(meta.pool)
          assert %Finch.Request{} = meta.request
          send(parent, {ref, :start})

        [:finch, :queue, :stop] ->
          assert is_integer(measurements.duration)
          assert is_integer(measurements.idle_time)
          assert is_pid(meta.pool)
          assert %Finch.Request{} = meta.request
          send(parent, {ref, :stop})

        [:finch, :queue, :exception] ->
          assert is_integer(measurements.duration)
          assert is_pid(meta.pool)
          assert meta.kind == :exit
          assert {:timeout, _} = meta.reason
          assert meta.stacktrace != nil
          assert %Finch.Request{} = meta.request
          send(parent, {ref, :exception})

        _ ->
          flunk("Unknown event")
      end
    end

    :telemetry.attach_many(
      to_string(finch_name),
      [
        [:finch, :queue, :start],
        [:finch, :queue, :stop],
        [:finch, :queue, :exception]
      ],
      handler,
      nil
    )

    assert {:ok, %{status: 200}} =
             Finch.build(:get, endpoint(bypass)) |> Finch.request(finch_name)

    assert_receive {^ref, :start}
    assert_receive {^ref, :stop}

    Bypass.down(bypass)

    assert_raise RuntimeError,
                 ~r/Finch was unable to provide a connection within the timeout/,
                 fn ->
                   Finch.build(:get, endpoint(bypass))
                   |> Finch.request(finch_name, pool_timeout: 0)
                 end

    assert_receive {^ref, :start}
    assert_receive {^ref, :exception}

    :telemetry.detach(to_string(finch_name))
  end

  test "reports connection spans", %{bypass: bypass, finch_name: finch_name} do
    parent = self()
    ref = make_ref()

    handler = fn event, measurements, meta, _config ->
      case event do
        [:finch, :connect, :start] ->
          assert is_integer(measurements.system_time)
          assert is_atom(meta.scheme)
          assert is_integer(meta.port)
          assert is_binary(meta.host)
          send(parent, {ref, :start})

        [:finch, :connect, :stop] ->
          assert is_integer(measurements.duration)
          assert is_atom(meta.scheme)
          assert is_integer(meta.port)
          assert is_binary(meta.host)
          send(parent, {ref, :stop})

        _ ->
          flunk("Unknown event")
      end
    end

    :telemetry.attach_many(
      to_string(finch_name),
      [
        [:finch, :connect, :start],
        [:finch, :connect, :stop]
      ],
      handler,
      nil
    )

    assert {:ok, %{status: 200}} =
             Finch.build(:get, endpoint(bypass)) |> Finch.request(finch_name)

    assert_receive {^ref, :start}
    assert_receive {^ref, :stop}

    :telemetry.detach(to_string(finch_name))
  end

  test "reports send spans", %{bypass: bypass, finch_name: finch_name} do
    parent = self()
    ref = make_ref()

    handler = fn event, measurements, meta, _config ->
      case event do
        [:finch, :send, :start] ->
          assert is_integer(measurements.system_time)
          assert is_integer(measurements.idle_time)
          assert %Finch.Request{} = meta.request
          send(parent, {ref, :start})

        [:finch, :send, :stop] ->
          assert is_integer(measurements.duration)
          assert is_integer(measurements.idle_time)
          assert %Finch.Request{} = meta.request
          send(parent, {ref, :stop})

        _ ->
          flunk("Unknown event")
      end
    end

    :telemetry.attach_many(
      to_string(finch_name),
      [
        [:finch, :send, :start],
        [:finch, :send, :stop],
        [:finch, :send, :exception]
      ],
      handler,
      nil
    )

    assert {:ok, %{status: 200}} =
             Finch.build(:get, endpoint(bypass)) |> Finch.request(finch_name)

    assert_receive {^ref, :start}
    assert_receive {^ref, :stop}

    :telemetry.detach(to_string(finch_name))
  end

  test "reports recv spans", %{bypass: bypass, finch_name: finch_name} do
    parent = self()
    ref = make_ref()

    handler = fn event, measurements, meta, _config ->
      case event do
        [:finch, :recv, :start] ->
          assert is_integer(measurements.system_time)
          assert is_integer(measurements.idle_time)
          assert %Finch.Request{} = meta.request
          send(parent, {ref, :start})

        [:finch, :recv, :stop] ->
          assert is_integer(measurements.duration)
          assert is_integer(measurements.idle_time)
          assert %Finch.Request{} = meta.request
          assert is_integer(meta.status)
          assert is_list(meta.headers)
          send(parent, {ref, :stop})

        _ ->
          flunk("Unknown event")
      end
    end

    :telemetry.attach_many(
      to_string(finch_name),
      [
        [:finch, :recv, :start],
        [:finch, :recv, :stop]
      ],
      handler,
      nil
    )

    assert {:ok, %{status: 200}} =
             Finch.build(:get, endpoint(bypass)) |> Finch.request(finch_name)

    assert_receive {^ref, :start}
    assert_receive {^ref, :stop}

    :telemetry.detach(to_string(finch_name))
  end
end
