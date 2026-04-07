defmodule PgRegistry.Pg do
  @moduledoc """
  An Elixir port of Erlang's `:pg` module, extended with per-member
  metadata.

  Distributed named process groups with eventually consistent membership.

  Each scope is its own GenServer registered locally under the scope
  name, and owns an ETS `:duplicate_bag` of the same name. Each entry
  is a single row of shape:

      {key, pid, meta, tag}

  where `tag` is an opaque per-node monotonic integer that gives every
  entry its own identity even when `(key, pid, meta)` would otherwise
  collide. The tag is internal: callers never see it. It exists so
  that `:pg`'s ref-counted multi-join semantics survive a flat-row
  layout, and so that cross-node leaves can name a specific entry
  unambiguously.

  Lookups (`get_members/2`, `lookup/2`, etc.) read the ETS table
  directly from the caller, so they are still O(rows-for-this-key)
  and never block. All mutations go through the GenServer.
  """

  use GenServer

  @type scope :: atom()
  @type group :: term()
  @type meta :: term()
  @type entry :: {pid(), meta()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(scope()) :: GenServer.on_start()
  def start_link(scope) when is_atom(scope) do
    GenServer.start_link(__MODULE__, scope, name: scope)
  end

  @doc "Starts a scope outside of any supervision/link tree."
  @spec start(scope()) :: GenServer.on_start()
  def start(scope) when is_atom(scope) do
    GenServer.start(__MODULE__, scope, name: scope)
  end

  @spec child_spec(scope()) :: Supervisor.child_spec()
  def child_spec(scope) do
    %{id: {__MODULE__, scope}, start: {__MODULE__, :start_link, [scope]}}
  end

  @spec join(scope(), group(), pid() | [pid()]) :: :ok
  def join(scope, group, pid_or_pids) when is_pid(pid_or_pids) or is_list(pid_or_pids) do
    join(scope, group, pid_or_pids, nil)
  end

  @doc """
  Joins one or more local processes to `group` with `meta` attached.

  When a list of pids is given, the same `meta` is stored for each.
  A pid may be joined to the same group multiple times with different
  metas; each entry is independent and must be left separately.
  """
  @spec join(scope(), group(), pid() | [pid()], meta()) :: :ok
  def join(scope, group, pid_or_pids, meta) when is_pid(pid_or_pids) or is_list(pid_or_pids) do
    :ok = ensure_local(pid_or_pids)
    GenServer.call(scope, {:join_local, group, pid_or_pids, meta}, :infinity)
  end

  @spec leave(scope(), group(), pid() | [pid()]) :: :ok | :not_joined
  def leave(scope, group, pid_or_pids) when is_pid(pid_or_pids) or is_list(pid_or_pids) do
    :ok = ensure_local(pid_or_pids)
    GenServer.call(scope, {:leave_local, group, pid_or_pids}, :infinity)
  end

  @doc """
  Replaces the metadata of every entry in `group` whose pid is `pid`,
  setting it to `new_meta`. Returns `:not_joined` when `pid` is not in
  the group.

  Subscribers receive `{ref, :update, group, [{pid, old_meta, new_meta}, ...]}`.
  """
  @spec update_meta(scope(), group(), pid(), meta()) :: :ok | :not_joined
  def update_meta(scope, group, pid, new_meta) when is_pid(pid) do
    :ok = ensure_local(pid)
    GenServer.call(scope, {:update_meta, group, pid, new_meta}, :infinity)
  end

  @spec get_members(scope(), group()) :: [pid()]
  def get_members(scope, group) do
    for {_g, pid, _meta, _tag} <- :ets.lookup(scope, group), do: pid
  end

  @spec get_local_members(scope(), group()) :: [pid()]
  def get_local_members(scope, group) do
    for {_g, pid, _meta, _tag} <- :ets.lookup(scope, group),
        node(pid) == node(),
        do: pid
  end

  @doc """
  Returns all `{pid, meta}` entries registered under `group`, across the
  whole cluster.
  """
  @spec lookup(scope(), group()) :: [entry()]
  def lookup(scope, group) do
    for {_g, pid, meta, _tag} <- :ets.lookup(scope, group), do: {pid, meta}
  end

  @doc """
  Returns the `{pid, meta}` entries for `group` whose pid lives on the
  local node.
  """
  @spec lookup_local(scope(), group()) :: [entry()]
  def lookup_local(scope, group) do
    for {_g, pid, meta, _tag} <- :ets.lookup(scope, group),
        node(pid) == node(),
        do: {pid, meta}
  end

  @spec which_groups(scope()) :: [group()]
  def which_groups(scope) when is_atom(scope) do
    fn {g, _pid, _meta, _tag}, acc -> MapSet.put(acc, g) end
    |> :ets.foldl(
      MapSet.new(),
      scope
    )
    |> MapSet.to_list()
  end

  @doc """
  Subscribes to all group changes in `scope`.

  Returns `{ref, snapshot}` where `snapshot` is `%{group => [{pid, meta}]}`.
  Subsequent join/leave/update events are delivered as
  `{ref, :join | :leave, group, [{pid, meta}, ...]}` and
  `{ref, :update, group, [{pid, old_meta, new_meta}, ...]}`.
  """
  @spec monitor_scope(scope()) :: {reference(), %{group() => [entry()]}}
  def monitor_scope(scope), do: GenServer.call(scope, :monitor, :infinity)

  @doc "Subscribes to changes in a single `group`."
  @spec monitor(scope(), group()) :: {reference(), [entry()]}
  def monitor(scope, group), do: GenServer.call(scope, {:monitor, group}, :infinity)

  @spec demonitor(scope(), reference()) :: :ok | false
  def demonitor(scope, ref) when is_reference(ref) do
    case GenServer.call(scope, {:demonitor, ref}, :infinity) do
      :ok ->
        flush(ref)
        :ok

      false ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Scope-level metadata (Registry.meta / put_meta / delete_meta equivalents)
  #
  # Local-only. Stored in a sibling ETS table named `:"#{scope}_meta"` so
  # reads can bypass the GenServer the same way the entries table can.
  # ---------------------------------------------------------------------------

  @doc "Returns `{:ok, value}` if `key` is set in `scope`'s metadata, else `:error`."
  @spec get_scope_meta(scope(), term()) :: {:ok, term()} | :error
  def get_scope_meta(scope, key) do
    case :ets.lookup(meta_table(scope), key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @doc "Sets `key` to `value` in `scope`'s metadata."
  @spec put_scope_meta(scope(), term(), term()) :: :ok
  def put_scope_meta(scope, key, value) do
    GenServer.call(scope, {:put_scope_meta, key, value}, :infinity)
  end

  @doc "Removes `key` from `scope`'s metadata."
  @spec delete_scope_meta(scope(), term()) :: :ok
  def delete_scope_meta(scope, key) do
    GenServer.call(scope, {:delete_scope_meta, key}, :infinity)
  end

  defp meta_table(scope), do: :"#{scope}_meta"

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  defmodule State do
    @moduledoc false
    defstruct scope: nil,
              # %{pid => {monitor_ref, [{group, tag}]}} — locally joined processes.
              # The list is ordered with most-recent join at the head, so
              # popping the head preserves :pg's LIFO leave semantics.
              local: %{},
              # %{peer_pid => {monitor_ref, %{group => [{pid, meta, tag}]}}}
              remote: %{},
              # %{ref => subscriber_pid} — whole-scope subscribers
              scope_monitors: %{},
              # %{ref => {pid, group}} — single-group subscribers (forward map)
              group_monitors: %{},
              # %{group => [{pid, ref}, ...]} — single-group subscribers (reverse)
              monitored_groups: %{}
  end

  @impl true
  def init(scope) do
    :ok = :net_kernel.monitor_nodes(true)

    for node <- Node.list() do
      send({scope, node}, {:discover, self()})
    end

    ^scope =
      :ets.new(scope, [:duplicate_bag, :protected, :named_table, {:read_concurrency, true}])

    meta = meta_table(scope)
    ^meta = :ets.new(meta, [:set, :protected, :named_table, {:read_concurrency, true}])

    {:ok, %State{scope: scope}}
  end

  @impl true
  def handle_call({:join_local, group, pid_or_pids, meta}, _from, %State{} = s) do
    pids = List.wrap(pid_or_pids)
    raw_entries = for pid <- pids, do: {pid, meta, fresh_tag()}

    new_local = Enum.reduce(raw_entries, s.local, &local_add(&1, group, &2))

    for {pid, m, tag} <- raw_entries do
      :ets.insert(s.scope, {group, pid, m, tag})
    end

    pub = strip_tags(raw_entries)
    notify_group(s.scope_monitors, s.monitored_groups, :join, group, pub)
    broadcast(Map.keys(s.remote), {:join, self(), group, raw_entries})

    {:reply, :ok, %{s | local: new_local}}
  end

  def handle_call({:leave_local, group, pid_or_pids}, _from, %State{} = s) do
    pids = List.wrap(pid_or_pids)
    {removed, new_local} = pop_local_entries(pids, group, s.local)

    if removed == [] do
      {:reply, :not_joined, s}
    else
      pub = remove_rows_for_group(s.scope, group, removed)

      if pub != [] do
        notify_group(s.scope_monitors, s.monitored_groups, :leave, group, pub)
      end

      broadcast_leaves(s.remote, group, removed)
      {:reply, :ok, %{s | local: new_local}}
    end
  end

  def handle_call({:update_meta, group, pid, new_meta}, _from, %State{} = s) do
    case rewrite_meta(s.scope, group, pid, new_meta) do
      [] ->
        {:reply, :not_joined, s}

      updates ->
        notify_group(s.scope_monitors, s.monitored_groups, :update, group, updates)
        broadcast(Map.keys(s.remote), {:update_meta, self(), group, pid, new_meta})
        {:reply, :ok, s}
    end
  end

  def handle_call(:monitor, {pid, _tag}, %State{} = s) do
    contents =
      :ets.foldl(
        fn {g, p, m, _tag}, acc -> Map.update(acc, g, [{p, m}], &[{p, m} | &1]) end,
        %{},
        s.scope
      )

    ref = Process.monitor(pid, tag: {:DOWN, :scope_monitors})
    {:reply, {ref, contents}, %{s | scope_monitors: Map.put(s.scope_monitors, ref, pid)}}
  end

  def handle_call({:monitor, group}, {pid, _tag}, %State{} = s) do
    members = lookup(s.scope, group)
    ref = Process.monitor(pid, tag: {:DOWN, :group_monitors})

    new_mg =
      Map.update(s.monitored_groups, group, [{pid, ref}], fn ex -> [{pid, ref} | ex] end)

    {:reply, {ref, members},
     %{s | group_monitors: Map.put(s.group_monitors, ref, {pid, group}), monitored_groups: new_mg}}
  end

  def handle_call({:put_scope_meta, key, value}, _from, %State{scope: scope} = s) do
    :ets.insert(meta_table(scope), {key, value})
    {:reply, :ok, s}
  end

  def handle_call({:delete_scope_meta, key}, _from, %State{scope: scope} = s) do
    :ets.delete(meta_table(scope), key)
    {:reply, :ok, s}
  end

  def handle_call({:demonitor, ref}, _from, %State{} = s) do
    case Map.pop(s.scope_monitors, ref) do
      {nil, _} ->
        case Map.pop(s.group_monitors, ref) do
          {nil, _} ->
            {:reply, false, s}

          {{pid, group}, new_gm} ->
            Process.demonitor(ref, [:flush])

            {:reply, :ok,
             %{
               s
               | group_monitors: new_gm,
                 monitored_groups: demonitor_group({pid, ref}, group, s.monitored_groups)
             }}
        end

      {_pid, new_mons} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{s | scope_monitors: new_mons}}
    end
  end

  @impl true
  def handle_info({:join, peer, group, raw_entries}, %State{} = s) do
    case Map.get(s.remote, peer) do
      {mref, remote_groups} ->
        for {pid, m, tag} <- raw_entries do
          :ets.insert(s.scope, {group, pid, m, tag})
        end

        pub = strip_tags(raw_entries)
        notify_group(s.scope_monitors, s.monitored_groups, :join, group, pub)

        new_remote_groups =
          Map.update(remote_groups, group, raw_entries, &(raw_entries ++ &1))

        {:noreply, %{s | remote: Map.put(s.remote, peer, {mref, new_remote_groups})}}

      nil ->
        {:noreply, s}
    end
  end

  def handle_info({:leave, peer, leave_triples}, %State{} = s) do
    case Map.get(s.remote, peer) do
      {mref, remote_groups} ->
        leaves_by_group = remove_rows_for_triples(s.scope, leave_triples)

        for {g, pub} <- leaves_by_group do
          notify_group(s.scope_monitors, s.monitored_groups, :leave, g, pub)
        end

        new_remote_groups = remove_remote_triples(remote_groups, leave_triples)
        {:noreply, %{s | remote: Map.put(s.remote, peer, {mref, new_remote_groups})}}

      nil ->
        {:noreply, s}
    end
  end

  def handle_info({:update_meta, peer, group, pid, new_meta}, %State{} = s) do
    case Map.fetch(s.remote, peer) do
      {:ok, {mref, remote_groups}} ->
        case rewrite_meta(s.scope, group, pid, new_meta) do
          [] ->
            {:noreply, s}

          updates ->
            notify_group(s.scope_monitors, s.monitored_groups, :update, group, updates)
            new_remote_groups = update_remote_meta(remote_groups, group, pid, new_meta)
            {:noreply, %{s | remote: Map.put(s.remote, peer, {mref, new_remote_groups})}}
        end

      :error ->
        {:noreply, s}
    end
  end

  def handle_info({:discover, peer}, %State{} = s), do: handle_discover(peer, s)
  def handle_info({:discover, peer, _proto_version}, %State{} = s), do: handle_discover(peer, s)

  # Local process exit
  def handle_info({:DOWN, mref, :process, pid, _info}, %State{} = s) when node(pid) == node() do
    case Map.pop(s.local, pid) do
      {nil, _} ->
        {:noreply, s}

      {{^mref, entries}, new_local} ->
        triples = down_local_pid(s.scope, pid, entries)
        notify_local_down(s.scope_monitors, s.monitored_groups, triples)
        broadcast(Map.keys(s.remote), {:leave, self(), Enum.map(triples, fn {g, p, _m, t} -> {g, p, t} end)})
        {:noreply, %{s | local: new_local}}
    end
  end

  # Remote scope process down
  def handle_info({:DOWN, mref, :process, pid, _info}, %State{} = s) do
    case Map.pop(s.remote, pid) do
      {{^mref, remote_map}, new_remote} ->
        for {group, entries} <- remote_map, {p, _m, tag} <- entries do
          :ets.match_delete(s.scope, {group, p, :_, tag})
        end

        for {group, entries} <- remote_map do
          notify_group(s.scope_monitors, s.monitored_groups, :leave, group, strip_tags(entries))
        end

        {:noreply, %{s | remote: new_remote}}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({{:DOWN, :scope_monitors}, mref, :process, _pid, _info}, %State{} = s) do
    {:noreply, %{s | scope_monitors: Map.delete(s.scope_monitors, mref)}}
  end

  def handle_info({{:DOWN, :group_monitors}, mref, :process, _pid, _info}, %State{} = s) do
    case Map.pop(s.group_monitors, mref) do
      {nil, _} ->
        {:noreply, s}

      {{pid, group}, new_gm} ->
        {:noreply,
         %{
           s
           | group_monitors: new_gm,
             monitored_groups: demonitor_group({pid, mref}, group, s.monitored_groups)
         }}
    end
  end

  def handle_info({:nodedown, _node}, s), do: {:noreply, s}
  def handle_info({:nodeup, node}, %State{} = s) when node == node(), do: {:noreply, s}

  def handle_info({:nodeup, node}, %State{scope: scope} = s) do
    send({scope, node}, {:discover, self()})
    {:noreply, s}
  end

  @impl true
  def handle_cast({:sync, peer, groups}, %State{} = s) do
    new_remote = handle_sync(s.scope, peer, s.remote, groups)
    {:noreply, %{s | remote: new_remote}}
  end

  @impl true
  def terminate(_reason, %State{scope: scope}) do
    if :ets.info(scope) != :undefined, do: :ets.delete(scope)

    meta = meta_table(scope)
    if :ets.info(meta) != :undefined, do: :ets.delete(meta)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp handle_discover(peer, %State{remote: remote, scope: scope} = s) do
    GenServer.cast(peer, {:sync, self(), all_local_entries(scope)})

    if Map.has_key?(remote, peer) do
      {:noreply, s}
    else
      mref = Process.monitor(peer)
      send(peer, {:discover, self()})
      {:noreply, %{s | remote: Map.put(remote, peer, {mref, %{}})}}
    end
  end

  defp ensure_local(pid) when is_pid(pid) do
    if node(pid) == node(), do: :ok, else: :erlang.error({:nolocal, pid})
  end

  defp ensure_local(pids) when is_list(pids) do
    Enum.each(pids, fn
      p when is_pid(p) and node(p) == node() -> :ok
      bad -> :erlang.error({:nolocal, bad})
    end)
  end

  defp ensure_local(bad), do: :erlang.error({:nolocal, bad})

  defp fresh_tag, do: :erlang.unique_integer([:monotonic])

  defp strip_tags(raw_entries), do: for({pid, meta, _tag} <- raw_entries, do: {pid, meta})

  # --- state.local helpers ---

  defp local_add({pid, _meta, tag}, group, local) do
    case Map.fetch(local, pid) do
      {:ok, {mref, list}} ->
        Map.put(local, pid, {mref, [{group, tag} | list]})

      :error ->
        mref = Process.monitor(pid)
        Map.put(local, pid, {mref, [{group, tag}]})
    end
  end

  # Pops the most-recent {group, tag} entry for each pid in `pids`.
  # Returns {[{pid, tag}, ...] in input order, new_local}. Pids without
  # a matching entry are silently skipped.
  defp pop_local_entries(pids, group, local) do
    {removed_rev, acc} =
      Enum.reduce(pids, {[], local}, fn pid, {removed, acc} ->
        case pop_local_one(pid, group, acc) do
          {nil, _} -> {removed, acc}
          {tag, new_acc} -> {[{pid, tag} | removed], new_acc}
        end
      end)

    {Enum.reverse(removed_rev), acc}
  end

  defp pop_local_one(pid, group, local) do
    case Map.get(local, pid) do
      nil ->
        {nil, local}

      {mref, list} ->
        case pop_first_group(list, group) do
          {nil, _} ->
            {nil, local}

          {tag, []} ->
            Process.demonitor(mref, [:flush])
            {tag, Map.delete(local, pid)}

          {tag, rest} ->
            {tag, Map.put(local, pid, {mref, rest})}
        end
    end
  end

  defp pop_first_group([], _group), do: {nil, []}
  defp pop_first_group([{g, tag} | tail], g), do: {tag, tail}

  defp pop_first_group([head | tail], group) do
    {tag, rest} = pop_first_group(tail, group)
    {tag, [head | rest]}
  end

  # --- ETS row mutation ---

  # For each {pid, tag} in `removed`, find the matching ETS row, capture
  # its meta for the notification, and delete it. Returns the public
  # `[{pid, meta}]` payload for notify_group.
  defp remove_rows_for_group(scope, group, removed) do
    for {pid, tag} <- removed,
        [{^group, ^pid, meta, ^tag}] <-
          [:ets.match_object(scope, {group, pid, :_, tag})] do
      :ets.match_delete(scope, {group, pid, :_, tag})
      {pid, meta}
    end
  end

  # Same as above but operates on incoming wire `[{group, pid, tag}]`
  # triples and returns `%{group => [{pid, meta}, ...]}` so notifications
  # can be batched per group.
  defp remove_rows_for_triples(scope, triples) do
    Enum.reduce(triples, %{}, fn {group, pid, tag}, acc ->
      case :ets.match_object(scope, {group, pid, :_, tag}) do
        [{^group, ^pid, meta, ^tag}] ->
          :ets.match_delete(scope, {group, pid, :_, tag})
          Map.update(acc, group, [{pid, meta}], &[{pid, meta} | &1])

        [] ->
          acc
      end
    end)
  end

  # Walks ETS for every row matching (group, pid, _, _), replaces meta,
  # returns the list of {pid, old, new} triples for notification.
  defp rewrite_meta(scope, group, pid, new_meta) do
    rows = :ets.match_object(scope, {group, pid, :_, :_})

    for {^group, ^pid, old_meta, tag} <- rows do
      :ets.match_delete(scope, {group, pid, :_, tag})
      :ets.insert(scope, {group, pid, new_meta, tag})
      {pid, old_meta, new_meta}
    end
  end

  defp down_local_pid(scope, pid, entries) do
    for {group, tag} <- entries do
      case :ets.match_object(scope, {group, pid, :_, tag}) do
        [{^group, ^pid, meta, ^tag}] ->
          :ets.match_delete(scope, {group, pid, :_, tag})
          {group, pid, meta, tag}

        [] ->
          # row already gone (rare race) — synthesize with nil meta so
          # subscribers still see something consistent
          {group, pid, nil, tag}
      end
    end
  end

  defp notify_local_down(scope_mon, mg, triples) do
    triples
    |> Enum.group_by(fn {g, _, _, _} -> g end, fn {_, p, m, _} -> {p, m} end)
    |> Enum.each(fn {g, pub} ->
      notify_group(scope_mon, mg, :leave, g, pub)
    end)
  end

  defp broadcast_leaves(remote_map, group, removed) do
    triples = for {pid, tag} <- removed, do: {group, pid, tag}
    broadcast(Map.keys(remote_map), {:leave, self(), triples})
  end

  # --- state.remote helpers ---

  defp remove_remote_triples(remote_groups, triples) do
    for {group, pid, tag} <- triples, reduce: remote_groups do
      acc ->
        filtered =
          acc
          |> Map.get(group, [])
          |> Enum.reject(fn {p, _m, t} -> p == pid and t == tag end)

        cond do
          not Map.has_key?(acc, group) -> acc
          filtered == [] -> Map.delete(acc, group)
          true -> Map.put(acc, group, filtered)
        end
    end
  end

  defp update_remote_meta(remote_groups, group, pid, new_meta) do
    case Map.get(remote_groups, group) do
      nil ->
        remote_groups

      entries ->
        updated =
          Enum.map(entries, fn
            {^pid, _old, tag} -> {pid, new_meta, tag}
            other -> other
          end)

        Map.put(remote_groups, group, updated)
    end
  end

  # --- sync from remote peer ---

  defp handle_sync(scope, peer, remote, groups) do
    {mref, remote_groups} =
      case Map.fetch(remote, peer) do
        :error -> {Process.monitor(peer), %{}}
        {:ok, existing} -> existing
      end

    sync_groups(scope, remote_groups, groups)
    Map.put(remote, peer, {mref, Map.new(groups)})
  end

  # No more groups in the new view → everything left in remote_groups
  # should be removed from ETS.
  defp sync_groups(scope, remote_groups, []) do
    for {group, entries} <- remote_groups, {_pid, _meta, tag} <- entries do
      :ets.match_delete(scope, {group, :_, :_, tag})
    end
  end

  defp sync_groups(scope, remote_groups, [{group, new_entries} | tail]) do
    case Map.pop(remote_groups, group) do
      {nil, _} ->
        for {pid, meta, tag} <- new_entries do
          :ets.insert(scope, {group, pid, meta, tag})
        end

        sync_groups(scope, remote_groups, tail)

      {old_entries, new_remote_groups} ->
        sync_one_group(scope, group, old_entries, new_entries)
        sync_groups(scope, new_remote_groups, tail)
    end
  end

  # Compute per-entry diff by (pid, tag). Removed entries are deleted
  # from ETS; new entries are inserted. No notifications fire — see the
  # design notes about sync ambiguity for multi-join metadata.
  defp sync_one_group(scope, group, old_entries, new_entries) do
    new_set = MapSet.new(new_entries, fn {p, _m, t} -> {p, t} end)
    old_set = MapSet.new(old_entries, fn {p, _m, t} -> {p, t} end)

    for {pid, _meta, tag} <- old_entries, not MapSet.member?(new_set, {pid, tag}) do
      :ets.match_delete(scope, {group, pid, :_, tag})
    end

    for {pid, meta, tag} <- new_entries, not MapSet.member?(old_set, {pid, tag}) do
      :ets.insert(scope, {group, pid, meta, tag})
    end
  end

  # Walks the ETS table for every row whose pid is local. Returns
  # `[{group, [{pid, meta, tag}, ...]}, ...]` for the discovery handshake.
  defp all_local_entries(scope) do
    fn {group, pid, meta, tag}, acc ->
      if node(pid) == node() do
        Map.update(acc, group, [{pid, meta, tag}], &[{pid, meta, tag} | &1])
      else
        acc
      end
    end
    |> :ets.foldl(
      %{},
      scope
    )
    |> Map.to_list()
  end

  defp broadcast([], _msg), do: :ok

  defp broadcast([dest | tail], msg) do
    send(dest, msg)
    broadcast(tail, msg)
  end

  defp demonitor_group(tag, group, mg) do
    case Map.fetch(mg, group) do
      {:ok, [^tag]} -> Map.delete(mg, group)
      {:ok, tags} -> Map.put(mg, group, tags -- [tag])
      :error -> mg
    end
  end

  defp notify_group(scope_monitors, mg, action, group, payload) do
    Enum.each(scope_monitors, fn {ref, pid} ->
      send(pid, {ref, action, group, payload})
    end)

    case Map.fetch(mg, group) do
      :error ->
        :ok

      {:ok, monitors} ->
        Enum.each(monitors, fn {pid, ref} ->
          send(pid, {ref, action, group, payload})
        end)
    end
  end

  defp flush(ref) do
    receive do
      {^ref, verb, _group, _payload} when verb in [:join, :leave, :update] ->
        flush(ref)
    after
      0 -> :ok
    end
  end
end
