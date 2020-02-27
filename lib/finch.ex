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
    uri = URI.parse(url)
    req = %{
      scheme: normalize_scheme(uri.scheme),
      host: uri.host,
      port: uri.port,
      method: build_method(method),
      path: uri.path || "/",
      headers: headers,
      body: body
    }
    pool = PoolManager.get_pool(req.scheme, req.host, req.port)
    Pool.request(pool, req, opts)
  end

  defp build_method(method) when method in @methods, do: method
  defp build_method(method) when is_atom(method) do
    @atom_to_method[method]
  end

  defp normalize_scheme(scheme) do
    case scheme do
      "https" -> :https
      "http" -> :http
    end
  end
end
