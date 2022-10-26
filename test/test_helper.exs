ExUnit.start()
Application.ensure_all_started(:bypass)

defmodule Finch.TestHelper do
  def ssl_version() do
    Application.spec(:ssl, :vsn)
    |> List.to_string()
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
  end
end
