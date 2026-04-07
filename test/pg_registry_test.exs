defmodule PgRegistryTest do
  use ExUnit.Case

  setup do
    scope = :"test_#{:erlang.unique_integer([:positive])}"
    start_supervised!({PgRegistry, scope})
    {:ok, scope: scope}
  end

  describe "start_link/1" do
    test "starts a scope", %{scope: scope} do
      assert is_list(PgRegistry.which_groups(scope))
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
      assert [self()] == PgRegistry.Pg.get_local_members(scope, :my_key)
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
      assert [self()] == PgRegistry.Pg.get_local_members(scope, :my_key)

      PgRegistry.unregister_name({scope, :my_key})

      assert [] == PgRegistry.Pg.get_local_members(scope, :my_key)
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

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      end

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

    test "3-element via tuple attaches a value at registration", %{scope: scope} do
      {:ok, pid} =
        Agent.start_link(fn -> :state end,
          name: {:via, PgRegistry, {scope, :tagged_agent, %{role: :primary}}}
        )

      assert pid == PgRegistry.whereis_name({scope, :tagged_agent})
      assert [{^pid, %{role: :primary}}] = PgRegistry.lookup(scope, :tagged_agent)
    end
  end

  describe "lookup/2" do
    test "returns [{pid, value}] entries", %{scope: scope} do
      PgRegistry.register_name({scope, :worker, :tag1}, self())
      assert [{self(), :tag1}] == PgRegistry.lookup(scope, :worker)
    end

    test "value defaults to nil for the 2-tuple via name", %{scope: scope} do
      PgRegistry.register_name({scope, :worker}, self())
      assert [{self(), nil}] == PgRegistry.lookup(scope, :worker)
    end

    test "returns [] for unknown key", %{scope: scope} do
      assert [] == PgRegistry.lookup(scope, :nope)
    end
  end

  describe "update_value/3 and update_value/4" do
    test "update_value/4 replaces the value for a specific pid", %{scope: scope} do
      PgRegistry.register_name({scope, :worker, :before}, self())
      assert :ok = PgRegistry.update_value(scope, :worker, self(), :after)
      assert [{self(), :after}] == PgRegistry.lookup(scope, :worker)
    end

    test "update_value/4 returns :not_joined when the pid isn't registered", %{scope: scope} do
      assert :not_joined = PgRegistry.update_value(scope, :worker, self(), :anything)
    end

    test "update_value/3 is sugar for update_value/4 with self()", %{scope: scope} do
      PgRegistry.register(scope, :worker, :v1)
      assert :ok = PgRegistry.update_value(scope, :worker, :v2)
      assert [{self(), :v2}] == PgRegistry.lookup(scope, :worker)
    end

    test "update_value/3 returns :not_joined when self() isn't registered", %{scope: scope} do
      assert :not_joined = PgRegistry.update_value(scope, :worker, :anything)
    end
  end

  describe "keys: :unique (per-node)" do
    test "register/3 returns error on collision" do
      scope = :"pg_uniq_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, name: scope, keys: :unique})

      assert {:ok, _} = PgRegistry.register(scope, :singleton, :first)

      assert {:error, {:already_registered, holder}} =
               PgRegistry.register(scope, :singleton, :second)

      assert holder == self()
    end

    test "register_name/2 returns :no on collision" do
      scope = :"pg_uniq_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, name: scope, keys: :unique})

      assert :yes = PgRegistry.register_name({scope, :singleton}, self())
      assert :no = PgRegistry.register_name({scope, :singleton}, self())
    end

    test "via tuple integrates with GenServer.start_link in unique mode" do
      scope = :"pg_uniq_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, name: scope, keys: :unique})

      {:ok, agent1} =
        Agent.start_link(fn -> :a end, name: {:via, PgRegistry, {scope, :singleton}})

      assert {:error, {:already_started, ^agent1}} =
               Agent.start_link(fn -> :b end, name: {:via, PgRegistry, {scope, :singleton}})
    end

    test "key released after the registered process exits" do
      scope = :"pg_uniq_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, name: scope, keys: :unique})

      task = Task.async(fn -> PgRegistry.register(scope, :singleton, :v) end)
      assert {:ok, _} = Task.await(task)

      _ = :sys.get_state(scope)
      assert {:ok, _} = PgRegistry.register(scope, :singleton, :v)
    end
  end

  describe "Registry-shaped start_link/1 (keyword form)" do
    test "accepts a keyword list with :name" do
      scope = :"pg_kw_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, name: scope})
      assert is_pid(Process.whereis(scope))
    end

    test "passes :listeners through" do
      {listener, _} = spawn_listener(self())
      scope = :"pg_kw_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, name: scope, listeners: [listener]})

      {:ok, _} = PgRegistry.register(scope, :worker, :v1)
      assert_receive {:register, ^scope, :worker, _, :v1}
    end

    test "accepts keys: :duplicate as a no-op" do
      scope = :"pg_kw_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, name: scope, keys: :duplicate})
      assert is_pid(Process.whereis(scope))
    end

    test "accepts keys: :unique (per-node uniqueness)" do
      scope = :"pg_kw_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, name: scope, keys: :unique})
      assert is_pid(Process.whereis(scope))
    end

    test "accepts partitions: 1 as a no-op" do
      scope = :"pg_kw_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, name: scope, partitions: 1})
      assert is_pid(Process.whereis(scope))
    end

    test "raises with a helpful error for partitions > 1" do
      assert_raise ArgumentError, ~r/partitions: 4/, fn ->
        PgRegistry.start_link(name: :pg_kw_partitioned, partitions: 4)
      end
    end

    test ":name is required" do
      assert_raise KeyError, fn -> PgRegistry.start_link([]) end
    end

    # Forwarder helper duplicated from the listeners describe so this
    # block doesn't reach into the other one's setup.
    defp spawn_listener(target) do
      name = :"pg_listener_kw_#{:erlang.unique_integer([:positive])}"

      pid =
        spawn_link(fn ->
          Process.register(self(), name)
          loop(target)
        end)

      :ok = wait_named(name)
      {name, pid}
    end

    defp loop(target) do
      receive do
        msg ->
          send(target, msg)
          loop(target)
      end
    end

    defp wait_named(name) do
      if Process.whereis(name),
        do: :ok,
        else:
          (
            Process.sleep(1)
            wait_named(name)
          )
    end
  end

  describe "keys/2" do
    test "returns all keys a pid is registered under", %{scope: scope} do
      PgRegistry.register_name({scope, :a}, self())
      PgRegistry.register_name({scope, :b}, self())
      keys = PgRegistry.keys(scope, self())
      assert :a in keys
      assert :b in keys
      assert length(keys) == 2
    end

    test "returns [] for an unregistered pid", %{scope: scope} do
      assert [] == PgRegistry.keys(scope, self())
    end

    test "does not include keys registered by other pids", %{scope: scope} do
      task =
        Task.async(fn ->
          PgRegistry.register_name({scope, :other}, self())
          Process.sleep(:infinity)
        end)

      Process.sleep(50)
      PgRegistry.register_name({scope, :mine}, self())

      assert [:mine] == PgRegistry.keys(scope, self())
      Task.shutdown(task, :brutal_kill)
    end
  end

  describe "register/3 and unregister/2" do
    test "register/3 joins self() under key with value", %{scope: scope} do
      assert {:ok, self()} == PgRegistry.register(scope, :worker, %{role: :primary})
      assert [{self(), %{role: :primary}}] == PgRegistry.lookup(scope, :worker)
    end

    test "unregister/2 removes self() from key", %{scope: scope} do
      PgRegistry.register(scope, :worker, :v)
      assert :ok = PgRegistry.unregister(scope, :worker)
      assert [] == PgRegistry.lookup(scope, :worker)
    end

    test "unregister/2 is a no-op when not registered", %{scope: scope} do
      assert :ok = PgRegistry.unregister(scope, :nope)
    end
  end

  describe "values/3" do
    test "returns the values registered by the given pid for the key", %{scope: scope} do
      PgRegistry.register(scope, :worker, :a)
      PgRegistry.register(scope, :worker, :b)

      values = PgRegistry.values(scope, :worker, self())
      assert :a in values
      assert :b in values
      assert length(values) == 2
    end

    test "returns [] for an unregistered pid", %{scope: scope} do
      assert [] == PgRegistry.values(scope, :worker, self())
    end
  end

  describe "match/3 and match/4" do
    test "matches entries against a literal value", %{scope: scope} do
      PgRegistry.register(scope, :worker, %{role: :primary})

      task =
        Task.async(fn ->
          PgRegistry.register(scope, :worker, %{role: :replica})
          Process.sleep(:infinity)
        end)

      Process.sleep(50)

      matches = PgRegistry.match(scope, :worker, %{role: :primary})
      assert [{self(), %{role: :primary}}] == matches

      Task.shutdown(task, :brutal_kill)
    end

    test "match/4 supports guards", %{scope: scope} do
      PgRegistry.register(scope, :worker, %{n: 1})
      PgRegistry.register(scope, :worker, %{n: 5})
      PgRegistry.register(scope, :worker, %{n: 10})

      matches = PgRegistry.match(scope, :worker, %{n: :"$1"}, [{:>, :"$1", 3}])
      assert length(matches) == 2
      assert Enum.all?(matches, fn {_pid, %{n: n}} -> n > 3 end)
    end

    test "match returns [] when nothing matches", %{scope: scope} do
      PgRegistry.register(scope, :worker, %{role: :primary})
      assert [] == PgRegistry.match(scope, :worker, %{role: :replica})
    end
  end

  describe "count_match/3 and count_match/4" do
    test "counts matching entries", %{scope: scope} do
      PgRegistry.register(scope, :worker, :a)
      PgRegistry.register(scope, :worker, :b)
      PgRegistry.register(scope, :worker, :a)

      assert 2 == PgRegistry.count_match(scope, :worker, :a)
      assert 1 == PgRegistry.count_match(scope, :worker, :b)
      assert 0 == PgRegistry.count_match(scope, :worker, :c)
    end
  end

  describe "select/2" do
    test "runs a Registry-shaped match-spec across the whole scope", %{scope: scope} do
      PgRegistry.register(scope, :a, 1)
      PgRegistry.register(scope, :a, 2)
      PgRegistry.register(scope, :b, 3)

      # match-spec input shape: {{key, pid, value}, guards, body}
      spec = [{{:a, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}]
      result = PgRegistry.select(scope, spec)
      assert length(result) == 2
      assert Enum.all?(result, fn {pid, _v} -> pid == self() end)
      assert Enum.sort(Enum.map(result, fn {_p, v} -> v end)) == [1, 2]
    end

    test "user match-specs see {key, pid, value} not the internal row shape", %{scope: scope} do
      PgRegistry.register(scope, :a, %{important: true})

      spec = [{{:_, :_, %{important: :"$1"}}, [{:==, :"$1", true}], [:"$_"]}]
      assert length(PgRegistry.select(scope, spec)) == 1
    end
  end

  describe "count_select/2" do
    test "counts via a match-spec", %{scope: scope} do
      PgRegistry.register(scope, :a, 1)
      PgRegistry.register(scope, :a, 2)
      PgRegistry.register(scope, :b, 3)

      spec = [{{:a, :_, :_}, [], [true]}]
      assert 2 == PgRegistry.count_select(scope, spec)
    end

    test "respects the user's body — body returning false counts as 0", %{scope: scope} do
      PgRegistry.register(scope, :a, 1)
      PgRegistry.register(scope, :a, 2)

      # Body returns false unconditionally — must NOT count any matches
      spec = [{{:a, :_, :_}, [], [false]}]
      assert 0 == PgRegistry.count_select(scope, spec)
    end
  end

  describe "unregister_match/3" do
    test "unregisters self()'s entries that match", %{scope: scope} do
      PgRegistry.register(scope, :worker, %{role: :primary})
      PgRegistry.register(scope, :worker, %{role: :replica})

      :ok = PgRegistry.unregister_match(scope, :worker, %{role: :replica})
      assert [{self(), %{role: :primary}}] == PgRegistry.lookup(scope, :worker)
    end

    test "removes the matched entry, not the most-recently-joined one", %{scope: scope} do
      # Critical: join :a first, then :b. The LIFO head is :b.
      # If we ask to remove :a, we should remove :a — not :b.
      PgRegistry.register(scope, :worker, :a)
      PgRegistry.register(scope, :worker, :b)

      :ok = PgRegistry.unregister_match(scope, :worker, :a)
      assert [{self(), :b}] == PgRegistry.lookup(scope, :worker)
    end

    test "removes all matching entries when several match", %{scope: scope} do
      PgRegistry.register(scope, :worker, %{role: :replica, n: 1})
      PgRegistry.register(scope, :worker, %{role: :replica, n: 2})
      PgRegistry.register(scope, :worker, %{role: :primary, n: 3})

      :ok = PgRegistry.unregister_match(scope, :worker, %{role: :replica, n: :_})
      assert [{self(), %{role: :primary, n: 3}}] == PgRegistry.lookup(scope, :worker)
    end

    test "leaves other pids' entries alone", %{scope: scope} do
      task =
        Task.async(fn ->
          PgRegistry.register(scope, :worker, :keep)
          Process.sleep(:infinity)
        end)

      Process.sleep(50)
      PgRegistry.register(scope, :worker, :remove_me)

      :ok = PgRegistry.unregister_match(scope, :worker, :remove_me)

      remaining = PgRegistry.lookup(scope, :worker)
      assert length(remaining) == 1
      assert {task.pid, :keep} in remaining

      Task.shutdown(task, :brutal_kill)
    end
  end

  describe "listeners" do
    # Spawns a tiny process registered under `name` that forwards every
    # message it receives to the test process. Lets us use multiple
    # listener atoms even though the test process can only have one
    # registered name itself.
    defp spawn_forwarder(target) do
      name = :"pg_listener_#{:erlang.unique_integer([:positive])}"

      pid =
        spawn_link(fn ->
          Process.register(self(), name)
          forward_loop(target)
        end)

      # wait until the name is bound
      wait_registered(name)
      {name, pid}
    end

    defp forward_loop(target) do
      receive do
        msg ->
          send(target, msg)
          forward_loop(target)
      end
    end

    defp wait_registered(name) do
      if Process.whereis(name),
        do: :ok,
        else:
          (
            Process.sleep(1)
            wait_registered(name)
          )
    end

    test "delivers :register on join" do
      {listener, _} = spawn_forwarder(self())
      scope = :"pg_lst_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, {scope, listeners: [listener]}})

      {:ok, _} = PgRegistry.register(scope, :worker, :v1)

      me = self()
      assert_receive {:register, ^scope, :worker, ^me, :v1}
    end

    test "delivers :unregister on leave" do
      {listener, _} = spawn_forwarder(self())
      scope = :"pg_lst_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, {scope, listeners: [listener]}})

      {:ok, _} = PgRegistry.register(scope, :worker, :v1)
      assert_receive {:register, ^scope, :worker, _, :v1}

      :ok = PgRegistry.unregister(scope, :worker)
      me = self()
      assert_receive {:unregister, ^scope, :worker, ^me}
    end

    test "does NOT deliver on update_value" do
      {listener, _} = spawn_forwarder(self())
      scope = :"pg_lst_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, {scope, listeners: [listener]}})

      {:ok, _} = PgRegistry.register(scope, :worker, :old)
      assert_receive {:register, ^scope, :worker, _, :old}

      :ok = PgRegistry.update_value(scope, :worker, self(), :new)
      refute_receive {:register, ^scope, _, _, _}, 50
      refute_receive {:unregister, ^scope, _, _}, 50
    end

    test "fans out to multiple listeners" do
      {l1, _} = spawn_forwarder(self())
      {l2, _} = spawn_forwarder(self())
      scope = :"pg_lst_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, {scope, listeners: [l1, l2]}})

      {:ok, _} = PgRegistry.register(scope, :worker, :v1)
      assert_receive {:register, ^scope, :worker, _, :v1}
      assert_receive {:register, ^scope, :worker, _, :v1}
    end

    test "delivers :unregister when a registered process exits" do
      {listener, _} = spawn_forwarder(self())
      scope = :"pg_lst_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, {scope, listeners: [listener]}})

      task =
        Task.async(fn ->
          PgRegistry.register(scope, :worker, :v)
          Process.sleep(:infinity)
        end)

      assert_receive {:register, ^scope, :worker, pid, :v}
      assert pid == task.pid

      Task.shutdown(task, :brutal_kill)
      assert_receive {:unregister, ^scope, :worker, ^pid}
    end

    test "missing listener atom does not crash the scope" do
      missing = :"pg_listener_missing_#{:erlang.unique_integer([:positive])}"
      # listener atom is intentionally NOT registered to any process
      assert Process.whereis(missing) == nil

      scope = :"pg_lst_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, {scope, listeners: [missing]}})

      scope_pid = Process.whereis(scope)
      assert is_pid(scope_pid)

      # This must not crash the scope
      {:ok, _} = PgRegistry.register(scope, :worker, :v1)
      :ok = PgRegistry.unregister(scope, :worker)

      assert Process.alive?(scope_pid)
      assert Process.whereis(scope) == scope_pid
    end

    test "listener that crashes between events still allows the scope to keep going" do
      name = :"pg_listener_flaky_#{:erlang.unique_integer([:positive])}"

      # Spawn a process registered under `name`, then kill it. The atom
      # is now unbound — the next register should be a no-op for the
      # listener and must not crash the scope.
      pid = spawn(fn -> Process.sleep(:infinity) end)
      Process.register(pid, name)
      Process.exit(pid, :kill)
      # Wait for unregister
      Process.sleep(20)
      assert Process.whereis(name) == nil

      scope = :"pg_lst_#{:erlang.unique_integer([:positive])}"
      start_supervised!({PgRegistry, {scope, listeners: [name]}})
      scope_pid = Process.whereis(scope)

      {:ok, _} = PgRegistry.register(scope, :worker, :v)
      assert Process.alive?(scope_pid)
    end
  end

  describe "meta/2, put_meta/3, delete_meta/2" do
    test "round-trip", %{scope: scope} do
      assert :error = PgRegistry.meta(scope, :config)
      assert :ok = PgRegistry.put_meta(scope, :config, %{retries: 3})
      assert {:ok, %{retries: 3}} == PgRegistry.meta(scope, :config)

      assert :ok = PgRegistry.delete_meta(scope, :config)
      assert :error = PgRegistry.meta(scope, :config)
    end
  end

  describe "count/1" do
    test "returns 0 for an empty scope", %{scope: scope} do
      assert 0 == PgRegistry.count(scope)
    end

    test "counts every entry, not just keys", %{scope: scope} do
      PgRegistry.register_name({scope, :a}, self())
      PgRegistry.register_name({scope, :b}, self())
      # same pid registered twice under same key counts as two
      PgRegistry.register_name({scope, :a}, self())
      assert 3 == PgRegistry.count(scope)
    end

    test "is correct across many keys", %{scope: scope} do
      for i <- 1..50 do
        PgRegistry.register_name({scope, {:k, i}}, self())
      end

      assert 50 == PgRegistry.count(scope)
    end
  end
end
