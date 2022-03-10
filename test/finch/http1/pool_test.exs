defmodule Finch.HTTP1.PoolTest do
  use ExUnit.Case

  setup do
    {:ok, bypass: Bypass.open()}
  end

  defp endpoint(%{port: port}, path \\ "/"), do: "http://localhost:#{port}#{path}"

  test "should terminate pool after idle timeout", %{bypass: bypass} do
    {atom_test_name, _arity} = __ENV__.function
    test_name = to_string(atom_test_name)
    parent = self()

    handler = fn event, _measurments, meta, _config ->
      assert event == [:finch, :pool_max_idle_time_exceeded]
      assert is_atom(meta.scheme)
      assert is_binary(meta.host)
      assert is_integer(meta.port)
      send(parent, :telemetry_sent)
    end

    :telemetry.attach(test_name, [:finch, :pool_max_idle_time_exceeded], handler, nil)

    start_supervised!(
      {Finch,
       name: IdleFinch,
       pools: %{
         default: [
           protocol: :http1,
           pool_max_idle_time: 5
         ]
       }}
    )

    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "OK")
    end)

    assert {:ok, %{status: 200}} =
             Finch.build(:get, endpoint(bypass))
             |> Finch.request(IdleFinch)

    [{_, pool, _, _}] = DynamicSupervisor.which_children(IdleFinch.PoolSupervisor)

    Process.monitor(pool)

    assert_receive {:DOWN, _, :process, ^pool, {:shutdown, :idle_timeout}}

    assert [] = DynamicSupervisor.which_children(IdleFinch.PoolSupervisor)

    assert_receive :telemetry_sent

    :telemetry.detach(test_name)
  end
end
