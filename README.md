# PgRegistry

A distributed process registry backed by Erlang's `:pg` module. Works like Elixir's `Registry` but discovers processes across clusters.

## Installation

Add `pg_registry` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pg_registry, "~> 0.1.0"}
  ]
end
```

## Usage

Add `PgRegistry` to your supervision tree:

```elixir
children = [
  {PgRegistry, :my_registry}
]
```

Register processes using the `:via` tuple:

```elixir
GenServer.start_link(MyServer, arg, name: {:via, PgRegistry, {:my_registry, :my_key}})
```

Look up processes across the cluster:

```elixir
PgRegistry.whereis_name({:my_registry, :my_key})
```

## How it works

PgRegistry uses Erlang's `:pg` module under the hood. When nodes connect, `:pg` automatically syncs process group memberships across the cluster, making registered processes discoverable from any node.

## License

MIT - see [LICENSE](LICENSE).
