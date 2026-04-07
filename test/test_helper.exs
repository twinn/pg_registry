unless Node.alive?() do
  # Make sure epmd is running before starting distribution.
  System.cmd("epmd", ["-daemon"])
  {:ok, _} = Node.start(:pg_test, :shortnames)
end

ExUnit.start()
