defmodule Finch.SSL do
  @moduledoc false

  alias Mint.HTTP

  def get_conn_opts() do
    case System.get_env("SSLKEYLOGFILE") do
      nil ->
        {:ok, nil, false}

      file_name ->
        {:ok, file_name, true}
    end
  end

  def maybe_log_secrets(:https, conn_opts, mint) do
    ssl_key_log_file = Keyword.get(conn_opts, :ssl_key_log_file)

    if ssl_key_log_file != nil do
      socket = HTTP.get_socket(mint)
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
    else
      :ok
    end
  end

  def maybe_log_secrets(_scheme, _conn_opts, _mint) do
    :ok
  end
end
