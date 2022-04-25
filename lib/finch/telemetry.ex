defmodule Finch.Telemetry do
  @moduledoc """
  Telemetry integration.

  Unless specified, all times are in `:native` units.

  Finch executes the following events:

  ### Request Start

  `[:finch, :request, :start]` - Executed when `Finch.request/3` or `Finch.stream/5` is called.

  #### Measurements

    * `:system_time` - The system time.

  #### Metadata

    * `:name` - The name of the Finch instance.
    * `:request` - The request (`Finch.Request`).

  ### Request Stop

  `[:finch, :request, :stop]` - Executed after `Finch.request/3` or `Finch.stream/5` ended.

  #### Measurements

  * `:duration` - Duration how long the request took.

  #### Metadata

  * `:name` - The name of the Finch instance.
  * `:request` - The request (`Finch.Request`).
  * `:result` - The result of the operation. In case of `Finch.stream/5` this is
    `{:ok, acc} | {:error, Exception.t()}`, where `acc` is the accumulator result of the
    reducer passed in `Finch.stream/5`. In case of `Finch.request/3` this is
    `{:ok, Finch.Response.t()} | {:error, Exception.t()}`.

  ### Request Exception

  `[:finch, :request, :exception]` - Executed when an exception occurs while executing
    `Finch.request/3` or `Finch.stream/5`.

  #### Measurements

    * `:duration` - The time it took since the start before raising the exception.

  #### Metadata

    * `:name` - The name of the Finch instance.
    * `:request` - The request (`Finch.Request`).
    * `:kind` - The type of exception.
    * `:reason` - Error description or error data.
    * `:stacktrace` - The stacktrace.

  ### Queue Start

  `[:finch, :queue, :start]` - Executed before checking out a connection from the pool.

  #### Measurements

    * `:system_time` - The system time.

  #### Metadata

    * `:pool` - The pool's pid.
    * `:request` - The request (`Finch.Request`).

  ### Queue Stop

  `[:finch, :queue, :stop]` - Executed after a connection is retrieved from the pool.

  #### Measurements

    * `:duration` - Duration to check out a pool connection.
    * `:idle_time` - Elapsed time since the connection was last checked in or initialized.

  #### Metadata

    * `:pool` - The pool's pid.
    * `:request` - The request (`Finch.Request`).

  ### Queue Exception

  `[:finch, :queue, :exception]` - Executed if checking out a connection throws an exception.

  #### Measurements

    * `:duration` - The time it took before raising an exception

  #### Metadata

    * `:request` - The request (`Finch.Request`).
    * `:kind` - The type of exception.
    * `:reason` - Error description or error data.
    * `:stacktrace` - The stacktrace.

  ### Connect Start

  `[:finch, :connect, :start]` - Executed before opening a new connection.
    If a connection is being re-used this event will *not* be executed.

  #### Measurements

    * `:system_time` - The system time.

  #### Metadata

    * `:scheme` - The scheme used in the connection. either `http` or `https`.
    * `:host` - The host address.
    * `:port` - the port to connect on.

  ### Connect Stop

  `[:finch, :connect, :stop]` - Executed after a connection is opened.

  #### Measurements

    * `:duration` - Duration to connect to the host.

  #### Metadata

    * `:scheme` - The scheme used in the connection. either `http` or `https`.
    * `:host` - The host address.
    * `:port` - the port to connect on.
    * `:error` - This value is optional. It includes any errors that occurred while opening the connection.

  ### Send Start

  `[:finch, :send, :start]` - Executed before sending a request.

  #### Measurements

    * `:system_time` - The system time.
    * `:idle_time` - Elapsed time since the connection was last checked in or initialized.

  #### Metadata

    * `:request` - The request (`Finch.Request`).

  ### Send Stop

  `[:finch, :send, :stop]` - Executed after a request is finished.

  #### Measurements

    * `:duration` - Duration to make the request.
    * `:idle_time` - Elapsed time since the connection was last checked in or initialized.

  #### Metadata

    * `:request` - The request (`Finch.Request`).
    * `:error` - This value is optional. It includes any errors that occurred while making the request.

  ### Receive Start

  `[:finch, :recv, :start]` - Executed before receiving the response.

  #### Measurements

    * `:system_time` - The system time.
    * `:idle_time` - Elapsed time since the connection was last checked in or initialized.

  #### Metadata

    * `:request` - The request (`Finch.Request`).

  ### Receive Start

  `[:finch, :recv, :stop]` - Executed after a response has been fully received.

  #### Measurements

    * `:duration` - Duration to receive the response.
    * `:idle_time` - Elapsed time since the connection was last checked in or initialized.

  #### Metadata

    * `:request` - The request (`Finch.Request`).
    * `:status` - The response status (`Mint.Types.status()`).
    * `:headers` - The response headers (`Mint.Types.headers()`).
    * `:error` - This value is optional. It includes any errors that occurred while receiving the response.

  ### Receive Exception

  `[:finch, :recv, :exception]` - Executed if an exception is thrown before the response has
    been fully received.

  #### Measurements

    * `:duration` - The time it took before raising an exception

  #### Metadata

    * `:request` - The request (`Finch.Request`).
    * `:kind` - The type of exception.
    * `:reason` - Error description or error data.
    * `:stacktrace` - The stacktrace.

  ### Reused Connection


  `[:finch, :reused_connection]` - Executed if an existing connection is reused. There are no measurements provided with this event.

  #### Metadata

    * `:scheme` - The scheme used in the connection. either `http` or `https`.
    * `:host` - The host address.
    * `:port` - the port to connect on.

  ### Conn Max Idle Time Exceeded

  `[:finch, :conn_max_idle_time_exceeded]` - Executed if a connection was discarded because the `conn_max_idle_time` had been reached.

  #### Measurements

    * `:idle_time` - Elapsed time since the connection was last checked in or initialized.

  #### Metadata

    * `:scheme` - The scheme used in the connection. either `http` or `https`.
    * `:host` - The host address.
    * `:port` - the port to connect on.

  ### Max Idle Time Exceeded

  `[:finch, :max_idle_time_exceeded]` - Executed if a connection was discarded because the `max_idle_time` had been reached.

  Deprecated use `:conn_max_idle_time_exceeded` event instead.

  #### Measurements

    * `:idle_time` - Elapsed time since the connection was last checked in or initialized.

  #### Metadata

    * `:scheme` - The scheme used in the connection. either `http` or `https`.
    * `:host` - The host address.
    * `:port` - the port to connect on.

  ### Pool Max Idle Time Exceeded

  `[:finch, :pool_max_idle_time_exceeded]` - Executed if a pool was terminated because the `pool_max_idle_time` has been reached. There are no measurements provided with this event.

  #### Metadata

    * `:scheme` - The scheme used in the connection. either `http` or `https`.
    * `:host` - The host address.
    * `:port` - the port to connect on.
  """

  @doc false
  # emits a `start` telemetry event and returns the the start time
  def start(event, meta \\ %{}, extra_measurements \\ %{}) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:finch, event, :start],
      Map.merge(extra_measurements, %{system_time: System.system_time()}),
      meta
    )

    start_time
  end

  @doc false
  # Emits a stop event.
  def stop(event, start_time, meta \\ %{}, extra_measurements \\ %{}) do
    end_time = System.monotonic_time()
    measurements = Map.merge(extra_measurements, %{duration: end_time - start_time})

    :telemetry.execute(
      [:finch, event, :stop],
      measurements,
      meta
    )
  end

  @doc false
  def exception(event, start_time, kind, reason, stack, meta \\ %{}, extra_measurements \\ %{}) do
    end_time = System.monotonic_time()
    measurements = Map.merge(extra_measurements, %{duration: end_time - start_time})

    meta =
      meta
      |> Map.put(:kind, kind)
      |> Map.put(:reason, reason)
      |> Map.put(:stacktrace, stack)

    :telemetry.execute([:finch, event, :exception], measurements, meta)
  end

  @doc false
  # Used for reporting generic events
  def event(event, measurements, meta) do
    :telemetry.execute([:finch, event], measurements, meta)
  end

  @doc false
  # Used to easily create :start, :stop, :exception events.
  def span(event, start_metadata, fun) do
    :telemetry.span(
      [:finch, event],
      start_metadata,
      fun
    )
  end
end
