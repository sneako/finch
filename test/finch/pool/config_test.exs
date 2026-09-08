defmodule Finch.Pool.ConfigTest do
  use FinchCase, async: true

  alias Finch.Pool
  alias Finch.Pool.Manager

  @moduletag bypass: false

  test "default certificates do not accumulate in supervisors for each destination", %{
    finch_name: name
  } do
    cacerts = certificates()
    opts = [count: 3, conn_opts: [transport_opts: [cacerts: cacerts]]]
    start_supervised!({Finch, name: name, pools: %{default: opts}})

    pools =
      for index <- 1..20 do
        pool = Pool.new("https://host-#{index}.invalid")
        assert {_pid, Finch.HTTP1.Pool} = Manager.get_pool(name, pool)
        pool
      end

    # The control processes and registry entries should be smaller than even one
    # copy of the certificate list, regardless of the number of destinations.
    certificate_bytes = :erts_debug.flat_size(cacerts) * :erlang.system_info(:wordsize)
    assert process_memory(Process.whereis(Manager.supervisor_name(name))) < certificate_bytes

    for pool <- pools do
      {pid, pool_name, _, _, _} = Manager.get_pool_supervisor(name, pool)
      assert process_memory(pid) < certificate_bytes

      entries = Registry.lookup(Manager.supervisor_registry_name(name), pool_name)
      assert :erts_debug.flat_size(entries) < :erts_debug.flat_size(cacerts)
    end
  end

  for source <- [:default, :configured, :user_managed] do
    test "#{source} options survive worker restarts and resizing", %{finch_name: name} do
      pool = Pool.new("https://configured.invalid", tag: :custom)
      cacerts = certificates()
      counter = :atomics.new(1, [])
      verify_fun = fn _cert, _event, state -> {:valid, state} end
      transport_opts = [cacerts: cacerts, verify_fun: {verify_fun, counter}]
      opts = [size: 7, conn_opts: [transport_opts: transport_opts]]

      case unquote(source) do
        :default ->
          start_supervised!({Finch, name: name, pools: %{default: opts}})

        :configured ->
          start_supervised!({Finch, name: name, pools: %{pool => opts}})

        :user_managed ->
          start_supervised!({Finch, name: name})
          start_supervised!({Pool, [finch: name, pool: pool] ++ opts})
      end

      assert {_pid, Finch.HTTP1.Pool} = Manager.get_pool(name, pool)
      {supervisor, _, _, _, _} = Manager.get_pool_supervisor(name, pool)

      assert :ok = Supervisor.terminate_child(supervisor, 1)
      assert {:ok, _pid} = Supervisor.restart_child(supervisor, 1)
      assert :ok = Finch.set_pool_count(name, pool, 3)
      assert {:ok, 3} = Finch.get_pool_count(name, pool)

      for {_id, pid, :worker, _modules} <- Supervisor.which_children(supervisor) do
        config = :sys.get_state(pid).state.opts
        assert config.size == 7
        assert config.conn_opts[:transport_opts][:cacerts] == cacerts
        assert {^verify_fun, ^counter} = config.conn_opts[:transport_opts][:verify_fun]
        assert :atomics.get(counter, 1) == 0
      end
    end
  end

  test "HTTP/2 workers resolve configured certificate options", %{finch_name: name} do
    url = Application.fetch_env!(:finch, :test_https_h2_url)
    cacerts = certificates()

    Finch.TestHelper.start_finch!(
      name: name,
      pools: %{
        url => [
          protocols: [:http2],
          conn_opts: [transport_opts: [cacerts: cacerts, verify: :verify_none]]
        ]
      }
    )

    assert {:ok, %Finch.Response{status: 200}} = Finch.request(Finch.build(:get, url), name)
    assert {:ok, pid} = Finch.find_pool(name, Pool.new(url))
    assert {:connected, data} = :sys.get_state(pid)
    assert data.connect_opts[:transport_opts][:cacerts] == cacerts
  end

  defp certificates do
    [{:Certificate, der, :not_encrypted}] =
      "test/fixtures/selfsigned.pem" |> File.read!() |> :public_key.pem_decode()

    # Match the decoded certificate shape returned by :public_key.cacerts_get/0
    # without depending on the size or contents of the machine's CA store.
    List.duplicate({:cert, der, :public_key.pkix_decode_cert(der, :otp)}, 100)
  end

  defp process_memory(pid) do
    :erlang.garbage_collect(pid)
    {:memory, bytes} = Process.info(pid, :memory)
    bytes
  end
end
