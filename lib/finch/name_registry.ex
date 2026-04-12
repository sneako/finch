defmodule Finch.NameRegistry do
  @moduledoc false

  # Maps `{:via, Registry, {reg, key}}` tuples to auto-generated internal atoms.
  #
  # Finch's internals (Elixir Registry, named ETS tables) require atom identifiers.
  # When a user provides a via tuple as the Finch name, this module generates a
  # unique atom for internal use and stores the mapping in a shared ETS table.
  #
  # The generated atoms are bounded by the number of active Finch instances,
  # not by user input, making this safe for dynamic/multi-tenant use cases.

  @table :finch_via_names

  @doc false
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Generates a unique internal atom for the given via name and stores the mapping.
  Returns the generated atom.
  """
  @spec register({:via, Registry, {atom(), term()}}) :: atom()
  def register({:via, Registry, {_reg, _key}} = via_name) do
    ensure_table()
    internal = :"Finch.Instance.#{:erlang.unique_integer([:positive, :monotonic])}"
    true = :ets.insert(@table, {via_name, internal})
    internal
  end

  @doc """
  Resolves a Finch name to the internal atom used by Finch's subsystems.

  When given an atom, returns it unchanged (no-op).
  When given a via tuple, looks up the internal atom from the ETS table.
  """
  @spec resolve(Finch.name()) :: atom()
  def resolve(name) when is_atom(name), do: name

  def resolve({:via, Registry, {_reg, _key}} = via_name) do
    case :ets.lookup(@table, via_name) do
      [{_, internal}] ->
        internal

      [] ->
        raise ArgumentError,
              "unknown Finch instance #{inspect(via_name)}. " <>
                "Make sure the Finch instance is started before making requests."
    end
  end

  @doc """
  Removes the mapping for the given via name. Called during Finch shutdown.
  """
  @spec unregister({:via, Registry, {atom(), term()}}) :: :ok
  def unregister({:via, Registry, {_reg, _key}} = via_name) do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table, via_name)
    end

    :ok
  end
end
