defmodule Finch.MintHTTP1 do
  @moduledoc false

  # This module exists to ensure that protocol negotiation does not accidentally cause Mint to open
  # HTTP2 connections in our HTTP1 pools.

  alias Mint.HTTP1
  alias Mint.UnsafeProxy

  def connect(scheme, host, port, conn_opts) do
    Mint.HTTP.connect(scheme, host, port, conn_opts)
  end

  def open?(%HTTP1{} = mint) do
    HTTP1.open?(mint)
  end

  def open?(%UnsafeProxy{} = mint) do
    UnsafeProxy.open?(mint)
  end

  def set_mode(%HTTP1{} = mint, mode) do
    HTTP1.set_mode(mint, mode)
  end

  def set_mode(%UnsafeProxy{} = mint, mode) do
    UnsafeProxy.set_mode(mint, mode)
  end

  def stream(%HTTP1{} = mint, message) do
    HTTP1.stream(mint, message)
  end

  def stream(%UnsafeProxy{} = mint, message) do
    UnsafeProxy.stream(mint, message)
  end

  def request(%HTTP1{} = mint, method, path, headers, stream_or_body) do
    HTTP1.request(mint, method, path, headers, stream_or_body)
  end

  def request(%UnsafeProxy{} = mint, method, path, headers, stream_or_body) do
    UnsafeProxy.request(mint, method, path, headers, stream_or_body)
  end

  def close(%HTTP1{} = mint) do
    HTTP1.close(mint)
  end

  def close(%UnsafeProxy{} = mint) do
    UnsafeProxy.close(mint)
  end

  def controlling_process(%HTTP1{} = mint, pid) do
    HTTP1.controlling_process(mint, pid)
  end

  def controlling_process(%UnsafeProxy{} = mint, pid) do
    UnsafeProxy.controlling_process(mint, pid)
  end

  def recv(%HTTP1{} = mint, byte_count, timeout) do
    HTTP1.recv(mint, byte_count, timeout)
  end

  def recv(%UnsafeProxy{} = mint, byte_count, timeout) do
    UnsafeProxy.recv(mint, byte_count, timeout)
  end

  def stream_request_body(%HTTP1{} = mint, ref, chunk) do
    HTTP1.stream_request_body(mint, ref, chunk)
  end

  def stream_request_body(%UnsafeProxy{} = mint, ref, chunk) do
    UnsafeProxy.stream_request_body(mint, ref, chunk)
  end
end
