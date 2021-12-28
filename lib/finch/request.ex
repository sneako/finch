defmodule Finch.Request do
  @moduledoc """
  A request struct.
  """

  @enforce_keys [:scheme, :host, :port, :method, :path, :headers, :body, :query]
  defstruct [:scheme, :host, :port, :method, :path, :headers, :body, :query, :unix_socket]

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

  @typedoc """
  An HTTP request method represented as an `atom()` or a `String.t()`.

  The following atom methods are supported: `#{Enum.map_join(@atom_methods, "`, `", &inspect/1)}`.
  You can use any arbitrary method by providing it as a `String.t()`.
  """
  @type method() :: :get | :post | :head | :patch | :delete | :options | :put | String.t()

  @typedoc """
  A Uniform Resource Locator, the address of a resource on the Web.
  """
  @type url() :: String.t() | URI.t()

  @typedoc """
  Request headers.
  """
  @type headers() :: Mint.Types.headers()

  @typedoc """
  Optional request body.
  """
  @type body() :: iodata() | {:stream, Enumerable.t()} | nil

  @type t :: %__MODULE__{
          scheme: Mint.Types.scheme(),
          host: String.t() | nil,
          port: :inet.port_number(),
          method: String.t(),
          path: String.t(),
          headers: headers(),
          body: body(),
          query: String.t() | nil,
          unix_socket: String.t() | nil
        }

  @doc false
  def request_path(%{path: path, query: nil}), do: path
  def request_path(%{path: path, query: ""}), do: path
  def request_path(%{path: path, query: query}), do: "#{path}?#{query}"

  @doc false
  def build(method, url, headers, body, opts) do
    unix_socket = Keyword.get(opts, :unix_socket)
    {scheme, host, port, path, query} = parse_url(url)

    %Finch.Request{
      scheme: scheme,
      host: host,
      port: port,
      method: build_method(method),
      path: path,
      headers: headers,
      body: body,
      query: query,
      unix_socket: unix_socket
    }
  end

  @doc false
  def parse_url(url) when is_binary(url) do
    url |> URI.parse() |> parse_url()
  end

  def parse_url(%URI{} = parsed_uri) do
    normalized_path = parsed_uri.path || "/"

    scheme =
      case parsed_uri.scheme do
        "https" ->
          :https

        "http" ->
          :http

        nil ->
          raise ArgumentError, "scheme is required for url: #{URI.to_string(parsed_uri)}"

        scheme ->
          raise ArgumentError,
                "invalid scheme \"#{scheme}\" for url: #{URI.to_string(parsed_uri)}"
      end

    {scheme, parsed_uri.host, parsed_uri.port, normalized_path, parsed_uri.query}
  end

  defp build_method(method) when is_binary(method), do: method
  defp build_method(method) when method in @atom_methods, do: @atom_to_method[method]

  defp build_method(method) do
    supported = Enum.map_join(@atom_methods, ", ", &inspect/1)

    raise ArgumentError, """
    got unsupported atom method #{inspect(method)}.
    Only the following methods can be provided as atoms: #{supported}.
    Otherwise you must pass a binary.
    """
  end
end
