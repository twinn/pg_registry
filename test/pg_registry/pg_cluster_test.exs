defmodule PgRegistry.PgClusterTest do
  use ExUnit.Case, async: false

  alias PgRegistry.Pg

  @moduletag :cluster

  setup do
    scope = :"pg_cluster_#{:erlang.unique_integer([:positive])}"
    cookie = Atom.to_charlist(Node.get_cookie())

    {:ok, peer, peer_node} =
      :peer.start(%{
        name: :"pg_peer_#{:erlang.unique_integer([:positive])}",
        args: [~c"-setcookie", cookie]
      })

    # share code paths so the peer can find PgRegistry.Pg and the test helper.
    :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :erpc.call(peer_node, Application, :ensure_all_started, [:pg_registry])

    # start the scope on both nodes
    {:ok, _} = Pg.start_link(scope)
    {:ok, _} = :erpc.call(peer_node, Pg, :start, [scope])

    # let discover/sync round-trip settle
    sync(scope, peer_node)

    on_exit(fn -> :peer.stop(peer) end)
    {:ok, scope: scope, peer: peer, peer_node: peer_node}
  end

  # Drain both scope mailboxes by issuing a sys:get_state on each side.
  defp sync(scope, peer_node) do
    _ = :sys.get_state(scope)
    _ = :erpc.call(peer_node, :sys, :get_state, [scope])
    _ = :sys.get_state(scope)
  end

  defp spawn_remote_member(peer_node, scope, group, meta \\ nil) do
    parent = self()

    pid =
      :erpc.call(peer_node, :erlang, :spawn, [
        PgRegistry.Pg.TestHelper,
        :member_loop,
        [parent, scope, group, meta]
      ])

    receive do
      {:joined, ^pid} -> :ok
    end

    pid
  end

  test "remote join becomes visible locally", %{scope: scope, peer_node: peer_node} do
    remote_pid = spawn_remote_member(peer_node, scope, :workers)
    sync(scope, peer_node)

    assert remote_pid in Pg.get_members(scope, :workers)
    # remote pids must NOT show up in local members on this node
    assert [] == Pg.get_local_members(scope, :workers)
    assert :workers in Pg.which_groups(scope)
  end

  test "local join becomes visible on the remote node", %{scope: scope, peer_node: peer_node} do
    me = self()
    :ok = Pg.join(scope, :workers, me)
    sync(scope, peer_node)

    remote_members = :erpc.call(peer_node, Pg, :get_members, [scope, :workers])
    assert me in remote_members
    # local on the remote node should be empty (we're remote from its POV)
    assert [] == :erpc.call(peer_node, Pg, :get_local_members, [scope, :workers])
  end

  test "remote process exit propagates a leave", %{scope: scope, peer_node: peer_node} do
    remote_pid = spawn_remote_member(peer_node, scope, :ephemeral)
    sync(scope, peer_node)
    assert remote_pid in Pg.get_members(scope, :ephemeral)

    ref = Process.monitor(remote_pid)
    :erpc.call(peer_node, :erlang, :exit, [remote_pid, :kill])

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end

    sync(scope, peer_node)
    assert [] == Pg.get_members(scope, :ephemeral)
    refute :ephemeral in Pg.which_groups(scope)
  end

  test "remote scope crash removes its members locally", %{scope: scope, peer_node: peer_node} do
    remote_pid = spawn_remote_member(peer_node, scope, :workers)
    sync(scope, peer_node)
    assert length(Pg.get_members(scope, :workers)) == 1

    # Subscribe BEFORE killing — the leave notification is fired from
    # inside the local scope's DOWN handler, so receiving it proves the
    # ETS row has already been removed. Polling :sys.get_state races
    # against the in-flight DOWN delivery from the peer node.
    {ref, _} = Pg.monitor_scope(scope)

    remote_scope_pid = :erpc.call(peer_node, Process, :whereis, [scope])
    :erpc.call(peer_node, Process, :exit, [remote_scope_pid, :kill])

    assert_receive {^ref, :leave, :workers, [{^remote_pid, _}]}, 2000
    assert [] == Pg.get_members(scope, :workers)
  end

  test "monitor_scope receives notifications about remote joins",
       %{scope: scope, peer_node: peer_node} do
    {ref, _} = Pg.monitor_scope(scope)
    remote_pid = spawn_remote_member(peer_node, scope, :watched)
    assert_receive {^ref, :join, :watched, [{^remote_pid, nil}]}, 1000

    :erpc.call(peer_node, Pg, :leave, [scope, :watched, remote_pid])
    assert_receive {^ref, :leave, :watched, [{^remote_pid, nil}]}, 1000
  end

  test "remote join with metadata propagates the meta everywhere",
       %{scope: scope, peer_node: peer_node} do
    {ref, _} = Pg.monitor_scope(scope)
    remote_pid = spawn_remote_member(peer_node, scope, :workers, %{role: :primary})

    assert_receive {^ref, :join, :workers, [{^remote_pid, %{role: :primary}}]}, 1000
    assert {remote_pid, %{role: :primary}} in Pg.lookup(scope, :workers)
    # local node sees no local entries for this group
    assert [] == Pg.lookup_local(scope, :workers)
  end

  test "keys: :unique is per-node — each node holds its own registration",
       %{peer_node: peer_node} do
    scope = :"pg_uniq_cluster_#{:erlang.unique_integer([:positive])}"

    # Both nodes start the same scope in unique mode
    {:ok, _} = Pg.start(scope, keys: :unique)
    {:ok, _} = :erpc.call(peer_node, Pg, :start, [scope, [keys: :unique]])

    # Local node registers a singleton
    :ok = Pg.join(scope, :singleton, self())

    # Peer node also registers a singleton — should succeed because
    # uniqueness is local-only
    remote_pid = spawn_remote_member(peer_node, scope, :singleton)

    sync(scope, peer_node)

    members = Pg.get_members(scope, :singleton)
    assert self() in members
    assert remote_pid in members
    # Local view: only our pid is local
    assert [self()] == Pg.get_local_members(scope, :singleton)
    # Local re-register still fails
    assert {:error, {:already_registered, _}} = Pg.join(scope, :singleton, self())
  end

  test "remote update_meta is visible locally and notifies subscribers",
       %{scope: scope, peer_node: peer_node} do
    {ref, _} = Pg.monitor_scope(scope)
    remote_pid = spawn_remote_member(peer_node, scope, :workers, :v1)
    assert_receive {^ref, :join, :workers, [{^remote_pid, :v1}]}, 1000

    # update_meta runs on the peer node (where the pid is local)
    :ok = :erpc.call(peer_node, Pg, :update_meta, [scope, :workers, remote_pid, :v2])

    assert_receive {^ref, :update, :workers, [{^remote_pid, :v1, :v2}]}, 1000
    assert {remote_pid, :v2} in Pg.lookup(scope, :workers)
  end
end
