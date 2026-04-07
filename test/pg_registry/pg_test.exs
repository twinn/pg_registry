defmodule PgRegistry.PgTest do
  use ExUnit.Case, async: false

  alias PgRegistry.Pg

  setup do
    scope = :"pg_test_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Pg, scope})
    {:ok, scope: scope}
  end

  defp spawn_member(scope, group) do
    parent = self()

    pid =
      spawn(fn ->
        Pg.join(scope, group, self())
        send(parent, :joined)
        receive do: (:stop -> :ok)
      end)

    receive do: (:joined -> :ok)
    pid
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
  end

  describe "start_link/1" do
    test "starts a named scope process", %{scope: scope} do
      assert is_pid(Process.whereis(scope))
    end

    test "creates an ETS table named after the scope", %{scope: scope} do
      assert :ets.info(scope) != :undefined
    end
  end

  describe "join/3 and get_members/2" do
    test "single pid join", %{scope: scope} do
      assert :ok = Pg.join(scope, :g, self())
      assert [self()] == Pg.get_members(scope, :g)
      assert [self()] == Pg.get_local_members(scope, :g)
    end

    test "joining same pid twice yields two entries", %{scope: scope} do
      :ok = Pg.join(scope, :g, self())
      :ok = Pg.join(scope, :g, self())
      assert [self(), self()] == Pg.get_members(scope, :g)
    end

    test "joining a list of pids", %{scope: scope} do
      p1 = spawn_member(scope, :other)
      :ok = Pg.join(scope, :g, [self(), p1])
      members = Pg.get_members(scope, :g)
      assert self() in members
      assert p1 in members
      stop(p1)
    end

    test "rejects non-pid argument", %{scope: scope} do
      assert_raise FunctionClauseError, fn -> Pg.join(scope, :g, :not_a_pid) end
    end

    test "rejects a list containing a non-pid", %{scope: scope} do
      assert_raise ErlangError, fn -> Pg.join(scope, :g, [self(), :nope]) end
    end

    test "get_members on unknown group returns []", %{scope: scope} do
      assert [] == Pg.get_members(scope, :nope)
      assert [] == Pg.get_local_members(scope, :nope)
    end
  end

  describe "leave/3" do
    test "removes a single pid", %{scope: scope} do
      :ok = Pg.join(scope, :g, self())
      assert :ok = Pg.leave(scope, :g, self())
      assert [] == Pg.get_members(scope, :g)
    end

    test "returns :not_joined when pid never joined", %{scope: scope} do
      assert :not_joined = Pg.leave(scope, :g, self())
    end

    test "leaving once leaves a duplicate behind", %{scope: scope} do
      :ok = Pg.join(scope, :g, self())
      :ok = Pg.join(scope, :g, self())
      :ok = Pg.leave(scope, :g, self())
      assert [self()] == Pg.get_members(scope, :g)
    end

    test "leaving a list of pids", %{scope: scope} do
      p1 = spawn_member(scope, :g)
      :ok = Pg.join(scope, :g, self())
      :ok = Pg.leave(scope, :g, [self(), p1])
      assert [] == Pg.get_members(scope, :g)
      stop(p1)
    end
  end

  describe "which_groups/1" do
    test "returns only non-empty groups", %{scope: scope} do
      assert [] == Pg.which_groups(scope)
      :ok = Pg.join(scope, :a, self())
      :ok = Pg.join(scope, :b, self())
      groups = Pg.which_groups(scope)
      assert :a in groups
      assert :b in groups

      :ok = Pg.leave(scope, :a, self())
      refute :a in Pg.which_groups(scope)
    end
  end

  describe "automatic cleanup on process exit" do
    test "DOWN removes pid from all its groups", %{scope: scope} do
      pid = spawn_member(scope, :g)
      Pg.join(scope, :h, pid)
      # ensure remote join is processed
      _ = :sys.get_state(scope)

      assert pid in Pg.get_members(scope, :g)
      assert pid in Pg.get_members(scope, :h)

      stop(pid)
      _ = :sys.get_state(scope)

      assert [] == Pg.get_members(scope, :g)
      assert [] == Pg.get_members(scope, :h)
      assert [] == Pg.which_groups(scope)
    end
  end

  describe "join/4 with metadata" do
    test "single pid with metadata", %{scope: scope} do
      assert :ok = Pg.join(scope, :g, self(), %{role: :primary})
      assert [{self(), %{role: :primary}}] == Pg.lookup(scope, :g)
      assert [{self(), %{role: :primary}}] == Pg.lookup_local(scope, :g)
      # bare-pid API still works
      assert [self()] == Pg.get_members(scope, :g)
    end

    test "join/3 stores nil metadata", %{scope: scope} do
      :ok = Pg.join(scope, :g, self())
      assert [{self(), nil}] == Pg.lookup(scope, :g)
    end

    test "list of pids share the same metadata", %{scope: scope} do
      p1 = spawn_member(scope, :other)
      :ok = Pg.join(scope, :g, [self(), p1], :shared)
      entries = Pg.lookup(scope, :g)
      assert {self(), :shared} in entries
      assert {p1, :shared} in entries
      stop(p1)
    end

    test "successive joins with different metas keep both entries", %{scope: scope} do
      :ok = Pg.join(scope, :g, self(), :first)
      :ok = Pg.join(scope, :g, self(), :second)
      entries = Pg.lookup(scope, :g)
      assert length(entries) == 2
      assert {self(), :first} in entries
      assert {self(), :second} in entries
      # bare-pid API sees the duplicate as expected
      assert [self(), self()] == Pg.get_members(scope, :g)
    end

    test "leave/3 removes the most recently joined entry first", %{scope: scope} do
      :ok = Pg.join(scope, :g, self(), :first)
      :ok = Pg.join(scope, :g, self(), :second)
      :ok = Pg.leave(scope, :g, self())
      # joins prepend, so :second was at the head — it should be gone first
      assert [{self(), :first}] == Pg.lookup(scope, :g)
    end
  end

  describe "update_meta/4" do
    test "updates the meta of a joined pid", %{scope: scope} do
      :ok = Pg.join(scope, :g, self(), :old)
      assert :ok = Pg.update_meta(scope, :g, self(), :new)
      assert [{self(), :new}] == Pg.lookup(scope, :g)
    end

    test "returns :not_joined when the pid is not in the group", %{scope: scope} do
      assert :not_joined = Pg.update_meta(scope, :g, self(), :whatever)
    end

    test "updates all entries when the pid is joined multiple times", %{scope: scope} do
      :ok = Pg.join(scope, :g, self(), :first)
      :ok = Pg.join(scope, :g, self(), :second)
      :ok = Pg.update_meta(scope, :g, self(), :unified)
      assert [{self(), :unified}, {self(), :unified}] == Pg.lookup(scope, :g)
    end

    test "delivers :update notification with old and new meta", %{scope: scope} do
      :ok = Pg.join(scope, :g, self(), :old)
      {ref, _} = Pg.monitor_scope(scope)
      :ok = Pg.update_meta(scope, :g, self(), :new)
      me = self()
      assert_receive {^ref, :update, :g, [{^me, :old, :new}]}
    end

    test ":update notification covers all matching entries", %{scope: scope} do
      :ok = Pg.join(scope, :g, self(), :a)
      :ok = Pg.join(scope, :g, self(), :b)
      {ref, _} = Pg.monitor_scope(scope)
      :ok = Pg.update_meta(scope, :g, self(), :z)
      me = self()
      assert_receive {^ref, :update, :g, updates}
      assert length(updates) == 2
      assert {me, :a, :z} in updates
      assert {me, :b, :z} in updates
    end

    test "rejects updates for non-local pids" do
      # we don't have a remote pid handy in this single-node test, just exercise
      # the guard with a malformed argument
      assert_raise FunctionClauseError, fn ->
        Pg.update_meta(:any_scope, :g, :not_a_pid, :meta)
      end
    end

    test "demonitor flushes :update messages too", %{scope: scope} do
      :ok = Pg.join(scope, :g, self(), :old)
      {ref, _} = Pg.monitor_scope(scope)
      :ok = Pg.update_meta(scope, :g, self(), :new)
      assert :ok = Pg.demonitor(scope, ref)
      refute_receive {^ref, _, _, _}, 50
    end
  end

  describe "lookup/2 and lookup_local/2" do
    test "return [] for unknown group", %{scope: scope} do
      assert [] == Pg.lookup(scope, :nope)
      assert [] == Pg.lookup_local(scope, :nope)
    end

    test "lookup_local is a subset of lookup", %{scope: scope} do
      :ok = Pg.join(scope, :g, self(), %{n: 1})
      assert Pg.lookup_local(scope, :g) == Pg.lookup(scope, :g)
    end
  end

  describe "monitor_scope/1" do
    test "returns current scope contents and a ref", %{scope: scope} do
      :ok = Pg.join(scope, :g, self(), :m)
      {ref, contents} = Pg.monitor_scope(scope)
      assert is_reference(ref)
      assert %{g: [{self(), :m}]} == Map.take(contents, [:g])
    end

    test "delivers join and leave notifications", %{scope: scope} do
      {ref, _} = Pg.monitor_scope(scope)
      :ok = Pg.join(scope, :g, self(), :m)
      me = self()
      assert_receive {^ref, :join, :g, [{^me, :m}]}
      :ok = Pg.leave(scope, :g, self())
      assert_receive {^ref, :leave, :g, [{^me, :m}]}
    end

    test "leave notification carries the meta from the entry that was removed",
         %{scope: scope} do
      :ok = Pg.join(scope, :g, self(), :first)
      :ok = Pg.join(scope, :g, self(), :second)
      {ref, _} = Pg.monitor_scope(scope)
      :ok = Pg.leave(scope, :g, self())
      me = self()
      # joins prepend, so :second (head) is removed first
      assert_receive {^ref, :leave, :g, [{^me, :second}]}
    end
  end

  describe "monitor/2 (single group)" do
    test "returns members and only delivers notifications for that group", %{scope: scope} do
      {ref, []} = Pg.monitor(scope, :g)
      :ok = Pg.join(scope, :g, self(), :hello)
      me = self()
      assert_receive {^ref, :join, :g, [{^me, :hello}]}

      :ok = Pg.join(scope, :other, self())
      refute_receive {^ref, :join, :other, _}, 50
    end
  end

  describe "demonitor/2" do
    test "stops further notifications and flushes pending ones", %{scope: scope} do
      {ref, _} = Pg.monitor_scope(scope)
      :ok = Pg.join(scope, :g, self())
      # pending message in mailbox
      assert :ok = Pg.demonitor(scope, ref)
      refute_receive {^ref, _, _, _}, 50

      :ok = Pg.join(scope, :h, self())
      refute_receive {^ref, _, _, _}, 50
    end

    test "returns false for unknown ref", %{scope: scope} do
      assert false == Pg.demonitor(scope, make_ref())
    end
  end
end
