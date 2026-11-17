# Measures the throughput of a Finch version with the configuration from
# https://github.com/sneako/finch/issues/385 and compares it with earlier runs.
#
#     elixir bench/throughput.exs                 # this checkout
#     FINCH=v0.21.0 elixir bench/throughput.exs   # a tag, branch or commit of this repository
#     elixir bench/throughput.exs report          # compare the saved runs without measuring
#
# Options, as environment variables:
#
#   * LABEL - the name of the run, defaults to FINCH or the current branch
#   * BENCH_TIME - seconds to measure each scenario for, defaults to 5
#   * BENCH_PARALLEL - concurrent callers in the second pass, defaults to the number of schedulers
#
# Every run is saved to bench/results under its label. Only API that exists in
# 0.21 is used, so that any version since can be measured.

root = Path.expand("..", __DIR__)
results = Path.join(root, "bench/results")
ref = System.get_env("FINCH")
report_only? = System.argv() == ["report"]

finch = if ref, do: {:finch, git: root, ref: ref}, else: {:finch, path: root}
Mix.install([finch, {:benchee, "~> 1.3"}, {:cowboy, "~> 2.12"}])

defmodule Bench.Server do
  @moduledoc false
  # Every server listens on its own port, which makes it a separate destination.
  # HTTP/1 is answered by a loop that does as little as possible, HTTP/2 by Cowboy.

  def start(:http2, scheme, fixtures) do
    ref = make_ref()
    dispatch = :cowboy_router.compile([{:_, [{:_, __MODULE__, []}]}])

    # Lift the limit on frames, which the requests of a benchmark exceed
    protocol = %{env: %{dispatch: dispatch}, max_received_frame_rate: {1_000_000_000, 10_000}}
    transport = %{num_acceptors: 1, socket_opts: [port: 0] ++ tls_opts(scheme, fixtures)}

    {:ok, _} =
      case scheme do
        :https -> :cowboy.start_tls(ref, transport, protocol)
        :http -> :cowboy.start_clear(ref, transport, protocol)
      end

    "#{scheme}://localhost:#{:ranch.get_port(ref)}"
  end

  def start(:http1, scheme, fixtures) do
    transport = transport(scheme)
    {:ok, listen} = transport.listen(0, listen_opts(scheme, fixtures))
    spawn_link(fn -> accept(transport, listen) end)

    "#{scheme}://localhost:#{port(transport, listen)}"
  end

  defp transport(:https), do: :ssl
  defp transport(:http), do: :gen_tcp

  # The Cowboy handler
  def init(request, state) do
    {:ok, :cowboy_req.reply(200, %{}, "ok", request), state}
  end

  defp listen_opts(scheme, fixtures) do
    [mode: :binary, active: false, reuseaddr: true, nodelay: true, backlog: 1024] ++
      tls_opts(scheme, fixtures)
  end

  defp tls_opts(:http, _fixtures), do: []

  defp tls_opts(:https, fixtures) do
    [
      certfile: Path.join(fixtures, "selfsigned.pem"),
      keyfile: Path.join(fixtures, "selfsigned_key.pem")
    ]
  end

  defp port(:ssl, listen) do
    {:ok, {_address, port}} = :ssl.sockname(listen)
    port
  end

  defp port(:gen_tcp, listen) do
    {:ok, port} = :inet.port(listen)
    port
  end

  defp accept(transport, listen) do
    with {:ok, socket} <- accept_socket(transport, listen) do
      spawn(fn -> accept(transport, listen) end)

      with {:ok, socket} <- handshake(transport, socket) do
        serve(transport, socket, "")
      end
    end
  end

  defp accept_socket(:ssl, listen), do: :ssl.transport_accept(listen)
  defp accept_socket(:gen_tcp, listen), do: :gen_tcp.accept(listen)

  defp handshake(:ssl, socket), do: :ssl.handshake(socket, 5_000)
  defp handshake(:gen_tcp, socket), do: {:ok, socket}

  # Requests in this benchmark have no body, so a request ends with its headers
  defp serve(transport, socket, buffer) do
    case transport.recv(socket, 0) do
      {:ok, data} ->
        if String.ends_with?(buffer <> data, "\r\n\r\n") do
          transport.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
          serve(transport, socket, "")
        else
          serve(transport, socket, buffer <> data)
        end

      {:error, _reason} ->
        transport.close(socket)
    end
  end
end

label =
  System.get_env("LABEL") || ref ||
    "git"
    |> System.cmd(["rev-parse", "--abbrev-ref", "HEAD"], cd: root)
    |> elem(0)
    |> String.trim()

time = "BENCH_TIME" |> System.get_env("5") |> String.to_integer()

parallel =
  "BENCH_PARALLEL" |> System.get_env("#{System.schedulers_online()}") |> String.to_integer()

saved = fn label, parallel ->
  Path.join(results, "#{String.replace(label, "/", "-")}.#{parallel}.benchee")
end

unless report_only? do
  versions =
    for app <- [:finch, :mint, :nimble_pool], do: "#{app} #{Application.spec(app, :vsn)}"

  IO.puts("Measuring #{label} (#{Enum.join(versions, ", ")})\n")

  fixtures = Path.join(root, "test/fixtures")
  callers = :atomics.new(1, [])
  destinations_per_caller = 32

  scenarios =
    for {protocol, title} <- [http1: "HTTP/1", http2: "HTTP/2"], reduce: %{} do
      scenarios ->
        name = Module.concat(Bench, title)

        {:ok, _} =
          Finch.start_link(
            name: name,
            pools: %{
              default: [
                size: 50,
                pool_max_idle_time: :timer.seconds(60),
                conn_max_idle_time: :timer.seconds(15),
                protocols: [protocol],
                # The configuration from the report. :linger is added, as the
                # connections closed by the first request scenarios would otherwise
                # wait in TIME_WAIT until the machine runs out of ports.
                conn_opts: [
                  transport_opts: [
                    cacerts: :public_key.cacerts_get(),
                    verify: :verify_none,
                    linger: {true, 0}
                  ]
                ]
              ]
            }
          )

        https = Finch.build(:get, Bench.Server.start(protocol, :https, fixtures))
        http = Finch.build(:get, Bench.Server.start(protocol, :http, fixtures))

        # The pool of a new destination is stopped after the request, which must
        # not happen while another caller uses it. Every caller has destinations
        # of its own, enough of them to not use one again before its pool is gone.
        destinations =
          for _ <- 1..(parallel * destinations_per_caller) do
            Bench.Server.start(protocol, :https, fixtures)
          end

        destinations = List.to_tuple(destinations)

        next_destination = fn ->
          {caller, requests} =
            Process.get(:bench) || {rem(:atomics.add_get(callers, 1, 1), parallel), 0}

          Process.put(:bench, {caller, requests + 1})
          index = caller * destinations_per_caller + rem(requests, destinations_per_caller)
          elem(destinations, index)
        end

        request = fn request ->
          {:ok, %{status: 200}} = Finch.request(request, name)
          request
        end

        Map.merge(scenarios, %{
          "#{title} request to an https destination" => %{
            before_each: fn -> https end,
            run: request,
            after_each: fn _request -> :ok end
          },
          "#{title} request to an http destination" => %{
            before_each: fn -> http end,
            run: request,
            after_each: fn _request -> :ok end
          },
          "#{title} first request to an https destination" => %{
            before_each: fn -> next_destination.() end,
            run: fn url ->
              request.(Finch.build(:get, url))
              url
            end,
            after_each: fn url -> Finch.stop_pool(name, url) end
          }
        })
    end

  for parallel <- Enum.uniq([1, parallel]) do
    Benchee.run(
      %{"Finch" => fn {scenario, argument} -> {scenario, scenario.run.(argument)} end},
      inputs: scenarios,
      before_each: fn scenario -> {scenario, scenario.before_each.()} end,
      after_each: fn {scenario, result} -> scenario.after_each.(result) end,
      time: time,
      warmup: 2,
      parallel: parallel,
      formatters: [],
      print: [configuration: false],
      save: [path: saved.(label, parallel), tag: label]
    )
  end
end

for parallel <- Enum.uniq([1, parallel]), Path.wildcard(saved.("*", parallel)) != [] do
  Benchee.report(
    load: saved.("*", parallel),
    title: "#{parallel} concurrent caller(s)",
    print: [configuration: false]
  )
end
