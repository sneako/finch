defmodule NameStruct do
  @moduledoc """
  Needed for tests on structs that implement the Jason.Encoder protocol.
  Defining this struct in the test module wouldn't work, since the .exs files
  are not within the compilation folders.
  """

  @derive Jason.Encoder

  defstruct [:name]
end
