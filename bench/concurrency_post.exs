# bench/concurrency_post.exs

# Calculate hash of the benchmark file
file_content = File.read!(__ENV__.file)
file_hash = :crypto.hash(:sha256, file_content) |> Base.encode16(case: :lower) |> String.slice(0, 7)

# Get Git Short SHA
{git_sha, 0} = System.cmd("git", ["rev-parse", "--short", "HEAD"])
git_sha = String.trim(git_sha)

IO.puts("Running benchmark for file hash: #{file_hash} and commit: #{git_sha}")

# Define a simple Plug Router for the server
defmodule BenchServer do
  use Plug.Router

  plug :match
  plug :dispatch

  post "/" do
    send_resp(conn, 200, "OK")
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end

# Start the server
port = 4000
{:ok, _} = Plug.Cowboy.http(BenchServer, [], port: port, protocol_options: [max_keepalive: 10_000_000])

# Start Finch
{:ok, _} = Finch.start_link(
  name: MyFinch,
  pools: %{
    :default => [
      size: 50,
      count: 4,
      conn_opts: [transport_opts: [recbuf: 1024 * 1024]]
    ]
  }
)

url = "http://localhost:#{port}/"
body = "some payload"
req = Finch.build(:post, url, [], body)

# Benchmark
Benchee.run(
  %{
    "http1_post_concurrency" => fn ->
      {:ok, _} = Finch.request(req, MyFinch)
    end
  },
  parallel: 10,
  formatters: [
    {Benchee.Formatters.HTML, file: "bench/results/#{file_hash}/#{git_sha}/concurrency_post.html"},
    {Benchee.Formatters.JSON, file: "bench/results/#{file_hash}/#{git_sha}/concurrency_post.json"},
    Benchee.Formatters.Console
  ]
)
