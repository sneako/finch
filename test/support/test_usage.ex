defmodule Finch.TestUsage do
  @moduledoc false
  # This module only exists in order to force dialyzer to pick up potential type
  # errors

  def call do
    req = Finch.build(:get, "https://keathley.io")

    case Finch.request(req, __MODULE__, []) do
      {:ok, %Finch.Response{} = resp} ->
        resp

      {:error, reason} ->
        raise reason
    end
  end
end
