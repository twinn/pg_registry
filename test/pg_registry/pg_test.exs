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

  describe "monitor_scope/1" do
    test "returns current scope contents and a ref", %{scope: scope} do
      :ok = Pg.join(scope, :g, self())
      {ref, contents} = Pg.monitor_scope(scope)
      assert is_reference(ref)
      assert %{g: [pid]} = contents
      assert pid == self()
    end

    test "delivers join and leave notifications", %{scope: scope} do
      {ref, _} = Pg.monitor_scope(scope)
      :ok = Pg.join(scope, :g, self())
      assert_receive {^ref, :join, :g, [pid]} when pid == self()
      :ok = Pg.leave(scope, :g, self())
      assert_receive {^ref, :leave, :g, [pid]} when pid == self()
    end
  end

  describe "monitor/2 (single group)" do
    test "returns members and only delivers notifications for that group", %{scope: scope} do
      {ref, []} = Pg.monitor(scope, :g)
      :ok = Pg.join(scope, :g, self())
      assert_receive {^ref, :join, :g, [pid]} when pid == self()

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
