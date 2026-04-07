defmodule PgRegistry.Pg.TestHelper do
  @moduledoc false
  # Lives in test/support so that the compiled beam ends up in the
  # standard test ebin path. That makes it loadable on a peer node
  # via :code.add_paths(:code.get_path()), which test modules themselves
  # are not, since their beams are not on disk.

  alias PgRegistry.Pg

  def member_loop(reply_to, scope, group) do
    :ok = Pg.join(scope, group, self())
    send(reply_to, {:joined, self()})
    receive do: (:stop -> :ok)
  end
end
