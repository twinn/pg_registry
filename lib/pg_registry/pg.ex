defmodule PgRegistry.Pg do
  @moduledoc """
  An Elixir port of Erlang's `:pg` module.

  Distributed named process groups with eventually consistent membership.
  This is a near line-for-line translation of the OTP 27 `pg.erl` (single
  GenServer + ETS table) into Elixir, kept self-contained so we can extend
  it with metadata support without forking OTP.

  Each scope is its own GenServer registered locally under the scope name,
  and owns an ETS table of the same name with rows of shape:

      {group, all_pids, local_pids}

  Lookups (`get_members/2`, `get_local_members/2`, `which_groups/1`) read
  the ETS table directly from the caller, so they are O(1) and never block.
  All mutations go through the GenServer.
  """

  use GenServer

  @type scope :: atom()
  @type group :: term()

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
    :ok = ensure_local(pid_or_pids)
    GenServer.call(scope, {:join_local, group, pid_or_pids}, :infinity)
  end

  @spec leave(scope(), group(), pid() | [pid()]) :: :ok | :not_joined
  def leave(scope, group, pid_or_pids) when is_pid(pid_or_pids) or is_list(pid_or_pids) do
    :ok = ensure_local(pid_or_pids)
    GenServer.call(scope, {:leave_local, group, pid_or_pids}, :infinity)
  end

  @spec get_members(scope(), group()) :: [pid()]
  def get_members(scope, group) do
    try do
      :ets.lookup_element(scope, group, 2, [])
    rescue
      ArgumentError -> []
    end
  end

  @spec get_local_members(scope(), group()) :: [pid()]
  def get_local_members(scope, group) do
    try do
      :ets.lookup_element(scope, group, 3, [])
    rescue
      ArgumentError -> []
    end
  end

  @spec which_groups(scope()) :: [group()]
  def which_groups(scope) when is_atom(scope) do
    for [g] <- :ets.match(scope, {:"$1", :_, :_}), do: g
  end

  @spec monitor_scope(scope()) :: {reference(), %{group() => [pid()]}}
  def monitor_scope(scope), do: GenServer.call(scope, :monitor, :infinity)

  @spec monitor(scope(), group()) :: {reference(), [pid()]}
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
  # GenServer
  # ---------------------------------------------------------------------------

  defmodule State do
    @moduledoc false
    defstruct scope: nil,
              # %{pid => {monitor_ref, [group]}} — locally joined processes
              local: %{},
              # %{peer_pid => {monitor_ref, %{group => [pid]}}} — remote scope peers
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
  def handle_call({:join_local, group, pid_or_pids}, _from, %State{} = s) do
    new_local = join_local(pid_or_pids, group, s.local)
    join_local_update_ets(s.scope, s.scope_monitors, s.monitored_groups, group, pid_or_pids)
    broadcast(Map.keys(s.remote), {:join, self(), group, pid_or_pids})
    {:reply, :ok, %{s | local: new_local}}
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
    contents = for [g, p] <- :ets.match(s.scope, {:"$1", :"$2", :_}), into: %{}, do: {g, p}
    ref = Process.monitor(pid, tag: {:DOWN, :scope_monitors})
    {:reply, {ref, contents}, %{s | scope_monitors: Map.put(s.scope_monitors, ref, pid)}}
  end

  def handle_call({:monitor, group}, {pid, _tag}, %State{} = s) do
    members = get_members(s.scope, group)
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
  def handle_info({:join, peer, group, pid_or_pids}, %State{} = s) do
    case Map.get(s.remote, peer) do
      {mref, remote_groups} ->
        join_remote_update_ets(s.scope, s.scope_monitors, s.monitored_groups, group, pid_or_pids)
        new_remote_groups = join_remote(group, pid_or_pids, remote_groups)
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
        Enum.each(remote_map, fn {group, pids} ->
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
  # Internals (mirrors pg.erl helpers)
  # ---------------------------------------------------------------------------

  defp handle_discover(peer, %State{remote: remote, local: local, scope: scope} = s) do
    GenServer.cast(peer, {:sync, self(), all_local_pids(local)})

    case Map.has_key?(remote, peer) do
      true ->
        {:noreply, s}

      false ->
        mref = Process.monitor(peer)
        send(peer, {:discover, self()})
        _ = scope
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

  # --- local membership bookkeeping ---

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

  # --- ETS updates ---

  defp join_local_update_ets(scope, scope_mon, mg, group, pid) when is_pid(pid) do
    case :ets.lookup(scope, group) do
      [{_g, all, local}] ->
        :ets.insert(scope, {group, [pid | all], [pid | local]})

      [] ->
        :ets.insert(scope, {group, [pid], [pid]})
    end

    notify_group(scope_mon, mg, :join, group, [pid])
  end

  defp join_local_update_ets(scope, scope_mon, mg, group, pids) when is_list(pids) do
    case :ets.lookup(scope, group) do
      [{_g, all, local}] ->
        :ets.insert(scope, {group, pids ++ all, pids ++ local})

      [] ->
        :ets.insert(scope, {group, pids, pids})
    end

    notify_group(scope_mon, mg, :join, group, pids)
  end

  defp join_remote_update_ets(scope, scope_mon, mg, group, pid) when is_pid(pid) do
    case :ets.lookup(scope, group) do
      [{_g, all, local}] -> :ets.insert(scope, {group, [pid | all], local})
      [] -> :ets.insert(scope, {group, [pid], []})
    end

    notify_group(scope_mon, mg, :join, group, [pid])
  end

  defp join_remote_update_ets(scope, scope_mon, mg, group, pids) when is_list(pids) do
    case :ets.lookup(scope, group) do
      [{_g, all, local}] -> :ets.insert(scope, {group, pids ++ all, local})
      [] -> :ets.insert(scope, {group, pids, []})
    end

    notify_group(scope_mon, mg, :join, group, pids)
  end

  defp leave_local_update_ets(scope, scope_mon, mg, group, pid) when is_pid(pid) do
    case :ets.lookup(scope, group) do
      [{_g, [^pid], [^pid]}] ->
        :ets.delete(scope, group)
        notify_group(scope_mon, mg, :leave, group, [pid])

      [{_g, all, local}] ->
        :ets.insert(scope, {group, List.delete(all, pid), List.delete(local, pid)})
        notify_group(scope_mon, mg, :leave, group, [pid])

      [] ->
        true
    end
  end

  defp leave_local_update_ets(scope, scope_mon, mg, group, pids) when is_list(pids) do
    case :ets.lookup(scope, group) do
      [{_g, all, local}] ->
        case all -- pids do
          [] -> :ets.delete(scope, group)
          new_all -> :ets.insert(scope, {group, new_all, local -- pids})
        end

        notify_group(scope_mon, mg, :leave, group, pids)

      [] ->
        true
    end
  end

  defp leave_remote_update_ets(scope, scope_mon, mg, pid, groups) when is_pid(pid) do
    Enum.each(groups, fn group ->
      case :ets.lookup(scope, group) do
        [{_g, [^pid], []}] ->
          :ets.delete(scope, group)
          notify_group(scope_mon, mg, :leave, group, [pid])

        [{_g, all, local}] ->
          :ets.insert(scope, {group, List.delete(all, pid), local})
          notify_group(scope_mon, mg, :leave, group, [pid])

        [] ->
          true
      end
    end)
  end

  defp leave_remote_update_ets(scope, scope_mon, mg, pids, groups) when is_list(pids) do
    Enum.each(groups, fn group ->
      case :ets.lookup(scope, group) do
        [{_g, all, local}] ->
          case all -- pids do
            [] when local == [] -> :ets.delete(scope, group)
            new_all -> :ets.insert(scope, {group, new_all, local})
          end

          notify_group(scope_mon, mg, :leave, group, pids)

        [] ->
          true
      end
    end)
  end

  # --- remote group bookkeeping ---

  defp join_remote(group, pid, remote_groups) when is_pid(pid) do
    Map.update(remote_groups, group, [pid], fn list -> [pid | list] end)
  end

  defp join_remote(group, pids, remote_groups) when is_list(pids) do
    Map.update(remote_groups, group, pids, fn list -> pids ++ list end)
  end

  defp leave_remote(pid, remote_map, groups) when is_pid(pid),
    do: leave_remote([pid], remote_map, groups)

  defp leave_remote(pids, remote_map, groups) do
    Enum.reduce(groups, remote_map, fn group, acc ->
      case Map.get(acc, group, []) -- pids do
        [] -> Map.delete(acc, group)
        remaining -> Map.put(acc, group, remaining)
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
    Enum.each(remote_groups, fn {group, pids} ->
      leave_remote_update_ets(scope, scope_mon, mg, pids, [group])
    end)
  end

  defp sync_groups(scope, scope_mon, mg, remote_groups, [{group, pids} | tail]) do
    case Map.pop(remote_groups, group) do
      {^pids, new_remote_groups} ->
        sync_groups(scope, scope_mon, mg, new_remote_groups, tail)

      {nil, _} ->
        join_remote_update_ets(scope, scope_mon, mg, group, pids)
        sync_groups(scope, scope_mon, mg, remote_groups, tail)

      {old_pids, new_remote_groups} ->
        [{_g, all_old, local_pids}] = :ets.lookup(scope, group)
        all_new = pids ++ (all_old -- old_pids)
        :ets.insert(scope, {group, all_new, local_pids})
        sync_groups(scope, scope_mon, mg, new_remote_groups, tail)
    end
  end

  defp all_local_pids(local) do
    local
    |> Enum.reduce(%{}, fn {pid, {_ref, groups}}, acc ->
      Enum.reduce(groups, acc, fn g, acc1 ->
        Map.update(acc1, g, [pid], fn list -> [pid | list] end)
      end)
    end)
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

  defp notify_group(scope_monitors, mg, action, group, pids) do
    Enum.each(scope_monitors, fn {ref, pid} ->
      send(pid, {ref, action, group, pids})
    end)

    case Map.fetch(mg, group) do
      :error ->
        :ok

      {:ok, monitors} ->
        Enum.each(monitors, fn {pid, ref} ->
          send(pid, {ref, action, group, pids})
        end)
    end
  end

  defp flush(ref) do
    receive do
      {^ref, verb, _group, _pids} when verb == :join or verb == :leave -> flush(ref)
    after
      0 -> :ok
    end
  end
end
