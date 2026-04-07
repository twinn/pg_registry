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

  defp spawn_remote_member(peer_node, scope, group) do
    parent = self()

    pid =
      :erpc.call(peer_node, :erlang, :spawn, [
        PgRegistry.Pg.TestHelper,
        :member_loop,
        [parent, scope, group]
      ])

    receive do: ({:joined, ^pid} -> :ok)
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
    receive do: ({:DOWN, ^ref, _, _, _} -> :ok)

    sync(scope, peer_node)
    assert [] == Pg.get_members(scope, :ephemeral)
    refute :ephemeral in Pg.which_groups(scope)
  end

  test "remote scope crash removes its members locally", %{scope: scope, peer_node: peer_node} do
    _remote_pid = spawn_remote_member(peer_node, scope, :workers)
    sync(scope, peer_node)
    assert length(Pg.get_members(scope, :workers)) == 1

    remote_scope_pid = :erpc.call(peer_node, Process, :whereis, [scope])
    ref = Process.monitor(remote_scope_pid)
    :erpc.call(peer_node, Process, :exit, [remote_scope_pid, :kill])
    receive do: ({:DOWN, ^ref, _, _, _} -> :ok)

    _ = :sys.get_state(scope)
    assert [] == Pg.get_members(scope, :workers)
  end

  test "monitor_scope receives notifications about remote joins",
       %{scope: scope, peer_node: peer_node} do
    {ref, _} = Pg.monitor_scope(scope)
    remote_pid = spawn_remote_member(peer_node, scope, :watched)
    assert_receive {^ref, :join, :watched, [^remote_pid]}, 1000

    :erpc.call(peer_node, Pg, :leave, [scope, :watched, remote_pid])
    assert_receive {^ref, :leave, :watched, [^remote_pid]}, 1000
  end
end
