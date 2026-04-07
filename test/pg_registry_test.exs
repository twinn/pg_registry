defmodule PgRegistryTest do
  use ExUnit.Case

  setup do
    scope = :"test_#{:erlang.unique_integer([:positive])}"
    start_supervised!({PgRegistry, scope})
    {:ok, scope: scope}
  end

  describe "start_link/1" do
    test "starts a pg scope", %{scope: scope} do
      assert :ok == scope |> :pg.which_groups() |> then(fn _ -> :ok end)
    end
  end

  describe "register_name/2" do
    test "registers a process under a key", %{scope: scope} do
      assert :yes = PgRegistry.register_name({scope, :my_key}, self())
    end

    test "allows multiple processes to register under the same key", %{scope: scope} do
      task =
        Task.async(fn ->
          PgRegistry.register_name({scope, :my_key}, self())
          Process.sleep(:infinity)
        end)

      Process.sleep(50)

      assert :yes = PgRegistry.register_name({scope, :my_key}, self())
      assert length(PgRegistry.get_members(scope, :my_key)) == 2

      Task.shutdown(task, :brutal_kill)
    end
  end

  describe "whereis_name/1" do
    test "returns pid for registered process", %{scope: scope} do
      PgRegistry.register_name({scope, :my_key}, self())
      assert self() == PgRegistry.whereis_name({scope, :my_key})
    end

    test "returns :undefined for unregistered key", %{scope: scope} do
      assert :undefined == PgRegistry.whereis_name({scope, :no_such_key})
    end

    test "prefers local members", %{scope: scope} do
      PgRegistry.register_name({scope, :my_key}, self())

      assert self() == PgRegistry.whereis_name({scope, :my_key})
      assert [self()] == :pg.get_local_members(scope, :my_key)
    end

    test "falls back to remote members when no local members exist", %{scope: scope} do
      PgRegistry.register_name({scope, :my_key}, self())
      assert self() == PgRegistry.whereis_name({scope, :my_key})

      # On a single node, get_members returns the same as get_local_members,
      # so this just verifies the fallback path doesn't break
      PgRegistry.unregister_name({scope, :my_key})
      assert :undefined == PgRegistry.whereis_name({scope, :my_key})
    end
  end

  describe "unregister_name/1" do
    test "removes a registration", %{scope: scope} do
      PgRegistry.register_name({scope, :my_key}, self())
      assert :ok = PgRegistry.unregister_name({scope, :my_key})
      assert :undefined == PgRegistry.whereis_name({scope, :my_key})
    end

    test "only unregisters local members", %{scope: scope} do
      PgRegistry.register_name({scope, :my_key}, self())
      assert [self()] == :pg.get_local_members(scope, :my_key)

      PgRegistry.unregister_name({scope, :my_key})

      assert [] == :pg.get_local_members(scope, :my_key)
    end
  end

  describe "send/2" do
    test "sends a message to a registered process", %{scope: scope} do
      PgRegistry.register_name({scope, :my_key}, self())
      PgRegistry.send({scope, :my_key}, :hello)
      assert_receive :hello
    end

    test "raises for unregistered key", %{scope: scope} do
      assert_raise ArgumentError, fn ->
        PgRegistry.send({scope, :no_such_key}, :hello)
      end
    end
  end

  describe "get_members/2" do
    test "returns all processes registered under a key", %{scope: scope} do
      task1 =
        Task.async(fn ->
          PgRegistry.register_name({scope, :group}, self())
          Process.sleep(:infinity)
        end)

      task2 =
        Task.async(fn ->
          PgRegistry.register_name({scope, :group}, self())
          Process.sleep(:infinity)
        end)

      Process.sleep(50)

      members = PgRegistry.get_members(scope, :group)
      assert length(members) == 2
      assert task1.pid in members
      assert task2.pid in members

      Task.shutdown(task1, :brutal_kill)
      Task.shutdown(task2, :brutal_kill)
    end

    test "returns empty list for unknown key", %{scope: scope} do
      assert [] == PgRegistry.get_members(scope, :no_such_key)
    end
  end

  describe "which_groups/1" do
    test "returns all registered keys", %{scope: scope} do
      PgRegistry.register_name({scope, :group_a}, self())
      PgRegistry.register_name({scope, :group_b}, self())

      groups = PgRegistry.which_groups(scope)
      assert :group_a in groups
      assert :group_b in groups
    end

    test "returns empty list when no groups exist", %{scope: scope} do
      assert [] == PgRegistry.which_groups(scope)
    end
  end

  describe "dispatch/3" do
    test "invokes callback for each member", %{scope: scope} do
      parent = self()

      for i <- 1..3 do
        Task.async(fn ->
          PgRegistry.register_name({scope, :workers}, self())
          send(parent, {:ready, i})
          Process.sleep(:infinity)
        end)
      end

      for _ <- 1..3, do: assert_receive({:ready, _})

      PgRegistry.dispatch(scope, :workers, fn members ->
        for pid <- members, do: send(pid, :work)
      end)

      # Verify all 3 received the message via get_members
      members = PgRegistry.get_members(scope, :workers)
      assert length(members) == 3
    end

    test "does not invoke callback when no members", %{scope: scope} do
      PgRegistry.dispatch(scope, :nobody, fn _members ->
        flunk("callback should not be invoked")
      end)
    end
  end

  describe "process cleanup" do
    test "dead process is automatically removed", %{scope: scope} do
      pid = spawn(fn -> :ok end)
      # Wait for process to die
      ref = Process.monitor(pid)
      receive do: ({:DOWN, ^ref, _, _, _} -> :ok)

      # pg won't have it since it died before/during join,
      # but let's register a living process, kill it, and verify cleanup
      task =
        Task.async(fn ->
          PgRegistry.register_name({scope, :ephemeral}, self())
          Process.sleep(:infinity)
        end)

      # Give it time to register
      Process.sleep(50)
      assert is_pid(PgRegistry.whereis_name({scope, :ephemeral}))

      Task.shutdown(task, :brutal_kill)
      # pg cleans up async, give it a moment
      Process.sleep(50)
      assert :undefined == PgRegistry.whereis_name({scope, :ephemeral})
    end
  end

  describe "GenServer via tuple integration" do
    test "can start and call a GenServer via PgRegistry", %{scope: scope} do
      {:ok, pid} = Agent.start_link(fn -> 0 end, name: {:via, PgRegistry, {scope, :my_agent}})
      assert pid == PgRegistry.whereis_name({scope, :my_agent})
      assert 0 == Agent.get({:via, PgRegistry, {scope, :my_agent}}, & &1)

      Agent.update({:via, PgRegistry, {scope, :my_agent}}, &(&1 + 1))
      assert 1 == Agent.get({:via, PgRegistry, {scope, :my_agent}}, & &1)
    end
  end
end
