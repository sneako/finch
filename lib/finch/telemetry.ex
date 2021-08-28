defmodule Finch.Telemetry do
  @moduledoc """
  Telemetry integration.

  Unless specified, all time's are in `:native` units.

  Finch executes the following events:

  * `[:finch, :queue, :start]` - Executed before checking out a connection from the pool.

    #### Measurements

      * `:system_time` - The system time

    #### Metadata:

      * `:pool` - The pool's pid
      * `:scheme` - The scheme used in the connection. either `http` or `https`
      * `:host` - The host address
      * `:port` - the port to connect on.

  * `[:finch, :queue, :stop]` - Executed after a connection is retrieved from the pool.

    #### Measurements

    * `:duration` - Duration to check out a pool connection.
    * `:idle_time` - Elapsed time since the connection was last checked in or initialized.

    #### Metadata

    * `:pool` - The pool's pid
    * `:scheme` - The scheme used in the connection. either `http` or `https`
    * `:host` - The host address
    * `:port` - the port to connect on.

  * `[:finch, :queue, :exception]` - Executed if checking out a connection throws an exception.

    #### Measurements

    * `:duration` - The time it took before raising an exception

    #### Metadata

    * `:scheme` - The scheme used in the connection. either `http` or `https`
    * `:host` - The host address
    * `:port` - the port to connect on.
    * `:kind` - The type of exception.
    * `:error` - Error description or error data.
    * `:stacktrace` - The stacktrace

  * `[:finch, :connect, :start]` - Executed before opening a new connection.
    If a connection is being re-used this event will *not* be executed.

    #### Measurements
    * `:system_time` - The system time

    #### Metadata
    * `:scheme` - The scheme used in the connection. either `http` or `https`
    * `:host` - The host address
    * `:port` - the port to connect on.

  * `[:finch, :connect, :stop]` - Executed after a connection is opened.

    #### Measurements
    * `:duration` - Duration to connect to the host.

    #### Metadata:
    * `:scheme` - The scheme used in the connection. either `http` or `https`
    * `:host` - The host address
    * `:port` - the port to connect on.
    * `:error` - This value is optional. It includes any errors that occurred while opening the connection.

  * `[:finch, :request, :start]` - Executed before sending a request.

    #### Measurements:
    * `:system_time` - The system time
    * `:idle_time` - Elapsed time since the connection was last checked in or initialized.

    #### Metadata:
    * `:scheme` - The scheme used in the connection. either `http` or `https`
    * `:host` - The host address
    * `:port` - the port to connect on.
    * `:path` - The request path.
    * `:method` - The request method.

  * `[:finch, :request, :stop]` - Executed after a request is finished.

    #### Measurements:
    * `:duration` - Duration to make the request.
    * `:idle_time` - Elapsed time since the connection was last checked in or initialized.

    #### Metadata:
    * `:scheme` - The scheme used in the connection. either `http` or `https`
    * `:host` - The host address
    * `:port` - the port to connect on.
    * `:path` - The request path.
    * `:method` - The request method.
    * `:error` - This value is optional. It includes any errors that occurred while making the request.

  * `[:finch, :response, :start]` - Executed before receiving the response.

    #### Measurements:
    * `:system_time` - The system time
    * `:idle_time` - Elapsed time since the connection was last checked in or initialized.

    #### Metadata:
    * `:scheme` - The scheme used in the connection. either `http` or `https`
    * `:host` - The host address
    * `:port` - the port to connect on.
    * `:path` - The request path.
    * `:method` - The request method.

  * `[:finch, :response, :stop]` - Executed after a response has been fully received.

    #### Measurements:
    * `:duration` - Duration to receive the response.
    * `:idle_time` - Elapsed time since the connection was last checked in or initialized.

    #### Metadata:
    * `:scheme` - The scheme used in the connection. either `http` or `https`
    * `:host` - The host address
    * `:port` - the port to connect on.
    * `:path` - The request path.
    * `:method` - The request method.
    * `:error` - This value is optional. It includes any errors that occurred while receiving the response.

  * `[:finch, :reused_connection]` - Executed if an existing connection is reused. There are no measurements provided with this event.

    #### Metadata:
    * `:scheme` - The scheme used in the connection. either `http` or `https`
    * `:host` - The host address
    * `:port` - the port to connect on.

  * `[:finch, :max_idle_time_exceeded]` - Executed if a connection was discarded because the max_idle_time had been reached.

    #### Measurements:
    * `:idle_time` - Elapsed time since the connection was last checked in or initialized.

    #### Metadata

    * `:scheme` - The scheme used in the connection. either `http` or `https`
    * `:host` - The host address
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
      |> Map.put(:error, reason)
      |> Map.put(:stacktrace, stack)

    :telemetry.execute([:finch, event, :exception], measurements, meta)
  end

  @doc false
  # Used for reporting generic events
  def event(event, measurements, meta) do
    :telemetry.execute([:finch, event], measurements, meta)
  end
end
