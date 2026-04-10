defmodule PgRegistry do
  @moduledoc """
  A distributed, cluster-aware process registry with per-entry metadata.

  `PgRegistry` provides a `Registry`-shaped API on top of `PgRegistry.Pg`,
  an Elixir port of Erlang's `:pg` extended with per-entry metadata.
  Processes registered in a scope are discovered across the cluster through
  gossip-based eventually consistent membership.

  ## Example

      # In a supervision tree
      children = [
        {PgRegistry, :my_registry}
      ]

      # Register a process via a :via tuple
      GenServer.start_link(MyServer, arg,
        name: {:via, PgRegistry, {:my_registry, :my_key}})

      # Register with metadata attached
      GenServer.start_link(MyServer, arg,
        name: {:via, PgRegistry, {:my_registry, :my_key, %{role: :primary}}})

      # Look up entries across the cluster
      PgRegistry.lookup(:my_registry, :my_key)
      #=> [{#PID<0.123.0>, %{role: :primary}}]
  """

  alias PgRegistry.Pg

  @type scope :: atom()
  @type key :: term()
  @type value :: term()
  @type via_name :: {scope(), key()} | {scope(), key(), value()}

  @doc """
  Starts a `PgRegistry` scope linked to the calling process.

  Three forms are accepted:

      PgRegistry.start_link(:my_reg)
      PgRegistry.start_link(:my_reg, listeners: [MyL])
      PgRegistry.start_link(name: :my_reg, listeners: [MyL], keys: :duplicate)

  The keyword form accepts the same option names as `Registry.start_link/1`.
  See `PgRegistry.Pg.start_link/2` for supported options. The `:partitions`
  option is accepted for compatibility; values other than `1` raise
  `ArgumentError`.
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

  Accepts a bare scope atom, a `{scope, opts}` tuple, or a keyword list
  with a `:name` key.
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
  #
  # Write side (register_name/2, unregister_name/1) works in both modes.
  # Read side (whereis_name/1, send/2) requires keys: :unique and
  # resolves locally only. See @doc on each function for details.
  # ---------------------------------------------------------------------------

  @via_resolve_unique """
  The :via read callbacks (whereis_name/1, send/2, and by extension
  GenServer.call, GenServer.cast, and Process.whereis on a via tuple)
  require a scope started with `keys: :unique`. The :via protocol
  expects an unambiguous name-to-pid mapping, which a `:duplicate`-keyed
  scope cannot provide.

  In `:duplicate` mode, use `lookup/2`, `match/3`, or `dispatch/3` to
  enumerate members.
  """

  @doc """
  Registers `pid` under `{scope, key}` or `{scope, key, value}`.

  This is the write side of the `:via` protocol and works in both
  `:duplicate` and `:unique` scopes.

    * In `:duplicate` mode, always returns `:yes`. Multiple pids may
      be registered under the same key, including the same pid
      multiple times with different values.

    * In `:unique` mode, returns `:yes` on success or `:no` if
      another local pid already holds the key.

  When invoked through `GenServer.start_link(name: {:via, PgRegistry, ...})`,
  a `:no` return causes the GenServer to surface
  `{:error, {:already_started, holder}}`.

  > #### `:via` tuples in `:duplicate` mode {: .info}
  >
  > As with `Registry`, `:via` tuple registration succeeds in
  > `:duplicate` mode, but name resolution (`whereis_name/1`, `send/2`,
  > and by extension `GenServer.call/3`) raises `ArgumentError` because
  > a duplicate-keyed scope may have many pids under one key. Use
  > `lookup/2` or `dispatch/3` to address members instead.

  ## Examples

      iex> {:ok, _} = PgRegistry.start_link(name: :doc_register_name, keys: :unique)
      iex> PgRegistry.register_name({:doc_register_name, :singleton}, self())
      :yes
      iex> PgRegistry.register_name({:doc_register_name, :singleton}, self())
      :no
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
  Unregisters local processes registered under `{scope, key}`.

  Works in both `:duplicate` and `:unique` modes.

    * In `:duplicate` mode, removes every local pid registered under
      `key`. Remote pids are not affected.

    * In `:unique` mode, removes the single local holder, if any.

  Always returns `:ok`.
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
  Returns the pid registered under `{scope, key}` on the local node,
  or `:undefined` if no local pid holds the key.

  Requires a scope started with `keys: :unique`. Raises `ArgumentError`
  for `:duplicate`-keyed scopes; use `lookup/2` or `dispatch/3` instead.

  ## Local-only resolution

  Because `keys: :unique` enforces per-node uniqueness, each node has
  at most one holder per key. This function resolves only on the local
  node. If the local node has no holder, `:undefined` is returned even
  if another node in the cluster holds the same key.

  As a consequence, `GenServer.call({:via, PgRegistry, {scope, key}}, msg)`
  from two different nodes may reach two different processes (one per
  node), and a node with no local holder will fail the call.

  Both `{scope, key}` and `{scope, key, value}` name shapes are accepted.
  The `value` element is used only at registration time and is ignored
  during lookup.

  ## Examples

      iex> {:ok, _} = PgRegistry.start_link(name: :doc_whereis, keys: :unique)
      iex> PgRegistry.whereis_name({:doc_whereis, :singleton})
      :undefined
      iex> PgRegistry.register_name({:doc_whereis, :singleton}, self())
      :yes
      iex> PgRegistry.whereis_name({:doc_whereis, :singleton}) == self()
      true
  """
  @spec whereis_name(via_name()) :: pid() | :undefined
  def whereis_name({scope, key}) do
    ensure_unique!(scope)
    do_whereis(scope, key)
  end

  def whereis_name({scope, key, _value}) do
    ensure_unique!(scope)
    do_whereis(scope, key)
  end

  defp do_whereis(scope, key) do
    case Pg.get_local_members(scope, key) do
      [pid | _] -> pid
      [] -> :undefined
    end
  end

  @doc """
  Sends `msg` to the local process registered under `{scope, key}`
  and returns the pid.

  Raises `ArgumentError` if no local process is registered or if the
  scope uses `:duplicate` keys. See `whereis_name/1` for details on
  local-only resolution.
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

  defp ensure_unique!(scope) do
    case Pg.keys_mode(scope) do
      :unique -> :ok
      :duplicate -> raise ArgumentError, @via_resolve_unique
    end
  end

  # ---------------------------------------------------------------------------
  # Registry-shaped API
  # ---------------------------------------------------------------------------

  @doc """
  Returns all `{pid, value}` entries registered under `key` in `scope`,
  across the entire cluster.

  ## Examples

      iex> {:ok, _} = PgRegistry.start_link(:doc_lookup)
      iex> {:ok, _} = PgRegistry.register(:doc_lookup, :worker, %{role: :primary})
      iex> [{pid, %{role: :primary}}] = PgRegistry.lookup(:doc_lookup, :worker)
      iex> pid == self()
      true

      iex> {:ok, _} = PgRegistry.start_link(:doc_lookup_empty)
      iex> PgRegistry.lookup(:doc_lookup_empty, :nobody)
      []
  """
  @spec lookup(scope(), key()) :: [{pid(), value()}]
  def lookup(scope, key), do: Pg.lookup(scope, key)

  @doc """
  Replaces the value attached to every entry under `key` in `scope`
  whose pid is `pid`. Returns `:not_joined` if `pid` has no entry.

  > #### Difference from `Registry.update_value/3` {: .warning}
  >
  > If `pid` has been joined to `key` multiple times (through repeated
  > `register/3` or `register_name/2` calls), **all** of its entries are
  > set to `new_value`. `Registry.update_value/3` does not encounter this
  > case because it is only available in `:unique` mode, where at most
  > one entry exists per pid per key.
  """
  @spec update_value(scope(), key(), pid(), value()) :: :ok | :not_joined
  def update_value(scope, key, pid, new_value) when is_pid(pid) do
    Pg.update_meta(scope, key, pid, new_value)
  end

  @doc """
  Calls `update_value/4` with `self()` as the pid.

  Similar to `Registry.update_value/3` but accepts a literal value
  rather than a callback.

  ## Examples

      iex> {:ok, _} = PgRegistry.start_link(:doc_update_value)
      iex> PgRegistry.register(:doc_update_value, :worker, :v1)
      iex> PgRegistry.update_value(:doc_update_value, :worker, :v2)
      :ok
      iex> [{_pid, :v2}] = PgRegistry.lookup(:doc_update_value, :worker)
      iex> PgRegistry.update_value(:doc_update_value, :nobody, :v)
      :not_joined
  """
  @spec update_value(scope(), key(), value()) :: :ok | :not_joined
  def update_value(scope, key, new_value) do
    update_value(scope, key, self(), new_value)
  end

  @doc """
  Returns the list of keys `pid` is registered under in `scope`.

  Iterates all groups in the scope; cost is proportional to the number
  of distinct keys. A pid joined to the same key multiple times appears
  only once in the result.

  ## Examples

      iex> {:ok, _} = PgRegistry.start_link(:doc_keys)
      iex> PgRegistry.register(:doc_keys, :a, :v)
      iex> PgRegistry.register(:doc_keys, :b, :v)
      iex> PgRegistry.keys(:doc_keys, self()) |> Enum.sort()
      [:a, :b]
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
  including duplicates.

  Reads `:ets.info(scope, :size)` directly, so the cost is constant
  regardless of scope size.

  ## Examples

      iex> {:ok, _} = PgRegistry.start_link(:doc_count)
      iex> PgRegistry.count(:doc_count)
      0
      iex> PgRegistry.register(:doc_count, :a, 1)
      iex> PgRegistry.register(:doc_count, :b, 2)
      iex> PgRegistry.count(:doc_count)
      2
  """
  @spec count(scope()) :: non_neg_integer()
  def count(scope) do
    case :ets.info(scope, :size) do
      :undefined -> 0
      n -> n
    end
  end

  @doc """
  Returns only the `{pid, value}` entries under `key` whose pid is
  on the local node.

  This function has no equivalent in `Registry`. It is useful in
  distributed contexts such as draining a node before shutdown,
  collecting per-node metrics, or preferring a local process before
  falling back to a remote one. For the cluster-wide view, see
  `lookup/2`.
  """
  @spec lookup_local(scope(), key()) :: [{pid(), value()}]
  defdelegate lookup_local(scope, key), to: Pg

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
  `scope`. If no processes are registered under `key`, the callback is
  not invoked.

  The fourth argument exists for signature compatibility with
  `Registry.dispatch/4`. No options are currently supported; passing a
  non-empty list raises `ArgumentError`.
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

  ## Examples

      iex> {:ok, _} = PgRegistry.start_link(:doc_register)
      iex> {:ok, pid} = PgRegistry.register(:doc_register, :worker, %{role: :primary})
      iex> pid == self()
      true
      iex> [{_pid, %{role: :primary}}] = PgRegistry.lookup(:doc_register, :worker)
      iex> :ok

  In `:unique` mode, a second `register/3` on the same key returns
  an error tuple with the current holder:

      iex> {:ok, _} = PgRegistry.start_link(name: :doc_register_unique, keys: :unique)
      iex> {:ok, _} = PgRegistry.register(:doc_register_unique, :singleton, :v)
      iex> {:error, {:already_registered, holder}} =
      ...>   PgRegistry.register(:doc_register_unique, :singleton, :v)
      iex> holder == self()
      true
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

  ## Examples

      iex> {:ok, _} = PgRegistry.start_link(:doc_unregister)
      iex> PgRegistry.register(:doc_unregister, :worker, :v)
      iex> PgRegistry.unregister(:doc_unregister, :worker)
      :ok
      iex> PgRegistry.lookup(:doc_unregister, :worker)
      []
      iex> PgRegistry.unregister(:doc_unregister, :nobody)
      :ok
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

  ## Examples

      iex> {:ok, _} = PgRegistry.start_link(:doc_values)
      iex> PgRegistry.register(:doc_values, :worker, :v1)
      iex> PgRegistry.values(:doc_values, :worker, self())
      [:v1]
      iex> PgRegistry.values(:doc_values, :worker, spawn(fn -> :ok end))
      []
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
  matches `pattern`.

  Only a single pattern + guard list is accepted. To run alternative
  patterns over the same key, call `match/3` multiple times or use
  `select/2` with a multi-clause match-spec.

  ## Examples

      iex> {:ok, _} = PgRegistry.start_link(:doc_match)
      iex> PgRegistry.register(:doc_match, :worker, %{role: :primary})
      iex> PgRegistry.register(:doc_match, :worker, %{role: :replica})
      iex> matches = PgRegistry.match(:doc_match, :worker, %{role: :primary})
      iex> Enum.map(matches, fn {_pid, v} -> v end)
      [%{role: :primary}]
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
  Runs a match-spec across the entire scope.

  Match-spec patterns are expressed against `{key, pid, value}` tuples,
  the same shape used by `Registry.select/2`.
  """
  @spec select(scope(), :ets.match_spec()) :: [term()]
  def select(scope, match_spec) when is_list(match_spec) do
    :ets.select(scope, rewrite_user_spec(match_spec))
  end

  @doc """
  Like `select/2` but returns the count of matching entries.

  The match-spec body is preserved, so a body of `[false]` correctly
  counts zero and a body that branches on the value can be used as a
  filter.
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
  Returns `{:ok, value}` if `key` is set in the scope's metadata, or
  `:error` otherwise.

  Scope metadata is local to the node and is not gossiped between
  nodes. Keys must be atoms or tuples.

  ## Examples

      iex> {:ok, _} = PgRegistry.start_link(:doc_meta)
      iex> PgRegistry.meta(:doc_meta, :config)
      :error
      iex> PgRegistry.put_meta(:doc_meta, :config, %{retries: 3})
      :ok
      iex> PgRegistry.meta(:doc_meta, :config)
      {:ok, %{retries: 3}}
      iex> PgRegistry.put_meta(:doc_meta, {:ns, :limit}, 100)
      :ok
      iex> PgRegistry.meta(:doc_meta, {:ns, :limit})
      {:ok, 100}
      iex> PgRegistry.delete_meta(:doc_meta, :config)
      :ok
      iex> PgRegistry.meta(:doc_meta, :config)
      :error
  """
  @spec meta(scope(), Pg.meta_key()) :: {:ok, term()} | :error
  defdelegate meta(scope, key), to: Pg, as: :get_scope_meta

  @doc """
  Sets `key` to `value` in `scope`'s local metadata. Keys must be
  atoms or tuples.
  """
  @spec put_meta(scope(), Pg.meta_key(), term()) :: :ok
  defdelegate put_meta(scope, key, value), to: Pg, as: :put_scope_meta

  @doc """
  Removes `key` from `scope`'s local metadata. Keys must be atoms or
  tuples.
  """
  @spec delete_meta(scope(), Pg.meta_key()) :: :ok
  defdelegate delete_meta(scope, key), to: Pg, as: :delete_scope_meta
end
