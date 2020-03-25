defmodule Finch.HTTP2.Pool do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  def init(
end
