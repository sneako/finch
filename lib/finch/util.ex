defmodule Finch.Util do
  @moduledoc false

  def maybe_log_secrets(:https, socket) do
    maybe_log_secrets(:https, System.get_env("SSLKEYLOGFILE"), socket)
  end

  def maybe_log_secrets(_scheme, _socket) do
    :ok
  end

  defp maybe_log_secrets(:https, nil, _socket) do
    :ok
  end

  defp maybe_log_secrets(:https, ssl_key_log_file, socket) do
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
