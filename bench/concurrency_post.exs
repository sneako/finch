# bench/concurrency_post.exs

# Get Git Short SHA
{git_sha, 0} = System.cmd("git", ["rev-parse", "--short", "HEAD"])
git_sha = String.trim(git_sha)

IO.puts("Running benchmark for commit: #{git_sha}")

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
{:ok, _} = Plug.Cowboy.http(BenchServer, [], port: port)

# Start Finch
{:ok, _} = Finch.start_link(name: MyFinch)

url = "http://localhost:#{port}/"
body = "some payload"

# Benchmark
Benchee.run(
  %{
    "http1_post_concurrency" => fn ->
      {:ok, _} = Finch.build(:post, url, [], body) |> Finch.request(MyFinch)
    end
  },
  parallel: 10, # Simulating concurrency
  time: 5,
  memory_time: 2,
  formatters: [
    {Benchee.Formatters.HTML, file: "bench/results/#{git_sha}/concurrency_post.html"},
    {Benchee.Formatters.JSON, file: "bench/results/#{git_sha}/concurrency_post.json"},
    Benchee.Formatters.Console
  ]
)
