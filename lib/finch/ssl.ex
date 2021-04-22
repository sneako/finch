defmodule Finch.SSL do
  @moduledoc false

  alias Mint.HTTP

  def maybe_log_secrets(:https, conn_opts, mint) do
    ssl_key_log_file_device = Keyword.get(conn_opts, :ssl_key_log_file_device)

    if ssl_key_log_file_device != nil do
      socket = HTTP.get_socket(mint)
      # Note: not every ssl library version returns information for :keylog. By using `with` here,
      # anything other than the expected return value is silently ignored.
      with {:ok, [{:keylog, keylog_items}]} <- :ssl.connection_information(socket, [:keylog]) do
        for keylog_item <- keylog_items do
          :ok = IO.puts(ssl_key_log_file_device, keylog_item)
        end
      end
    else
      :ok
    end
  end

  def maybe_log_secrets(_scheme, _conn_opts, _mint) do
    :ok
  end
end
