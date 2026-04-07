defmodule PgRegistry.Pg do
  @moduledoc """
  An Elixir port of Erlang's `:pg` module, extended internally to carry
  per-member metadata.

  Distributed named process groups with eventually consistent membership.

  Each scope is its own GenServer registered locally under the scope name,
  and owns an ETS table of the same name with rows of shape:

      {group, all_entries, local_entries}

  where each entry is `{pid, meta}` and `meta` defaults to `nil`. The
  third slot is the subset of entries whose pid lives on this node.

  As of step 1, the public API is unchanged: `get_members/2` and
  `get_local_members/2` still return `[pid]`, and subscription
  notifications still carry `[pid]`. Metadata is stored and gossiped
  between nodes but not yet exposed.

  Lookups read the ETS table directly from the caller, so they are O(1)
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

  @doc """
  Starts a scope outside of any supervision/link tree. Mirrors `:pg.start/1`.
  """
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

  When a list of pids is given, the same `meta` is stored for each. To
  store different metadata for different pids, call `join/4` multiple
  times. A pid may be joined to the same group multiple times with
  different metas; each entry is independent and must be left
  separately.
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
  setting it to `new_meta`.

  If `pid` was joined multiple times to `group` (with possibly different
  metas), all of those entries are updated to `new_meta`. Returns
  `:not_joined` when `pid` is not in the group.

  Subscribers receive `{ref, :update, group, [{pid, old_meta, new_meta}, ...]}`.
  """
  @spec update_meta(scope(), group(), pid(), meta()) :: :ok | :not_joined
  def update_meta(scope, group, pid, new_meta) when is_pid(pid) do
    :ok = ensure_local(pid)
    GenServer.call(scope, {:update_meta, group, pid, new_meta}, :infinity)
  end

  @spec get_members(scope(), group()) :: [pid()]
  def get_members(scope, group) do
    extract_pids(lookup(scope, group))
  end

  @spec get_local_members(scope(), group()) :: [pid()]
  def get_local_members(scope, group) do
    extract_pids(lookup_local(scope, group))
  end

  @spec which_groups(scope()) :: [group()]
  def which_groups(scope) when is_atom(scope) do
    for [g] <- :ets.match(scope, {:"$1", :_, :_}), do: g
  end

  @doc """
  Subscribes to all group changes in `scope`.

  Returns `{ref, snapshot}` where `snapshot` is `%{group => [{pid, meta}]}`.
  Subsequent join/leave events are delivered as
  `{ref, :join | :leave, group, [{pid, meta}, ...]}`.
  """
  @spec monitor_scope(scope()) :: {reference(), %{group() => [entry()]}}
  def monitor_scope(scope), do: GenServer.call(scope, :monitor, :infinity)

  @doc """
  Subscribes to changes in a single `group`.

  Returns `{ref, [{pid, meta}, ...]}` and delivers entry-shaped
  notifications, same as `monitor_scope/1`.
  """
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

  @doc """
  Returns all `{pid, meta}` entries registered under `group`, across the
  whole cluster.

  This is the metadata-aware counterpart to `get_members/2`. The same
  pid may appear multiple times if it was joined more than once.
  """
  @spec lookup(scope(), group()) :: [entry()]
  def lookup(scope, group) do
    :ets.lookup_element(scope, group, 2, [])
  rescue
    ArgumentError -> []
  end

  @doc """
  Returns the `{pid, meta}` entries for `group` whose pid lives on the
  local node.
  """
  @spec lookup_local(scope(), group()) :: [entry()]
  def lookup_local(scope, group) do
    :ets.lookup_element(scope, group, 3, [])
  rescue
    ArgumentError -> []
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  defmodule State do
    @moduledoc false
    defstruct scope: nil,
              # %{pid => {monitor_ref, [group]}} — locally joined processes.
              # Used for monitor bookkeeping; metadata lives in ETS, not here.
              local: %{},
              # %{peer_pid => {monitor_ref, %{group => [{pid, meta}]}}}
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

    ^scope = :ets.new(scope, [:set, :protected, :named_table, {:read_concurrency, true}])
    {:ok, %State{scope: scope}}
  end

  @impl true
  def handle_call({:join_local, group, pid_or_pids, meta}, _from, %State{} = s) do
    entries = wrap_meta(pid_or_pids, meta)
    new_local = join_local(pid_or_pids, group, s.local)
    join_local_update_ets(s.scope, s.scope_monitors, s.monitored_groups, group, entries)
    broadcast(Map.keys(s.remote), {:join, self(), group, entries})
    {:reply, :ok, %{s | local: new_local}}
  end

  def handle_call({:update_meta, group, pid, new_meta}, _from, %State{} = s) do
    case :ets.lookup(s.scope, group) do
      [{_g, all, local}] ->
        case replace_meta_for_pid(all, pid, new_meta) do
          {_, []} ->
            {:reply, :not_joined, s}

          {new_all, updates} ->
            {new_local, _} = replace_meta_for_pid(local, pid, new_meta)
            :ets.insert(s.scope, {group, new_all, new_local})
            notify_group(s.scope_monitors, s.monitored_groups, :update, group, updates)
            broadcast(Map.keys(s.remote), {:update_meta, self(), group, pid, new_meta})
            {:reply, :ok, s}
        end

      [] ->
        {:reply, :not_joined, s}
    end
  end

  def handle_call({:leave_local, group, pid_or_pids}, _from, %State{} = s) do
    case leave_local(pid_or_pids, group, s.local) do
      same when same == s.local ->
        {:reply, :not_joined, s}

      new_local ->
        leave_local_update_ets(s.scope, s.scope_monitors, s.monitored_groups, group, pid_or_pids)
        broadcast(Map.keys(s.remote), {:leave, self(), pid_or_pids, [group]})
        {:reply, :ok, %{s | local: new_local}}
    end
  end

  def handle_call(:monitor, {pid, _tag}, %State{} = s) do
    contents =
      for [g, entries] <- :ets.match(s.scope, {:"$1", :"$2", :_}),
          into: %{},
          do: {g, entries}

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
  def handle_info({:join, peer, group, entries}, %State{} = s) do
    case Map.get(s.remote, peer) do
      {mref, remote_groups} ->
        join_remote_update_ets(s.scope, s.scope_monitors, s.monitored_groups, group, entries)
        new_remote_groups = join_remote(group, entries, remote_groups)
        {:noreply, %{s | remote: Map.put(s.remote, peer, {mref, new_remote_groups})}}

      nil ->
        # node flickering or out-of-overlay sender — ignore
        {:noreply, s}
    end
  end

  def handle_info({:leave, peer, pid_or_pids, groups}, %State{} = s) do
    case Map.get(s.remote, peer) do
      {mref, remote_map} ->
        leave_remote_update_ets(
          s.scope,
          s.scope_monitors,
          s.monitored_groups,
          pid_or_pids,
          groups
        )

        new_remote_map = leave_remote(pid_or_pids, remote_map, groups)
        {:noreply, %{s | remote: Map.put(s.remote, peer, {mref, new_remote_map})}}

      nil ->
        {:noreply, s}
    end
  end

  def handle_info({:update_meta, peer, group, pid, new_meta}, %State{} = s) do
    with {:ok, {mref, remote_groups}} <- Map.fetch(s.remote, peer),
         [{_g, all, local}] <- :ets.lookup(s.scope, group) do
      {new_all, updates} = replace_meta_for_pid(all, pid, new_meta)

      if updates != [] do
        :ets.insert(s.scope, {group, new_all, local})
        notify_group(s.scope_monitors, s.monitored_groups, :update, group, updates)
      end

      new_remote_groups =
        case Map.get(remote_groups, group) do
          nil ->
            remote_groups

          entries ->
            {updated, _} = replace_meta_for_pid(entries, pid, new_meta)
            Map.put(remote_groups, group, updated)
        end

      {:noreply, %{s | remote: Map.put(s.remote, peer, {mref, new_remote_groups})}}
    else
      _ -> {:noreply, s}
    end
  end

  def handle_info({:discover, peer}, %State{} = s), do: handle_discover(peer, s)
  def handle_info({:discover, peer, _proto_version}, %State{} = s), do: handle_discover(peer, s)

  # Local process exit
  def handle_info({:DOWN, mref, :process, pid, _info}, %State{} = s) when node(pid) == node() do
    case Map.pop(s.local, pid) do
      {nil, _} ->
        {:noreply, s}

      {{^mref, groups}, new_local} ->
        for g <- groups do
          leave_local_update_ets(s.scope, s.scope_monitors, s.monitored_groups, g, pid)
        end

        broadcast(Map.keys(s.remote), {:leave, self(), pid, groups})
        {:noreply, %{s | local: new_local}}
    end
  end

  # Remote scope process down
  def handle_info({:DOWN, mref, :process, pid, _info}, %State{} = s) do
    case Map.pop(s.remote, pid) do
      {{^mref, remote_map}, new_remote} ->
        Enum.each(remote_map, fn {group, entries} ->
          pids = extract_pids(entries)
          leave_remote_update_ets(s.scope, s.scope_monitors, s.monitored_groups, pids, [group])
        end)

        {:noreply, %{s | remote: new_remote}}

      _ ->
        {:noreply, s}
    end
  end

  # Scope subscriber went away
  def handle_info({{:DOWN, :scope_monitors}, mref, :process, _pid, _info}, %State{} = s) do
    {:noreply, %{s | scope_monitors: Map.delete(s.scope_monitors, mref)}}
  end

  # Group subscriber went away
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
    new_remote =
      handle_sync(s.scope, s.scope_monitors, s.monitored_groups, peer, s.remote, groups)

    {:noreply, %{s | remote: new_remote}}
  end

  @impl true
  def terminate(_reason, %State{scope: scope}) do
    if :ets.info(scope) != :undefined, do: :ets.delete(scope)
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

  # --- entry helpers ---

  defp wrap_meta(pid, meta) when is_pid(pid), do: [{pid, meta}]
  defp wrap_meta(pids, meta) when is_list(pids), do: Enum.map(pids, &{&1, meta})

  defp extract_pids(entries), do: for({p, _} <- entries, do: p)

  # Pops the first entry whose pid matches `target`. Mirrors :pg.erl's
  # `lists:delete/2` for ref-counted joins, but compares only the pid
  # component (meta is ignored on leave) and returns the popped entry
  # so callers can ship its meta in notifications.
  defp pop_first_by_pid([], _target), do: {nil, []}
  defp pop_first_by_pid([{target, _} = entry | tail], target), do: {entry, tail}

  defp pop_first_by_pid([head | tail], target) do
    {popped, rest} = pop_first_by_pid(tail, target)
    {popped, [head | rest]}
  end

  # Replaces every {pid, _} entry's meta with `new_meta`. Returns the
  # rewritten entries list AND a list of `{pid, old_meta, new_meta}`
  # triples for the entries that actually changed (so subscribers can
  # see what was updated). Entries with `^new_meta` already are still
  # reported as triples, since the user explicitly asked for the update.
  defp replace_meta_for_pid(entries, pid, new_meta) do
    entries
    |> Enum.map_reduce([], fn
      {^pid, old_meta} = _entry, updates ->
        {{pid, new_meta}, [{pid, old_meta, new_meta} | updates]}

      other, updates ->
        {other, updates}
    end)
    |> then(fn {new_entries, updates_rev} -> {new_entries, Enum.reverse(updates_rev)} end)
  end

  # Pops one entry per pid in `pids`, in input order. Pids without a
  # match in `entries` are silently skipped (matching pg.erl semantics).
  # Returns {popped_entries_in_input_order, remaining_entries}.
  defp pop_first_by_pids(entries, pids) do
    {popped_rev, remaining} =
      Enum.reduce(pids, {[], entries}, fn pid, {popped, rem} ->
        case pop_first_by_pid(rem, pid) do
          {nil, _} -> {popped, rem}
          {entry, new_rem} -> {[entry | popped], new_rem}
        end
      end)

    {Enum.reverse(popped_rev), remaining}
  end

  # --- local membership bookkeeping (state.local) ---

  defp join_local(pid, group, local) when is_pid(pid) do
    case Map.fetch(local, pid) do
      {:ok, {mref, groups}} ->
        Map.put(local, pid, {mref, [group | groups]})

      :error ->
        mref = Process.monitor(pid)
        Map.put(local, pid, {mref, [group]})
    end
  end

  defp join_local([], _group, local), do: local

  defp join_local([pid | tail], group, local) do
    join_local(tail, group, join_local(pid, group, local))
  end

  defp leave_local(pid, group, local) when is_pid(pid) do
    case Map.fetch(local, pid) do
      {:ok, {mref, [^group]}} ->
        Process.demonitor(mref, [:flush])
        Map.delete(local, pid)

      {:ok, {mref, groups}} ->
        if group in groups do
          Map.put(local, pid, {mref, List.delete(groups, group)})
        else
          local
        end

      :error ->
        local
    end
  end

  defp leave_local([], _group, local), do: local

  defp leave_local([pid | tail], group, local) do
    leave_local(tail, group, leave_local(pid, group, local))
  end

  # --- ETS updates (operate on entries) ---

  defp join_local_update_ets(scope, scope_mon, mg, group, entries) when is_list(entries) do
    case :ets.lookup(scope, group) do
      [{_g, all, local}] ->
        :ets.insert(scope, {group, entries ++ all, entries ++ local})

      [] ->
        :ets.insert(scope, {group, entries, entries})
    end

    notify_group(scope_mon, mg, :join, group, entries)
  end

  defp join_remote_update_ets(scope, scope_mon, mg, group, entries) when is_list(entries) do
    case :ets.lookup(scope, group) do
      [{_g, all, local}] -> :ets.insert(scope, {group, entries ++ all, local})
      [] -> :ets.insert(scope, {group, entries, []})
    end

    notify_group(scope_mon, mg, :join, group, entries)
  end

  defp leave_local_update_ets(scope, scope_mon, mg, group, pid) when is_pid(pid),
    do: leave_local_update_ets(scope, scope_mon, mg, group, [pid])

  defp leave_local_update_ets(scope, scope_mon, mg, group, pids) when is_list(pids) do
    case :ets.lookup(scope, group) do
      [{_g, all, local}] ->
        {popped, new_all} = pop_first_by_pids(all, pids)
        {_, new_local} = pop_first_by_pids(local, pids)

        if new_all == [] do
          :ets.delete(scope, group)
        else
          :ets.insert(scope, {group, new_all, new_local})
        end

        if popped != [], do: notify_group(scope_mon, mg, :leave, group, popped)

      [] ->
        true
    end
  end

  defp leave_remote_update_ets(scope, scope_mon, mg, pid, groups) when is_pid(pid),
    do: leave_remote_update_ets(scope, scope_mon, mg, [pid], groups)

  defp leave_remote_update_ets(scope, scope_mon, mg, pids, groups) when is_list(pids) do
    for group <- groups,
        [{_g, all, local}] <- [:ets.lookup(scope, group)] do
      {popped, new_all} = pop_first_by_pids(all, pids)

      if new_all == [] and local == [] do
        :ets.delete(scope, group)
      else
        :ets.insert(scope, {group, new_all, local})
      end

      if popped != [], do: notify_group(scope_mon, mg, :leave, group, popped)
    end

    :ok
  end

  # --- remote-peer bookkeeping (state.remote inner map) ---

  defp join_remote(group, entries, remote_groups) when is_list(entries) do
    Map.update(remote_groups, group, entries, fn list -> entries ++ list end)
  end

  defp leave_remote(pid, remote_map, groups) when is_pid(pid), do: leave_remote([pid], remote_map, groups)

  defp leave_remote(pids, remote_map, groups) do
    Enum.reduce(groups, remote_map, fn group, acc ->
      {_popped, remaining} = pop_first_by_pids(Map.get(acc, group, []), pids)

      case remaining do
        [] -> Map.delete(acc, group)
        rest -> Map.put(acc, group, rest)
      end
    end)
  end

  # --- sync from remote peer ---

  defp handle_sync(scope, scope_mon, mg, peer, remote, groups) do
    {mref, remote_groups} =
      case Map.fetch(remote, peer) do
        :error -> {Process.monitor(peer), %{}}
        {:ok, existing} -> existing
      end

    sync_groups(scope, scope_mon, mg, remote_groups, groups)
    Map.put(remote, peer, {mref, Map.new(groups)})
  end

  defp sync_groups(scope, scope_mon, mg, remote_groups, []) do
    Enum.each(remote_groups, fn {group, entries} ->
      leave_remote_update_ets(scope, scope_mon, mg, extract_pids(entries), [group])
    end)
  end

  defp sync_groups(scope, scope_mon, mg, remote_groups, [{group, entries} | tail]) do
    case Map.pop(remote_groups, group) do
      {^entries, new_remote_groups} ->
        sync_groups(scope, scope_mon, mg, new_remote_groups, tail)

      {nil, _} ->
        join_remote_update_ets(scope, scope_mon, mg, group, entries)
        sync_groups(scope, scope_mon, mg, remote_groups, tail)

      {old_entries, new_remote_groups} ->
        # Different from before — recompute the row's all-slot. Local slot
        # is preserved (it's our own pids; the peer doesn't own them).
        [{_g, all_old, local}] = :ets.lookup(scope, group)
        all_new = entries ++ (all_old -- old_entries)
        :ets.insert(scope, {group, all_new, local})
        sync_groups(scope, scope_mon, mg, new_remote_groups, tail)
    end
  end

  # Walks the ETS table for rows whose local slot is non-empty and returns
  # `[{group, [{pid, meta}]}, ...]`. ETS is the source of truth for meta;
  # state.local doesn't store it.
  defp all_local_entries(scope) do
    :ets.select(scope, [
      {{:"$1", :_, :"$2"}, [{:"=/=", :"$2", []}], [{{:"$1", :"$2"}}]}
    ])
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

  defp notify_group(scope_monitors, mg, action, group, entries) do
    Enum.each(scope_monitors, fn {ref, pid} ->
      send(pid, {ref, action, group, entries})
    end)

    case Map.fetch(mg, group) do
      :error ->
        :ok

      {:ok, monitors} ->
        Enum.each(monitors, fn {pid, ref} ->
          send(pid, {ref, action, group, entries})
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
