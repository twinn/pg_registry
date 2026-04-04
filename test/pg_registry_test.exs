defmodule PgRegistryTest do
  use ExUnit.Case

  setup do
    scope = :"test_#{:erlang.unique_integer([:positive])}"
    start_supervised!({PgRegistry, scope})
    {:ok, scope: scope}
  end

  describe "start_link/1" do
    test "starts a pg scope", %{scope: scope} do
      assert :ok == :pg.which_groups(scope) |> then(fn _ -> :ok end)
    end
  end

  describe "register_name/2" do
    test "registers a process under a key", %{scope: scope} do
      assert :yes = PgRegistry.register_name({scope, :my_key}, self())
    end

    test "returns :no for duplicate registration", %{scope: scope} do
      assert :yes = PgRegistry.register_name({scope, :my_key}, self())
      assert :no = PgRegistry.register_name({scope, :my_key}, self())
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
  end

  describe "unregister_name/1" do
    test "removes a registration", %{scope: scope} do
      PgRegistry.register_name({scope, :my_key}, self())
      assert :ok = PgRegistry.unregister_name({scope, :my_key})
      assert :undefined == PgRegistry.whereis_name({scope, :my_key})
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
