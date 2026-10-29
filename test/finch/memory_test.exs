defmodule Finch.MemoryTest do
  # Reproduces https://github.com/sneako/finch/issues/385, where an application
  # that reaches many hosts through the default pool uses far more memory than it
  # did on 0.21. Apart from the "dynamically started pools" tests, only API that
  # exists in 0.21 is used, so that this file can also run against it.
  use ExUnit.Case, async: true

  @moduletag :memory

  @destinations 20
  @fixtures_dir Path.expand("../fixtures", __DIR__)

  setup_all do
    {:ok, cacerts: cacerts()}
  end

  setup context do
    {:ok, finch_name: context.test}
  end

  for protocol <- [:http1, :http2] do
    describe "memory per destination with #{protocol}" do
      @describetag protocol: protocol

      test "https destinations", %{finch_name: name, cacerts: cacerts, protocol: protocol} do
        urls = for _ <- 1..@destinations, do: start_server(:https)
        start_finch!(name, cacerts, protocols: [protocol])
        baseline = measure(name)

        for url <- urls do
          assert {:ok, %{status: 200}} = request(name, url)
        end

        assert_cheaper_than_certificates(baseline, measure(name), @destinations, cacerts)
      end

      @tag :capture_log
      test "https destinations that refuse the connection",
           %{finch_name: name, cacerts: cacerts, protocol: protocol} do
        start_finch!(name, cacerts, protocols: [protocol])
        urls = refused_destinations(:https, @destinations)
        baseline = measure(name)

        # An HTTP/2 pool is waited for until the pool timeout
        urls
        |> Task.async_stream(&Finch.request(Finch.build(:get, &1), name, pool_timeout: 500),
          max_concurrency: @destinations
        )
        |> Enum.each(&assert {:ok, {:error, _}} = &1)

        current = measure(name)
        # HTTP/2 pools keep trying to connect, which they log
        stop_supervised!(name)

        assert_cheaper_than_certificates(baseline, current, @destinations, cacerts)
      end

      test "http destinations", %{finch_name: name, cacerts: cacerts, protocol: protocol} do
        urls = for _ <- 1..@destinations, do: start_server(:http)
        start_finch!(name, cacerts, protocols: [protocol])
        baseline = measure(name)

        for url <- urls do
          assert {:ok, %{status: 200}} = request(name, url)
        end

        assert_cheaper_than_certificates(baseline, measure(name), @destinations, cacerts)
      end

      test "concurrent requests to one destination",
           %{finch_name: name, cacerts: cacerts, protocol: protocol} do
        url = start_server(:https)
        start_finch!(name, cacerts, protocols: [protocol])
        baseline = measure(name)

        1..10
        |> Enum.map(fn _ -> Task.async(fn -> request(name, url <> "/wait/100") end) end)
        |> Task.await_many()
        |> Enum.each(&assert {:ok, %{status: 200}} = &1)

        assert_cheaper_than_certificates(baseline, measure(name), 1, cacerts)
      end
    end

    describe "memory of the calling process with #{protocol}" do
      @describetag protocol: protocol

      # Also fails on 0.21, where the caller reads the whole configuration from
      # the registry to find the pool manager
      test "when the request starts the pool",
           %{finch_name: name, cacerts: cacerts, protocol: protocol} do
        url = start_server(:https)
        start_finch!(name, cacerts, protocols: [protocol])

        assert_cheaper_than_certificates([caller: caller_memory(name, url)], cacerts)
      end

      test "when the pool is already running",
           %{finch_name: name, cacerts: cacerts, protocol: protocol} do
        url = start_server(:https)
        start_finch!(name, cacerts, protocols: [protocol])
        assert {:ok, %{status: 200}} = request(name, url)

        assert_cheaper_than_certificates([caller: caller_memory(name, url)], cacerts)
      end
    end

    describe "dynamically started pools with #{protocol}" do
      @describetag protocol: protocol
      @describetag :dynamic_pools

      test "started with connection options",
           %{finch_name: name, cacerts: cacerts, protocol: protocol} do
        urls = for _ <- 1..@destinations, do: start_server(:https)
        start_supervised!({Finch, name: name})
        conn_opts = [transport_opts: [cacerts: cacerts, verify: :verify_none]]
        baseline = measure(name)

        for url <- urls do
          pool = Finch.Pool.new(url)
          assert :ok = Finch.start_pool(name, pool, protocols: [protocol], conn_opts: conn_opts)
        end

        assert_cheaper_than_certificates(baseline, measure(name), @destinations, cacerts)
      end

      test "resized with set_pool_count/3",
           %{finch_name: name, cacerts: cacerts, protocol: protocol} do
        url = start_server(:https)
        start_finch!(name, cacerts, protocols: [protocol])
        assert {:ok, %{status: 200}} = request(name, url)
        baseline = measure(name)

        assert :ok = Finch.set_pool_count(name, url, 5)

        assert_cheaper_than_certificates(baseline, measure(name), 4, cacerts)
      end
    end
  end

  # The configuration from the report
  defp start_finch!(name, cacerts, pool_opts) do
    default = [
      size: 10,
      pool_max_idle_time: :timer.seconds(60),
      conn_max_idle_time: :timer.seconds(15),
      protocols: [:http1],
      conn_opts: [transport_opts: [cacerts: cacerts, verify: :verify_none]]
    ]

    start_supervised!({Finch, name: name, pools: %{default: Keyword.merge(default, pool_opts)}})
  end

  # Before 0.24 a request could reach an HTTP/2 pool that was still connecting
  defp request(name, url, attempts \\ 20) do
    case Finch.request(Finch.build(:get, url), name) do
      {:error, _} when attempts > 0 ->
        Process.sleep(50)
        request(name, url, attempts - 1)

      result ->
        result
    end
  end

  # :public_key.cacerts_get/0 returns a term kept in :persistent_term, which
  # processes share instead of copying. Build the same shape from the fixture so
  # that the suite does not depend on the machine's CA store.
  defp cacerts do
    [{:Certificate, der, :not_encrypted}] =
      @fixtures_dir |> Path.join("selfsigned.pem") |> File.read!() |> :public_key.pem_decode()

    certs = for _ <- 1..150, do: {:cert, der, :public_key.pkix_decode_cert(der, :otp)}
    :persistent_term.put({__MODULE__, :cacerts}, certs)
    :persistent_term.get({__MODULE__, :cacerts})
  end

  defp certificate_bytes(cacerts) do
    :erts_debug.flat_size(cacerts) * :erlang.system_info(:wordsize)
  end

  ## Measuring

  # Memory of every process and ETS table in the Finch supervision tree, as an
  # operator would see it (resident) and after garbage collection (live).
  defp measure(name) do
    pids = processes(name)
    resident = process_memory(pids)
    Enum.each(pids, &:erlang.garbage_collect/1)
    tables = table_memory(pids)

    %{resident: resident + tables, live: process_memory(pids) + tables}
  end

  defp processes(name) do
    supervisor = Process.whereis(:"#{name}.Supervisor")
    [supervisor | descendants(supervisor)]
  end

  defp descendants(supervisor) do
    for {_id, pid, type, _modules} <- Supervisor.which_children(supervisor),
        is_pid(pid),
        pid <- [pid | if(type == :supervisor, do: descendants(pid), else: [])] do
      pid
    end
  end

  defp process_memory(pids) do
    pids
    |> Enum.map(fn pid ->
      {:memory, bytes} = Process.info(pid, :memory)
      bytes
    end)
    |> Enum.sum()
  end

  defp table_memory(pids) do
    words =
      for table <- :ets.all(), :ets.info(table, :owner) in pids do
        :ets.info(table, :memory)
      end

    Enum.sum(words) * :erlang.system_info(:wordsize)
  end

  # The largest heap that a process making a request had. Its garbage
  # collections are traced, as the heap may shrink again before the request ends.
  defp caller_memory(name, url) do
    caller =
      spawn_link(fn ->
        receive do
          :request -> assert {:ok, %{status: 200}} = request(name, url)
        end
      end)

    :erlang.trace(caller, true, [:garbage_collection])
    ref = Process.monitor(caller)
    send(caller, :request)

    largest_heap(caller, ref, 0) * :erlang.system_info(:wordsize)
  end

  defp largest_heap(caller, ref, words) do
    receive do
      {:trace, ^caller, _event, info} ->
        heap = info[:heap_block_size] + info[:old_heap_block_size] + info[:mbuf_size]
        largest_heap(caller, ref, max(words, heap))

      {:DOWN, ^ref, :process, ^caller, _reason} ->
        words
    end
  end

  defp assert_cheaper_than_certificates(baseline, current, count, cacerts) do
    costs = for kind <- [:resident, :live], do: {kind, div(current[kind] - baseline[kind], count)}
    assert_cheaper_than_certificates(costs, cacerts)
  end

  defp assert_cheaper_than_certificates(costs, cacerts) do
    limit = certificate_bytes(cacerts)
    got = Enum.map_join(costs, ", ", fn {kind, cost} -> "#{div(cost, 1024)} KB #{kind}" end)

    assert Enum.all?(costs, fn {_kind, cost} -> cost < limit end),
           "expected less memory than a copy of the CA certificates " <>
             "(#{div(limit, 1024)} KB), got #{got}"
  end

  ## Destinations

  # Every server listens on its own port, which makes it a separate destination.
  # It speaks HTTP/1 and HTTP/2. Tests start it before Finch, so that Finch is
  # stopped first and its pools do not try to reconnect.
  defp start_server(scheme) do
    ref = make_ref()

    options = [
      ref: ref,
      port: 0,
      transport_options: [num_acceptors: 2],
      protocol_options: [request_timeout: :infinity]
    ]

    start_supervised!(
      Plug.Cowboy.child_spec(
        scheme: scheme,
        plug: Finch.HTTP2Server.PlugRouter,
        options: options ++ tls_options(scheme)
      )
    )

    "#{scheme}://localhost:#{:ranch.get_port(ref)}"
  end

  defp tls_options(:http), do: []

  defp tls_options(:https) do
    [
      certfile: Path.join(@fixtures_dir, "selfsigned.pem"),
      keyfile: Path.join(@fixtures_dir, "selfsigned_key.pem")
    ]
  end

  defp refused_destinations(scheme, count) do
    sockets =
      for _ <- 1..count do
        {:ok, listen} = :gen_tcp.listen(0, [])
        listen
      end

    urls =
      for listen <- sockets do
        {:ok, port} = :inet.port(listen)
        "#{scheme}://localhost:#{port}"
      end

    Enum.each(sockets, &:gen_tcp.close/1)
    urls
  end
end
