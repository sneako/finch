defmodule Finch.URI do
  @moduledoc false

  def fetch_host!(%URI{host: host}) when is_binary(host) and byte_size(host) > 0, do: host

  def fetch_host!(%URI{} = parsed_uri) do
    raise ArgumentError, "host is required for url: #{URI.to_string(parsed_uri)}"
  end
end