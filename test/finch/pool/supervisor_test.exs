defmodule Finch.Pool.SupervisorTest do
  use FinchCase, async: false

  for protocol <- [:http1, :http2], metrics? <- [false, true] do
    @tag protocol: protocol, metrics?: metrics?
    test "scale down unregisters #{protocol} workers before returning with metrics #{metrics?}",
         %{
           finch_name: finch_name,
           bypass: bypass,
           protocol: protocol,
           metrics?: metrics?
         } do
      url =
        case protocol do
          :http1 ->
            Bypass.stub(bypass, "GET", "/", &Plug.Conn.send_resp(&1, 200, "OK"))
            endpoint(bypass)

          :http2 ->
            Application.fetch_env!(:finch, :test_https_h2_url)
        end

      listener = :"#{finch_name}.Listener"
      Process.register(self(), listener)
      pool_name = url |> Finch.Pool.new() |> Finch.Pool.to_name()

      start_supervised!(
        {Finch,
         name: finch_name,
         registry_listeners: [listener],
         pools: %{
           url => [
             protocols: [protocol],
             count: 3,
             start_pool_metrics?: metrics?,
             conn_opts: [transport_opts: [verify: :verify_none]]
           ]
         }}
      )

      for _ <- 1..3 do
        assert_receive {:register, ^finch_name, ^pool_name, _partition, _module}, 5_000
      end

      partitions = for {_, pid, _, _} <- Supervisor.which_children(finch_name), do: pid
      Enum.each(partitions, &:sys.suspend/1)

      try do
        # Prevent automatic cleanup of exited workers from hiding a stale registration.
        assert :ok = Finch.set_pool_count(finch_name, url, 2)
        assert {:ok, 2} = Finch.get_pool_count(finch_name, url)
        assert [_, _] = entries = Registry.lookup(finch_name, pool_name)
        assert Enum.all?(entries, fn {pid, _module} -> Process.alive?(pid) end)

        assert {:ok, %{status: 200}} = Finch.request(Finch.build(:get, url), finch_name)
      after
        Enum.each(partitions, &:sys.resume/1)
        stop_supervised!(finch_name)
      end
    end
  end
end
