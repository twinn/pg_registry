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

  @type scope :: atom()
  @type key :: term()
  @type via_name :: {scope(), key()}

  @doc """
  Starts a `PgRegistry` scope.

  The `scope` is an atom used to namespace registrations. It is passed
  directly to `:pg.start_link/1`.
  """
  @spec start_link(scope()) :: {:ok, pid()} | {:error, term()}
  def start_link(scope) when is_atom(scope) do
    :pg.start_link(scope)
  end

  @doc """
  Returns a child specification for use in a supervision tree.

      children = [
        {PgRegistry, :my_registry}
      ]
  """
  @spec child_spec(scope()) :: Supervisor.child_spec()
  def child_spec(scope) do
    %{
      id: {__MODULE__, scope},
      start: {__MODULE__, :start_link, [scope]}
    }
  end

  @doc """
  Registers the given `pid` under `{scope, key}`.

  Always returns `:yes`. Multiple processes can register under the
  same key. Implements the `:via` callback.
  """
  @spec register_name(via_name(), pid()) :: :yes
  def register_name({scope, key}, pid) do
    :pg.join(scope, key, pid)
    :yes
  end

  @doc """
  Unregisters all processes under `{scope, key}`.

  Always returns `:ok`.
  """
  @spec unregister_name(via_name()) :: :ok
  def unregister_name({scope, key}) do
    for pid <- :pg.get_local_members(scope, key) do
      :pg.leave(scope, key, pid)
    end

    :ok
  end

  @doc """
  Looks up the process registered under `{scope, key}`.

  Returns the pid if found, or `:undefined` otherwise.
  """
  @spec whereis_name(via_name()) :: pid() | :undefined
  def whereis_name({scope, key}) do
    case :pg.get_local_members(scope, key) do
      [pid | _] ->
        pid

      [] ->
        case :pg.get_members(scope, key) do
          [pid | _] -> pid
          [] -> :undefined
        end
    end
  end

  @doc """
  Returns all processes registered under `key` in the given `scope`.
  """
  @spec get_members(scope(), key()) :: [pid()]
  defdelegate get_members(scope, key), to: :pg

  @doc """
  Returns all groups in the given `scope`.
  """
  @spec which_groups(scope()) :: [key()]
  defdelegate which_groups(scope), to: :pg

  @doc """
  Invokes `callback` with the list of members registered under `key` in `scope`.
  """
  @spec dispatch(scope(), key(), ([pid()] -> term())) :: :ok
  def dispatch(scope, key, callback) when is_function(callback, 1) do
    case :pg.get_members(scope, key) do
      [] ->
        :ok

      members ->
        callback.(members)
        :ok
    end
  end

  @doc """
  Sends `msg` to the process registered under `{scope, key}`.

  Returns the pid. Raises `ArgumentError` if no process is registered.
  """
  @spec send(via_name(), term()) :: pid()
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
