if Code.ensure_loaded?(Plug) do
  defmodule LoggerJSON.PlugUtils do
    @moduledoc """
    This module contains functions that can be used across different
    `LoggerJSON.Plug.MetadataFormatters` implementations to provide
    common functionality.
    """

    alias Plug.Conn

    @doc """
    Grabs the client IP address from `Plug.Conn`. First we try
    to grab the client IP from the `x-forwarded-for` header.
    Then we fall back to the `conn.remote_ip` field.
    """
    def remote_ip(conn) do
      if header_value = get_header(conn, "x-forwarded-for") do
        header_value
        |> String.split(",")
        |> hd()
        |> String.trim()
      else
        to_string(:inet_parse.ntoa(conn.remote_ip))
      end
    end

    @doc false
    def get_header(conn, header) do
      case Conn.get_req_header(conn, header) do
        [] -> nil
        [val | _] -> val
      end
    end
  end
end
