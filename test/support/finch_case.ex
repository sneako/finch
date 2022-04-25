defmodule FinchCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import FinchCase
    end
  end

  setup %{test: finch_name} do
    {:ok, bypass: Bypass.open(), finch_name: finch_name}
  end

  @doc "Returns the url for a Bypass instance"
  def endpoint(%{port: port}, path \\ "/"), do: "http://localhost:#{port}#{path}"
end
