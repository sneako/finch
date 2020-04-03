defmodule Finch do
  @moduledoc """
  Finch

  Create your Finch HTTP Client like so:

      defmodule MyFinch do
        use Finch
      end

  For HTTP/1 connections, Finch allows you to configure how many pools and their size,
  for any {scheme, host, port} combination at compile time.

  You can also configure a `:default` pool size and pool count that will be used for any
  {scheme, host, port} you did not already configure.

  Here is an example of what that might look like:

      defmodule MyConfiguredFinch do
        use Finch, pools: %{
          :default => %{size: 10, count: 1},
          {:https, "hex.pm", 443} => %{size: 20, count: 4}
        }
      end
  """
  defmacro __using__(opts) do
    quote do
      @config %{
        name: __MODULE__,
        pool_sup_name: :"#{__MODULE__}.PoolSup",
        pool_reg_name: :"#{__MODULE__}.PoolRegistry",
        pools: Keyword.get(unquote(opts), :pools, %{})
      }

      def start_link do
        name = :"#{__MODULE__}.PoolManager"
        Finch.PoolManager.start_link(name, @config)
      end

      def request(method, url, headers, body, opts) do
        Finch.request(@config, method, url, headers, body, opts)
      end
    end
  end

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

  def request(config, method, url, headers, body, opts) do
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
    pool = PoolManager.get_pool(config, req.scheme, req.host, req.port)
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
