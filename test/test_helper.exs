{:ok, listen_socket} = :ssl.listen(0, mode: :binary)
{:ok, {_address, port}} = :ssl.sockname(listen_socket)
:ssl.close(listen_socket)

Finch.HTTP2Server.start(port)
Application.put_env(:finch, :test_https_h2_url, "https://localhost:#{port}")

Mimic.copy(Mint.HTTP)

ExUnit.start()
Application.ensure_all_started(:bypass)

defmodule Finch.TestHelper do
  use ExUnit.Case

  def ssl_version() do
    Application.spec(:ssl, :vsn)
    |> List.to_string()
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
  end

  @doc """
  Starts a Finch instance and waits for at least one HTTP/2 pool to register
  (enter the :connected state) before returning. Uses Registry listeners for
  deterministic readiness detection instead of polling with real requests.
  """
  def start_finch!(opts) do
    name = Keyword.fetch!(opts, :name)
    listener = :"finch_test_#{System.unique_integer([:positive])}"
    test_pid = self()
    ref = make_ref()

    spawn(fn ->
      Process.register(self(), listener)
      Process.monitor(test_pid)
      send(test_pid, {ref, :ready})

      receive do
        msg -> send(test_pid, msg)
      end

      receive do
        {:DOWN, _, _, ^test_pid, _} -> :ok
      end
    end)

    assert_receive {^ref, :ready}
    opts = Keyword.put(opts, :registry_listeners, [listener])
    start_supervised!({Finch, opts})
    assert_receive {:register, ^name, _key, _pid, _value}, 5_000
    name
  end
end
