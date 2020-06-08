defmodule Finch.Error do
  defexception [:reason]

  def message(%{reason: reason}) do
    ""
  end
end
