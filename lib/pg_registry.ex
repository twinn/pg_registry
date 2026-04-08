defmodule PgRegistry do
  @moduledoc """
  A distributed process registry backed by `PgRegistry.Pg`.

  Works like Elixir's `Registry` but discovers processes across clusters
  and lets you attach a per-process value (metadata) at registration
  time, just like Registry's `{:via, Registry, {Reg, key, value}}` form.

  ## Usage

      # In your supervision tree
      children = [
        {PgRegistry, :my_registry}
      ]

      # Register a GenServer (no value)
      GenServer.start_link(MyServer, arg, name: {:via, PgRegistry, {:my_registry, :my_key}})

      # Register a GenServer with a value attached
      GenServer.start_link(MyServer, arg,
        name: {:via, PgRegistry, {:my_registry, :my_key, %{role: :primary}}}
      )

      # Look up entries (returns [{pid, value}])
      PgRegistry.lookup(:my_registry, :my_key)
  """

  alias PgRegistry.Pg

  @type scope :: atom()
  @type key :: term()
  @type value :: term()
  @type via_name :: {scope(), key()} | {scope(), key(), value()}

  @doc """
  Starts a `PgRegistry` scope.

  Three forms are accepted:

      PgRegistry.start_link(:my_reg)
      PgRegistry.start_link(:my_reg, listeners: [MyL])
      PgRegistry.start_link(name: :my_reg, listeners: [MyL], keys: :duplicate)

  The third (keyword) form mirrors `Registry.start_link/1` for users
  porting from Registry. `:keys` may be `:duplicate` (a no-op) but
  `:unique` raises — see the README for the rationale. `:partitions`
  is accepted and silently ignored.
  """
  @spec start_link(scope() | keyword()) :: GenServer.on_start()
  def start_link(scope) when is_atom(scope), do: Pg.start_link(scope)

  def start_link(opts) when is_list(opts) do
    {scope, pg_opts} = parse_keyword_opts(opts)
    Pg.start_link(scope, pg_opts)
  end

  @spec start_link(scope(), keyword()) :: GenServer.on_start()
  def start_link(scope, opts) when is_atom(scope) and is_list(opts) do
    Pg.start_link(scope, validate_pg_opts!(opts))
  end

  @doc """
  Returns a child specification for use in a supervision tree.

  Accepts a bare scope atom, a `{scope, opts}` tuple, or a Registry-shaped
  keyword list with `:name`.
  """
  @spec child_spec(scope() | {scope(), keyword()} | keyword()) :: Supervisor.child_spec()
  def child_spec({scope, opts}) when is_atom(scope) and is_list(opts) do
    %{id: {__MODULE__, scope}, start: {__MODULE__, :start_link, [scope, opts]}}
  end

  def child_spec(scope) when is_atom(scope) do
    %{id: {__MODULE__, scope}, start: {__MODULE__, :start_link, [scope]}}
  end

  def child_spec(opts) when is_list(opts) do
    {scope, _} = parse_keyword_opts(opts)
    %{id: {__MODULE__, scope}, start: {__MODULE__, :start_link, [opts]}}
  end

  # Splits Registry-shaped keyword opts into the scope name and the
  # subset of options that PgRegistry.Pg understands.
  defp parse_keyword_opts(opts) do
    scope = Keyword.fetch!(opts, :name)
    pg_opts = opts |> Keyword.delete(:name) |> validate_pg_opts!()
    {scope, pg_opts}
  end

  # Validates the option set passed to either form of start_link and
  # returns the subset that PgRegistry.Pg.start_link/2 understands.
  # All option-shape errors land here so the 2-arity and keyword
  # paths give the same diagnostics.
  @valid_pg_opts [:keys, :listeners, :partitions]
  defp validate_pg_opts!(opts) do
    validate_known_opts!(opts)
    validate_partitions!(opts)

    [
      keys: validate_keys!(opts),
      listeners: validate_listeners!(opts)
    ]
  end

  defp validate_known_opts!(opts) do
    case Keyword.keys(opts) -- @valid_pg_opts do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown PgRegistry option(s): #{inspect(unknown)}; " <>
                "valid options are #{inspect(@valid_pg_opts ++ [:name])}"
    end
  end

  defp validate_keys!(opts) do
    case Keyword.get(opts, :keys, :duplicate) do
      mode when mode in [:duplicate, :unique] ->
        mode

      other ->
        raise ArgumentError,
              "expected :keys to be :duplicate or :unique, got: #{inspect(other)}"
    end
  end

  defp validate_partitions!(opts) do
    case Keyword.get(opts, :partitions, 1) do
      1 ->
        :ok

      n when is_integer(n) and n > 1 ->
        raise ArgumentError, """
        PgRegistry does not support `partitions: #{n}`. PgRegistry uses
        a single ETS table per scope; partitioning would shard local
        writes across N GenServers but does not help with the
        gossip/convergence path that dominates cost in a cluster.

        If you hit local write contention on a single scope, the right
        fix is usually to split the scope into several scopes (one per
        logical workload), not to partition a single one.
        """

      other ->
        raise ArgumentError, "expected :partitions to be 1, got: #{inspect(other)}"
    end
  end

  defp validate_listeners!(opts) do
    listeners = Keyword.get(opts, :listeners, [])

    if is_list(listeners) and Enum.all?(listeners, &is_atom/1) do
      listeners
    else
      raise ArgumentError,
            "expected :listeners to be a list of atoms (registered process names), " <>
              "got: #{inspect(listeners)}"
    end
  end

  # ---------------------------------------------------------------------------
  # :via callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Registers `pid` under `{scope, key}` or `{scope, key, value}`.

  Returns `:yes` on success, or `:no` if the scope was started with
  `keys: :unique` and another local pid already holds this key.

  Implements the `:via` callback. When called via
  `GenServer.start_link(name: {:via, PgRegistry, ...})`, a `:no` reply
  causes `gen.erl` to follow up with `whereis_name/1` and surface
  `{:error, {:already_started, holder}}` automatically.

  When you call `register_name/2` directly (not through `:via`), the
  `:no` return does not carry the holder pid. Use `whereis_name/1` to
  recover it if you need to know who the existing holder is.
  """
  @spec register_name(via_name(), pid()) :: :yes | :no
  def register_name({scope, key}, pid), do: do_register_name(scope, key, pid, nil)
  def register_name({scope, key, value}, pid), do: do_register_name(scope, key, pid, value)

  defp do_register_name(scope, key, pid, value) do
    case Pg.join(scope, key, pid, value) do
      :ok -> :yes
      {:error, {:already_registered, _}} -> :no
    end
  end

  @doc """
  Unregisters all local processes under `{scope, key}`. Always returns `:ok`.
  """
  @spec unregister_name(via_name()) :: :ok
  def unregister_name({scope, key}), do: do_unregister(scope, key)
  def unregister_name({scope, key, _value}), do: do_unregister(scope, key)

  defp do_unregister(scope, key) do
    case Pg.get_local_members(scope, key) do
      [] ->
        :ok

      pids ->
        _ = Pg.leave(scope, key, pids)
        :ok
    end
  end

  @doc """
  Looks up a single pid registered under `{scope, key}`. Local pids are
  preferred. Returns `:undefined` if no process is registered.

  Accepts both the 2-tuple `{scope, key}` and the 3-tuple
  `{scope, key, value}` via name shapes. The `value` field is **only**
  used at registration time — it is ignored here, because lookup is by
  key. Asymmetric on purpose: a caller usually doesn't know the value
  to look up by it, and several pids may be registered under the same
  key with different values.
  """
  @spec whereis_name(via_name()) :: pid() | :undefined
  def whereis_name({scope, key}), do: do_whereis(scope, key)
  def whereis_name({scope, key, _value}), do: do_whereis(scope, key)

  defp do_whereis(scope, key) do
    case Pg.get_local_members(scope, key) do
      [pid | _] ->
        pid

      [] ->
        case Pg.get_members(scope, key) do
          [pid | _] -> pid
          [] -> :undefined
        end
    end
  end

  @doc """
  Sends `msg` to a process registered under `{scope, key}`. Returns the
  pid. Raises `ArgumentError` if no process is registered.
  """
  @spec send(via_name(), term()) :: pid()
  def send(name, msg) do
    case whereis_name(name) do
      :undefined ->
        raise ArgumentError, "no process registered under #{inspect(name)}"

      pid ->
        Kernel.send(pid, msg)
        pid
    end
  end

  # ---------------------------------------------------------------------------
  # Registry-shaped API
  # ---------------------------------------------------------------------------

  @doc """
  Returns all `{pid, value}` entries registered under `key` in `scope`.

  This is the metadata-aware view. Equivalent to Elixir's `Registry.lookup/2`
  but spans the cluster.
  """
  @spec lookup(scope(), key()) :: [{pid(), value()}]
  def lookup(scope, key), do: Pg.lookup(scope, key)

  @doc """
  Replaces the value attached to every entry under `key` in `scope`
  whose pid is `pid`. Returns `:not_joined` if `pid` has no entry there.

  > #### Different from `Registry.update_value/3` {: .warning}
  >
  > If `pid` has been joined to `key` multiple times (because of repeated
  > `register/3` or `register_name/2` calls), **all** of its entries are
  > collapsed to `new_value`. `Registry.update_value/3` doesn't have to
  > deal with this case because it's only available in `:unique` mode,
  > where there's at most one entry per pid per key.
  """
  @spec update_value(scope(), key(), pid(), value()) :: :ok | :not_joined
  def update_value(scope, key, pid, new_value) when is_pid(pid) do
    Pg.update_meta(scope, key, pid, new_value)
  end

  @doc """
  Sugar for `update_value/4` that updates the calling process's entry.
  Closer in shape to `Registry.update_value/3` but takes a literal value
  rather than a callback.
  """
  @spec update_value(scope(), key(), value()) :: :ok | :not_joined
  def update_value(scope, key, new_value) do
    update_value(scope, key, self(), new_value)
  end

  @doc """
  Returns the list of keys `pid` is registered under in `scope`.

  Walks every group in the scope, so cost is `O(number_of_keys)`. A pid
  joined to the same key multiple times appears only once in the result.
  """
  @spec keys(scope(), pid()) :: [key()]
  def keys(scope, pid) when is_pid(pid) do
    for key <- Pg.which_groups(scope),
        pid in Pg.get_members(scope, key),
        uniq: true,
        do: key
  end

  @doc """
  Returns the total number of `{pid, value}` entries in `scope`,
  counting duplicates. Same semantics as Elixir's `Registry.count/1`.

  Implemented as a single `:ets.info/2` call — O(1) regardless of
  scope size.
  """
  @spec count(scope()) :: non_neg_integer()
  def count(scope) do
    case :ets.info(scope, :size) do
      :undefined -> 0
      n -> n
    end
  end

  @doc """
  Returns all pids registered under `key` in `scope` (cluster-wide).
  Bare-pid view; use `lookup/2` for `{pid, value}` entries.
  """
  @spec get_members(scope(), key()) :: [pid()]
  defdelegate get_members(scope, key), to: Pg

  @doc """
  Returns all keys with at least one registered process in `scope`.
  """
  @spec which_groups(scope()) :: [key()]
  defdelegate which_groups(scope), to: Pg

  @doc """
  Subscribes the caller to all join/leave/update events in `scope`.

  Returns `{ref, snapshot}` where `snapshot` is `%{key => [{pid, value}]}`.
  Subsequent events arrive as `{ref, :join | :leave | :update, key, payload}`.
  See `PgRegistry.Pg.monitor_scope/1` for the payload shapes.
  """
  @spec monitor_scope(scope()) :: {reference(), %{key() => [{pid(), value()}]}}
  defdelegate monitor_scope(scope), to: Pg

  @doc "Subscribes the caller to events for a single `key`."
  @spec monitor(scope(), key()) :: {reference(), [{pid(), value()}]}
  defdelegate monitor(scope, key), to: Pg

  @doc "Cancels a subscription created with `monitor_scope/1` or `monitor/2`."
  @spec demonitor(scope(), reference()) :: :ok | false
  defdelegate demonitor(scope, ref), to: Pg

  @doc """
  Invokes `callback` with the list of pids registered under `key` in
  `scope`, if there are any.

  Currently no options are supported. The fourth argument exists for
  signature parity with `Registry.dispatch/4` but any non-empty option
  list raises `ArgumentError` rather than silently doing the wrong
  thing — in particular, `parallel: true` is not implemented; if you
  need parallelism, spawn tasks from inside the callback yourself.
  """
  @spec dispatch(scope(), key(), ([pid()] -> term()), keyword()) :: :ok
  def dispatch(scope, key, callback, opts \\ []) when is_function(callback, 1) and is_list(opts) do
    if opts != [] do
      raise ArgumentError,
            "PgRegistry.dispatch/4 does not currently support any options, " <>
              "got: #{inspect(opts)}. Dispatch is always sequential; if you " <>
              "need parallelism, spawn tasks from the callback yourself."
    end

    case Pg.get_members(scope, key) do
      [] ->
        :ok

      members ->
        callback.(members)
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Registry-shaped self() API
  # ---------------------------------------------------------------------------

  @doc """
  Registers the calling process under `key` in `scope` with `value`.

  Returns `{:ok, self()}` on success. In a scope started with
  `keys: :unique`, returns `{:error, {:already_registered, pid}}`
  if another local pid already holds the key.
  """
  @spec register(scope(), key(), value()) ::
          {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register(scope, key, value) do
    case Pg.join(scope, key, self(), value) do
      :ok -> {:ok, self()}
      {:error, {:already_registered, _}} = err -> err
    end
  end

  @doc """
  Unregisters the calling process from `key` in `scope`. Returns `:ok`
  whether or not the caller had a registration.
  """
  @spec unregister(scope(), key()) :: :ok
  def unregister(scope, key) do
    case Pg.leave(scope, key, self()) do
      :ok -> :ok
      :not_joined -> :ok
    end
  end

  @doc """
  Returns the values registered by `pid` under `key` in `scope`.
  Mirrors `Registry.values/3`.
  """
  @spec values(scope(), key(), pid()) :: [value()]
  def values(scope, key, pid) when is_pid(pid) do
    for {p, v} <- Pg.lookup(scope, key), p == pid, do: v
  end

  # ---------------------------------------------------------------------------
  # match / select family
  #
  # User-supplied patterns and match-specs operate on `{key, pid, value}`
  # triples just like Elixir's Registry. Internally our ETS rows are
  # 4-tuples `{key, pid, value, tag}` where `tag` is an opaque per-entry
  # identity used by the Pg layer. The trailing `:_` rewrites here are
  # what makes the user-facing shape work against the storage shape.
  # ---------------------------------------------------------------------------

  @doc """
  Returns `{pid, value}` entries under `key` in `scope` whose value
  matches `pattern`. Mirrors `Registry.match/3`.

  Only a single pattern + guard list is accepted. To run alternative
  patterns over the same key, call `match/3` multiple times or use
  `select/2` with a multi-clause match-spec.
  """
  @spec match(scope(), key(), term()) :: [{pid(), value()}]
  def match(scope, key, pattern), do: match(scope, key, pattern, [])

  @doc """
  Like `match/3` with extra `guards` against any `:"$N"` variables bound
  by `pattern`.
  """
  @spec match(scope(), key(), term(), list()) :: [{pid(), value()}]
  def match(scope, key, pattern, guards) do
    :ets.select(scope, build_match_spec(key, pattern, guards))
  end

  @doc "Counts entries under `key` in `scope` whose value matches `pattern`."
  @spec count_match(scope(), key(), term()) :: non_neg_integer()
  def count_match(scope, key, pattern), do: count_match(scope, key, pattern, [])

  @doc "Like `count_match/3` with guards."
  @spec count_match(scope(), key(), term(), list()) :: non_neg_integer()
  def count_match(scope, key, pattern, guards) do
    spec = [
      {{key, :_, pattern, :_}, guards, [true]}
    ]

    :ets.select_count(scope, spec)
  end

  @doc """
  Runs a Registry-style match-spec across the entire scope.

  The match-spec patterns and bodies are expressed against
  `{key, pid, value}` tuples, exactly like `Registry.select/2`.
  """
  @spec select(scope(), :ets.match_spec()) :: [term()]
  def select(scope, match_spec) when is_list(match_spec) do
    :ets.select(scope, rewrite_user_spec(match_spec))
  end

  @doc """
  Like `select/2` but returns the count of entries whose match-spec
  body returns `true`.

  The user's match-spec body is preserved (matching `Registry.count_select/2`),
  so a body of `[false]` correctly counts zero, and a body that branches
  on the value can be used as a filter.
  """
  @spec count_select(scope(), :ets.match_spec()) :: non_neg_integer()
  def count_select(scope, match_spec) when is_list(match_spec) do
    :ets.select_count(scope, rewrite_user_spec(match_spec))
  end

  @doc """
  Unregisters the calling process's entries under `key` in `scope`
  whose value matches `pattern`.
  """
  @spec unregister_match(scope(), key(), term()) :: :ok
  def unregister_match(scope, key, pattern), do: unregister_match(scope, key, pattern, [])

  @doc "Like `unregister_match/3` with guards."
  @spec unregister_match(scope(), key(), term(), list()) :: :ok
  def unregister_match(scope, key, pattern, guards) do
    _ = Pg.unregister_match(scope, key, self(), pattern, guards)
    :ok
  end

  # Internal: build a match-spec for the storage layout from a
  # value-shaped pattern + guards.
  defp build_match_spec(key, pattern, guards) do
    [
      {
        {key, :_, pattern, :_},
        guards,
        [{{{:element, 2, :"$_"}, {:element, 3, :"$_"}}}]
      }
    ]
  end

  # Internal: rewrite a user-supplied match-spec from {key, pid, value}
  # shape to our 4-tuple {key, pid, value, tag} storage shape by
  # appending `:_` to each match pattern.
  defp rewrite_user_spec(spec) do
    Enum.map(spec, fn {match, guards, body} ->
      {:erlang.append_element(match, :_), guards, body}
    end)
  end

  # ---------------------------------------------------------------------------
  # Scope-level metadata (Registry.meta / put_meta / delete_meta equivalents)
  # ---------------------------------------------------------------------------

  @doc """
  Returns `{:ok, value}` if `key` is set in `scope`'s metadata, else
  `:error`. Local-only — metadata is not gossiped between nodes.
  """
  @spec meta(scope(), term()) :: {:ok, term()} | :error
  defdelegate meta(scope, key), to: Pg, as: :get_scope_meta

  @doc "Sets `key` to `value` in `scope`'s local metadata."
  @spec put_meta(scope(), term(), term()) :: :ok
  defdelegate put_meta(scope, key, value), to: Pg, as: :put_scope_meta

  @doc "Removes `key` from `scope`'s local metadata."
  @spec delete_meta(scope(), term()) :: :ok
  defdelegate delete_meta(scope, key), to: Pg, as: :delete_scope_meta
end
