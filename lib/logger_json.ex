defmodule LoggerJSON do
  @moduledoc """
  JSON console back-end for Elixir Logger.

  It can be used as drop-in replacement for default `:console` Logger back-end in cases where you use
  use Google Cloud Logger or other JSON-based log collectors.

  ## Log Format

  LoggerJSON provides two JSON formatters out of the box.

  You can change this structure by implementing `LoggerJSON.Formatter` behaviour and passing module
  name to `:formatter` config option. Example implementations can be found in `LoggerJSON.Formatters.GoogleCloudLogger`
  and `LoggerJSON.Formatters.BasicLogger`.

      config :logger_json, :backend,
        formatter: MyFormatterImplementation

  ## Encoders support

  You can replace default Jason encoder with other module that supports `encode!/1` function. This can be even used
  as custom formatter callback.

  Popular Jason alternatives:

   * [poison](https://hex.pm/packages/poison).
   * [exjsx](https://github.com/talentdeficit/exjsx).
   * [elixir-json](https://github.com/cblage/elixir-json) - native Elixir encoder implementation.
   * [jiffy](https://github.com/davisp/jiffy).

  ## Dynamic configuration

  For dynamically configuring the endpoint, such as loading data
  from environment variables or configuration files, LoggerJSON provides
  an `:on_init` option that allows developers to set a module, function
  and list of arguments that is invoked when the endpoint starts. If you
  would like to disable the `:on_init` callback function dynamically, you
  can pass in `:disabled` and no callback function will be called.

      config :logger_json, :backend,
        on_init: {YourApp.Logger, :load_from_system_env, []}

  """
  @behaviour :gen_event

  @ignored_metadata_keys ~w[ansi_color initial_call crash_reason pid gl mfa report_cb time]a

  defstruct metadata: nil,
            level: nil,
            device: nil,
            max_buffer: nil,
            buffer_size: 0,
            buffer: [],
            ref: nil,
            output: nil,
            json_encoder: nil,
            on_init: nil,
            formatter: nil

  @doc """
  Configures Logger log level at runtime by using value from environment variable.

  By default, 'LOG_LEVEL' environment variable is used.
  """
  def configure_log_level_from_env!(env_name \\ "LOG_LEVEL") do
    env_name
    |> System.get_env()
    |> configure_log_level!()
  end

  @doc """
  Changes Logger log level at runtime.

  Notice that settings this value below `compile_time_purge_level` would not work,
  because Logger calls would be already stripped at compile-time.
  """
  def configure_log_level!(nil), do: :ok

  def configure_log_level!(level) when level in ["debug", "info", "warn", "error"],
    do: Logger.configure(level: String.to_atom(level))

  def configure_log_level!(level) when is_atom(level), do: Logger.configure(level: level)

  def configure_log_level!(level) do
    raise ArgumentError,
          "LOG_LEVEL environment should have one of 'debug', 'info', 'warn', 'error' values, got: #{inspect(level)}"
  end

  def init(__MODULE__) do
    config = get_env()
    device = Keyword.get(config, :device, :user)

    if Process.whereis(device) do
      {:ok, init(config, %__MODULE__{})}
    else
      {:error, :ignore}
    end
  end

  def init({__MODULE__, opts}) when is_list(opts) do
    config = configure_merge(get_env(), opts)
    {:ok, init(config, %__MODULE__{})}
  end

  def handle_call({:configure, options}, state) do
    config = configure_merge(get_env(), options)
    put_env(config)

    {:ok, :ok, init(config, state)}
  end

  def handle_event({level, _gl, {Logger, msg, ts, md}}, state) do
    %{level: log_level, ref: ref, buffer_size: buffer_size, max_buffer: max_buffer} = state

    cond do
      not meet_level?(level, log_level) ->
        {:ok, state}

      is_nil(ref) ->
        {:ok, log_event(level, msg, ts, md, state)}

      buffer_size < max_buffer ->
        {:ok, buffer_event(level, msg, ts, md, state)}

      buffer_size === max_buffer ->
        state = buffer_event(level, msg, ts, md, state)
        {:ok, await_io(state)}
    end
  end

  def handle_event(:flush, state) do
    {:ok, flush(state)}
  end

  def handle_event(_, state) do
    {:ok, state}
  end

  def handle_info({:io_reply, ref, msg}, %{ref: ref} = state) do
    {:ok, handle_io_reply(msg, state)}
  end

  def handle_info({:DOWN, ref, _, pid, reason}, %{ref: ref}) do
    raise "device #{inspect(pid)} exited: " <> Exception.format_exit(reason)
  end

  def handle_info(_, state) do
    {:ok, state}
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(_reason, _state) do
    :ok
  end

  # Helpers

  # Somehow Logger.Watcher is started before Application loads configuration
  # so we use default value here and expect back-end to be reconfigured later.
  defp get_env, do: Application.get_env(:logger_json, :backend, [])

  defp put_env(env), do: Application.put_env(:logger_json, :backend, env)

  defp meet_level?(_lvl, nil), do: true
  defp meet_level?(lvl, min), do: Logger.compare_levels(lvl, min) != :lt

  defp init(config, state) do
    config =
      case Keyword.fetch(config, :on_init) do
        {:ok, {mod, fun, args}} ->
          {:ok, conf} = apply(mod, fun, [config | args])
          conf

        {:ok, :disabled} ->
          config

        {:ok, other} ->
          raise ArgumentError,
                "invalid :on_init option for :logger_json application. " <>
                  "Expected a tuple with module, function and args, got: #{inspect(other)}"

        :error ->
          config
      end

    json_encoder = Keyword.get(config, :json_encoder, Jason)
    formatter = Keyword.get(config, :formatter, LoggerJSON.Formatters.BasicLogger)
    level = Keyword.get(config, :level)
    device = Keyword.get(config, :device, :user)
    max_buffer = Keyword.get(config, :max_buffer, 32)

    metadata =
      config
      |> Keyword.get(:metadata, [])
      |> configure_metadata()

    %{
      state
      | metadata: metadata,
        level: level,
        device: device,
        max_buffer: max_buffer,
        json_encoder: json_encoder,
        formatter: formatter
    }
  end

  defp configure_metadata([]), do: []
  defp configure_metadata(:all), do: :all
  defp configure_metadata(metadata) when is_list(metadata), do: Enum.reverse(metadata)

  defp configure_merge(env, options), do: Keyword.merge(env, options, fn _key, _v1, v2 -> v2 end)

  defp log_event(level, msg, ts, md, %{device: device} = state) do
    output = format_event(level, msg, ts, md, state)
    %{state | ref: async_io(device, output), output: output}
  end

  defp buffer_event(level, msg, ts, md, state) do
    %{buffer: buffer, buffer_size: buffer_size} = state
    buffer = [buffer | format_event(level, msg, ts, md, state)]
    %{state | buffer: buffer, buffer_size: buffer_size + 1}
  end

  defp async_io(name, output) when is_atom(name) do
    case Process.whereis(name) do
      device when is_pid(device) ->
        async_io(device, output)

      nil ->
        raise "no device registered with the name #{inspect(name)}"
    end
  end

  defp async_io(device, output) when is_pid(device) do
    ref = Process.monitor(device)
    send(device, {:io_request, self(), ref, {:put_chars, :unicode, output}})
    ref
  end

  defp await_io(%{ref: nil} = state), do: state

  defp await_io(%{ref: ref} = state) do
    receive do
      {:io_reply, ^ref, :ok} ->
        handle_io_reply(:ok, state)

      {:io_reply, ^ref, error} ->
        error
        |> handle_io_reply(state)
        |> await_io()

      {:DOWN, ^ref, _, pid, reason} ->
        raise "device #{inspect(pid)} exited: " <> Exception.format_exit(reason)
    end
  end

  defp format_event(level, msg, ts, md, state) do
    %{json_encoder: json_encoder, formatter: formatter, metadata: md_keys} = state

    unless formatter do
      raise ArgumentError,
            "invalid :formatter option for :logger_json application. " <>
              "Expected module name that implements LoggerJSON.Formatter behaviour, " <> "got: #{inspect(json_encoder)}"
    end

    event = formatter.format_event(level, msg, ts, md, md_keys)

    case json_encoder do
      nil ->
        raise ArgumentError,
              "invalid :json_encoder option for :logger_json application. " <>
                "Expected one of supported encoders module name or {module, function}, " <>
                "got: #{inspect(json_encoder)}. Logged entry: #{inspect(event)}"

      {module, fun} ->
        apply(module, fun, [event]) <> "\n"

      json_encoder ->
        [json_encoder.encode_to_iodata!(event) | "\n"]
    end
  end

  # Drops keys that can not or should not be encoded to JSON
  def take_metadata(metadata, keys_or_all, ignored_keys \\ [])

  def take_metadata(metadata, :all, ignored_keys) do
    metadata
    |> Keyword.drop(ignored_keys ++ @ignored_metadata_keys)
    |> Enum.into(%{})
  end

  def take_metadata(metadata, keys, ignored_keys) do
    metadata = Keyword.drop(metadata, ignored_keys ++ @ignored_metadata_keys)
    Enum.reduce(keys, %{}, &append_metadata_key_to_acc(metadata, &1, &2))
  end

  defp append_metadata_key_to_acc(metadata, key, acc) do
    case Keyword.fetch(metadata, key) do
      {:ok, val} ->
        Map.put(acc, key, val)

      :error ->
        acc
    end
  end

  defp handle_io_reply(:ok, %{ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    log_buffer(%{state | ref: nil, output: nil})
  end

  defp handle_io_reply({:error, {:put_chars, :unicode, _} = error}, state) do
    retry_log(error, state)
  end

  defp handle_io_reply({:error, :put_chars}, %{output: output} = state) do
    retry_log({:put_chars, :unicode, output}, state)
  end

  defp handle_io_reply({:error, error}, _) do
    raise "failure while logging console messages: " <> inspect(error)
  end

  defp log_buffer(%{buffer_size: 0, buffer: []} = state), do: state

  defp log_buffer(state) do
    %{device: device, buffer: buffer} = state
    %{state | ref: async_io(device, buffer), buffer: [], buffer_size: 0, output: buffer}
  end

  defp retry_log(error, %{device: device, ref: ref, output: dirty} = state) do
    Process.demonitor(ref, [:flush])

    case :unicode.characters_to_binary(dirty) do
      {_, good, bad} ->
        clean = [good | Logger.Formatter.prune(bad)]
        %{state | ref: async_io(device, clean), output: clean}

      _ ->
        # A well behaved IO device should not error on good data
        raise "failure while logging consoles messages: " <> inspect(error)
    end
  end

  defp flush(%{ref: nil} = state), do: state

  defp flush(state) do
    state
    |> await_io()
    |> flush()
  end
end
