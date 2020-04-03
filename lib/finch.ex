defmodule Finch do
  @moduledoc """
  Start Finch in your supervision tree, passing a `:name` is required:

      {Finch, name: MyFinch}

  For HTTP/1 connections, Finch allows you to configure how many pools and their size,
  for any {scheme, host, port} combination at compile time.

  You can also configure a `:default` pool size and pool count that will be used for any
  {scheme, host, port} you did not already configure.

  Here is an example of what that might look like:

      {Finch, name: MyFinch, pools: %{
         :default => %{size: 10, count: 1},
         {:https, "hex.pm", 443} => %{size: 20, count: 4}
      }

  And then you can use it by passing the name to the request function:

      Finch.request(MyFinch, ...)
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

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    config = %{
      registry_name: name,
      manager_name: pool_manager_name(name),
      supervisor_name: pool_supervisor_name(name),
      pools: Keyword.get(opts, :pools, %{})
    }

    Finch.PoolManager.start_link(config)
  end

  def request(name, method, url, headers, body, opts \\ []) do
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

    pool = PoolManager.get_pool(name, req.scheme, req.host, req.port)
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

  defp pool_manager_name(name), do: :"#{name}.PoolManager"
  defp pool_supervisor_name(name), do: :"#{name}.PoolSup"
end
