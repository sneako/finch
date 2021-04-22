defmodule Finch.SSL do
  @moduledoc false

  alias Mint.HTTP

  def maybe_log_secrets(:https, mint) do
    socket = HTTP.get_socket(mint)
    maybe_log_secrets(:https, System.get_env("SSLKEYLOGFILE"), socket)
  end

  def maybe_log_secrets(_scheme, _mint) do
    :ok
  end

  defp maybe_log_secrets(:https, nil, _mint) do
    :ok
  end

  defp maybe_log_secrets(:https, ssl_key_log_file, socket) do
    # Note: not every ssl library version returns information for :keylog. By using `with` here,
    # anything other than the expected return value is silently ignored.
    with {:ok, [{:keylog, keylog_items}]} <- :ssl.connection_information(socket, [:keylog]),
         {:ok, f} <- File.open(ssl_key_log_file, [:append]) do
      try do
        for keylog_item <- keylog_items do
          :ok = IO.puts(f, keylog_item)
        end
      after
        File.close(f)
      end
    end
  end
end
