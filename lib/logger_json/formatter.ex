defmodule LoggerJSON.Formatter do
  @moduledoc """
  Behaviour that should be implemented by log formatters.

  Example implementations can be found in `LoggerJSON.Formatters.GoogleCloudLogger` and
  `LoggerJSON.Formatters.BasicLogger`.
  """

  @doc """
  Format event callback.

  Returned map will be encoded to JSON.
  """
  @callback format_event(
              level :: Logger.level(),
              msg :: Logger.message(),
              ts :: Logger.Formatter.time(),
              md :: [atom] | :all,
              state :: map
            ) :: map | iodata() | %Jason.Fragment{}
end
