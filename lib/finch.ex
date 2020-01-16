defmodule Finch do
  @moduledoc """
  Finch
  """
  alias Finch.Pool
  alias Finch.PoolManager

  @atom_methods [
    :get,
    :post,
    :put,
    :patch,
    :delete,
    :head,
    :options
  ]
  @methods [
    "GET",
    "POST",
    "PUT",
    "PATCH",
    "DELETE",
    "HEAD",
    "OPTIONS"
  ]
  @atom_to_method Enum.zip(@atom_methods, @methods) |> Enum.into(%{})

  def request(method, url, headers, body, opts) do
    {scheme, host, port, path} = parse_url(url)
    req = %{
      method: build_method(method),
      path: path || "/",
      headers: headers,
      body: body
    }
    |> IO.inspect(label: "Req")
    pool = PoolManager.get_pool({scheme, host, port})
    Pool.request(pool, req, opts)
  end

  defp build_method(method) when method in @methods, do: method
  defp build_method(method) when is_atom(method) do
    @atom_to_method[method]
  end

  defp parse_url(url) do
    uri = URI.parse(url)

    {normalize_scheme(uri.scheme), uri.host, uri.port, uri.path}
  end

  defp normalize_scheme(scheme) do
    case scheme do
      "https" -> :https
      "http" -> :http
    end
  end
end
