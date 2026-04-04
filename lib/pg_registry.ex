defmodule PgRegistry do
  @moduledoc """
  A distributed process registry backed by Erlang's `:pg` module.

  Works like Elixir's `Registry` but discovers processes across clusters.

  ## Usage

      # In your supervision tree
      children = [
        {PgRegistry, :my_registry}
      ]

      # Register a GenServer
      GenServer.start_link(MyServer, arg, name: {:via, PgRegistry, {:my_registry, :my_key}})
  """

  @doc """
  Starts a `PgRegistry` scope.

  The `scope` is an atom used to namespace registrations. It is passed
  directly to `:pg.start_link/1`.
  """
  def start_link(scope) when is_atom(scope) do
    :pg.start_link(scope)
  end

  @doc """
  Returns a child specification for use in a supervision tree.

      children = [
        {PgRegistry, :my_registry}
      ]
  """
  def child_spec(scope) do
    %{
      id: {__MODULE__, scope},
      start: {__MODULE__, :start_link, [scope]}
    }
  end

  @doc """
  Registers the given `pid` under `{scope, key}`.

  Returns `:yes` on success or `:no` if another process is already
  registered under the same key. This implements the `:via` callback
  for unique registrations.
  """
  def register_name({scope, key}, pid) do
    case :pg.get_members(scope, key) do
      [] ->
        :pg.join(scope, key, pid)
        :yes

      _members ->
        :no
    end
  end

  @doc """
  Unregisters all processes under `{scope, key}`.

  Always returns `:ok`.
  """
  def unregister_name({scope, key}) do
    for pid <- :pg.get_members(scope, key) do
      :pg.leave(scope, key, pid)
    end

    :ok
  end

  @doc """
  Looks up the process registered under `{scope, key}`.

  Returns the pid if found, or `:undefined` otherwise.
  """
  def whereis_name({scope, key}) do
    case :pg.get_members(scope, key) do
      [pid | _] -> pid
      [] -> :undefined
    end
  end

  @doc """
  Sends `msg` to the process registered under `{scope, key}`.

  Returns the pid. Raises `ArgumentError` if no process is registered.
  """
  def send({scope, key} = name, msg) do
    case whereis_name(name) do
      :undefined ->
        raise ArgumentError, "no process registered under #{inspect({scope, key})}"

      pid ->
        Kernel.send(pid, msg)
        pid
    end
  end
end
