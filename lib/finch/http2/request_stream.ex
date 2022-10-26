defmodule Finch.HTTP2.RequestStream do
  @moduledoc false

  defstruct [:body, :from, :from_pid, :status, :buffer, :continuation]

  def new(body, {from_pid, _from_ref} = from) do
    enumerable =
      case body do
        {:stream, stream} -> Stream.map(stream, &with_byte_size/1)
        nil -> [with_byte_size("")]
        io_data -> [with_byte_size(io_data)]
      end

    reducer = &reduce_with_suspend/2

    %__MODULE__{
      body: body,
      from: from,
      from_pid: from_pid,
      status: if(body == nil, do: :done, else: :streaming),
      buffer: <<>>,
      continuation: &Enumerable.reduce(enumerable, &1, reducer)
    }
  end

  defp with_byte_size(binary) when is_binary(binary), do: {binary, byte_size(binary)}
  defp with_byte_size(io_data), do: io_data |> IO.iodata_to_binary() |> with_byte_size()

  defp reduce_with_suspend(
         {message, message_size},
         {message_buffer, message_buffer_size, window}
       )
       when message_size + message_buffer_size > window do
    {:suspend,
     {[{message, message_size} | message_buffer], message_size + message_buffer_size, window}}
  end

  defp reduce_with_suspend(
         {message, message_size},
         {message_buffer, message_buffer_size, window}
       ) do
    {:cont, {[message | message_buffer], message_size + message_buffer_size, window}}
  end

  # gets the next chunk of data that will fit into the given window size
  def next_chunk(request, window)

  # when the buffer is empty, continue reducing the stream
  def next_chunk(%__MODULE__{buffer: <<>>} = request, window) do
    continue_reduce(request, {[], 0, window})
  end

  def next_chunk(%__MODULE__{buffer: buffer} = request, window) do
    case buffer do
      <<bytes_to_send::binary-size(window), rest::binary>> ->
        # when the buffer contains more bytes than a window, send as much of the
        # buffer as we can
        {put_in(request.buffer, rest), bytes_to_send}

      _ ->
        # when the buffer can fit in the windows, continue reducing using the buffer
        # as the accumulator
        continue_reduce(request, {[buffer], byte_size(buffer), window})
    end
  end

  defp continue_reduce(request, acc) do
    case request.continuation.({:cont, acc}) do
      {finished, {messages, _size, _window}} when finished in [:done, :halted] ->
        {put_in(request.status, :done), Enum.reverse(messages)}

      {:suspended,
       {[{overload_message, overload_message_size} | messages_that_fit], total_size, window_size},
       next_continuation} ->
        fittable_size = window_size - (total_size - overload_message_size)

        <<fittable_binary::binary-size(fittable_size), overload_binary::binary>> =
          overload_message

        request = %{request | continuation: next_continuation, buffer: overload_binary}

        {request, Enum.reverse([fittable_binary | messages_that_fit])}
    end
  end
end
