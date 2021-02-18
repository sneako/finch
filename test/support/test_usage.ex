defmodule Finch.TestUsage do
  @moduledoc false
  # This module only exists in order to force dialyzer to pick up potential type
  # errors

  def call do
    req = Finch.build(:get, "https://keathley.io")
    Finch.request(req, __MODULE__, [])
  end
end
