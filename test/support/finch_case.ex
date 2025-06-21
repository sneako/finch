defmodule FinchCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import FinchCase
    end
  end

  setup context do
    bypass =
      case context do
        %{bypass: false} -> []
        %{} -> [bypass: Bypass.open()]
      end

    {:ok, bypass ++ [finch_name: context.test]}
  end

  @doc "Returns the URL for a Bypass instance"
  def endpoint(%{port: port}, path \\ "/"), do: "http://localhost:#{port}#{path}"
end
