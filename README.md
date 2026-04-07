# PgRegistry

A distributed, metadata-aware process registry for Elixir. Works like
Elixir's [`Registry`](https://hexdocs.pm/elixir/Registry.html) but
discovers processes across a cluster, with the same gossip-based
eventually-consistent membership model as Erlang's `:pg`.

PgRegistry exposes a Registry-shaped API on top of a self-contained
Elixir port of `:pg` that has been extended to carry per-entry
metadata. You get cluster-wide process discovery, per-process values,
listener notifications, and ETS-native match-spec queries — all
without `:global`'s coordination tax.

## Installation

```elixir
def deps do
  [
    {:pg_registry, "~> 0.3"}
  ]
end
```

## Quick start

```elixir
# In your supervision tree
children = [
  {PgRegistry, :my_registry}
]

# Register a process by name (via tuple)
GenServer.start_link(MyServer, arg,
  name: {:via, PgRegistry, {:my_registry, :my_key}})

# Or register the calling process directly
{:ok, _} = PgRegistry.register(:my_registry, :worker, %{role: :primary})

# Look up across the cluster
PgRegistry.lookup(:my_registry, :worker)
#=> [{#PID<0.123.0>, %{role: :primary}}]

PgRegistry.whereis_name({:my_registry, :my_key})
#=> #PID<0.456.0>
```

## Why PgRegistry

| | `Registry` | `:global` | `PgRegistry` |
|---|---|---|---|
| Scope | one node | whole cluster | whole cluster |
| Cost per register | µs | ms (cluster-wide lock) | µs (async gossip per peer) |
| Convergence model | n/a | synchronous, lock-based | eventual, gossip-based |
| Net-split behavior | n/a | collisions on heal resolved by user-supplied resolver, may kill processes | diverges silently, converges on heal without conflict |
| Per-process values | yes | no | yes |
| Match-spec queries | yes (ETS-native) | no | yes (ETS-native) |
| Listeners | yes | no | yes |
| Unique key mode | yes (per-node) | yes (cluster-wide, expensive) | yes (per-node only) |

`Registry` is fast but local-only. `:global` is cluster-wide but
synchronous and famously slow. PgRegistry sits in a third spot:
**cluster-wide, lock-free, fast, with no consensus tax** — at the
cost of allowing duplicate registrations (multiple processes per
key, including across nodes).

## API

### Configuration

Three start-link forms are accepted:

```elixir
# Bare scope name
{PgRegistry, :my_registry}

# Scope + opts
{PgRegistry, {:my_registry, listeners: [MyListener]}}

# Registry-shaped keyword form
{PgRegistry, name: :my_registry, listeners: [MyListener], keys: :duplicate}
```

Supported options:

- `:listeners` — list of registered process names that receive
  `{:register, scope, key, pid, value}` and
  `{:unregister, scope, key, pid}` messages on join/leave events
- `:keys` — `:duplicate` (default) or `:unique`. `:unique` enforces
  per-node uniqueness only; see [Per-node uniqueness](#per-node-uniqueness)
  below
- `:partitions` — `1` (default, no-op). Anything greater raises; see
  [Partitions](#partitions) below

### Registering processes

```elixir
# via the :via tuple (compatible with GenServer/Agent/Task names)
{:via, PgRegistry, {scope, key}}                # value defaults to nil
{:via, PgRegistry, {scope, key, value}}         # 3-tuple attaches a value

# via the Registry-shaped API (registers self())
PgRegistry.register(scope, key, value)          #=> {:ok, self()}
PgRegistry.unregister(scope, key)               #=> :ok

# via the explicit-pid API
PgRegistry.register_name({scope, key}, pid)
PgRegistry.register_name({scope, key, value}, pid)
PgRegistry.unregister_name({scope, key})
```

A process may register multiple times under the same key (with
possibly different values). Each registration is independent and must
be unregistered separately. When a registered process exits, all of
its entries are automatically removed and listeners/subscribers are
notified.

### Reading

```elixir
PgRegistry.lookup(scope, key)              # [{pid, value}, ...]
PgRegistry.whereis_name({scope, key})      # pid | :undefined
PgRegistry.get_members(scope, key)         # [pid, ...] (cluster-wide)
PgRegistry.get_local_members(scope, key)   # [pid, ...] (local node only)
PgRegistry.values(scope, key, pid)         # [value, ...] for one pid
PgRegistry.keys(scope, pid)                # [key, ...] for one pid
PgRegistry.which_groups(scope)             # [key, ...]
PgRegistry.count(scope)                    # total entries
```

All read functions are lock-free, performed directly against ETS from
the calling process. They never block on the GenServer.

### Updating values

```elixir
PgRegistry.update_value(scope, key, new_value)        # self()
PgRegistry.update_value(scope, key, pid, new_value)   # specific pid
```

Updates every entry under `key` whose pid matches. Returns
`:not_joined` if there's nothing to update. Subscribers (see below)
receive `{ref, :update, key, [{pid, old, new}]}` events; listeners do
not — matching `Registry`'s behavior.

### Match-spec queries

```elixir
PgRegistry.match(scope, key, pattern)
PgRegistry.match(scope, key, pattern, guards)
PgRegistry.count_match(scope, key, pattern)
PgRegistry.count_match(scope, key, pattern, guards)
PgRegistry.unregister_match(scope, key, pattern)
PgRegistry.unregister_match(scope, key, pattern, guards)

PgRegistry.select(scope, match_spec)        # returns user-defined results
PgRegistry.count_select(scope, match_spec)
```

`match/3,4` matches against the value position. `select/2` takes a
full ETS match-spec whose patterns are shaped as `{key, pid, value}`
(matching `Registry.select/2`). All of these run as native ETS queries
against the underlying table.

### Subscriptions and listeners

Two ways to react to scope changes:

**Listeners** are configured at scope start-up and receive raw
messages. Same shape as `Registry`'s listeners:

```elixir
{PgRegistry, name: :my_registry, listeners: [MyListener]}

# MyListener receives:
{:register,   :my_registry, key, pid, value}
{:unregister, :my_registry, key, pid}
```

Addressed by registered name (atom), so a listener that crashes and
restarts under the same name keeps receiving events. Listeners do
**not** fire on `update_value` (matching `Registry`).

**Runtime subscriptions** are dynamic and use refs. They also fire
`:update` events:

```elixir
{ref, snapshot} = PgRegistry.Pg.monitor_scope(:my_registry)
# snapshot :: %{key => [{pid, value}, ...]}

# Subscriber receives:
{^ref, :join,   key, [{pid, value}, ...]}
{^ref, :leave,  key, [{pid, value}, ...]}
{^ref, :update, key, [{pid, old, new}, ...]}

PgRegistry.Pg.demonitor(:my_registry, ref)
```

Use listeners for fixed system-level integrations (logging, metrics,
side effects on register/unregister). Use subscriptions for
short-lived consumers that come and go.

### Scope-level metadata

```elixir
PgRegistry.put_meta(scope, :config, %{retries: 3})
PgRegistry.meta(scope, :config)        #=> {:ok, %{retries: 3}}
PgRegistry.delete_meta(scope, :config)
```

Local-only — scope metadata is *not* gossiped between nodes. Stored
in a sibling ETS table for fast reads.

### Dispatch

```elixir
PgRegistry.dispatch(scope, key, fn members ->
  for pid <- members, do: send(pid, {:work, payload})
end)
```

Invokes the callback with the list of pids registered under `key`,
or no-ops if there are none.

## Design notes

### Per-node uniqueness

PgRegistry supports `keys: :unique`, but **uniqueness is enforced
per-node, not cluster-wide**. This is the same scope as `Registry`'s
`:unique` mode, lifted into a distributed setting:

- Within a single node, only one local pid can hold a given key. A
  second `register/3` returns `{:error, {:already_registered, holder}}`.
- Across the cluster, **each node can have its own holder** under the
  same key. There is no cross-node arbitration.

```elixir
{PgRegistry, name: :singletons, keys: :unique}

# On node A:
{:ok, _} = PgRegistry.register(:singletons, :worker, :v)

# Same node, second call (any pid):
{:error, {:already_registered, ^pid_a}} =
  PgRegistry.register(:singletons, :worker, :v)

# Node B at the same time succeeds — its node has its own holder:
{:ok, _} = PgRegistry.register(:singletons, :worker, :v)
```

The `:via` tuple integrates correctly: `register_name/2` returns `:no`
on collision, so `GenServer.start_link(name: {:via, PgRegistry, ...})`
surfaces `{:error, {:already_started, pid}}` automatically.

When the holding process exits (or calls `unregister/2`), the key
becomes available again on that node.

**This is useful when you want a singleton per node** — one
connection pool per node, one cache per node, one supervisor per
node — without paying `:global`'s consensus tax. **It is not what
you want for cluster-wide singletons.** If you need exactly-one
across the cluster, use `:global` or a leader election library.

Multi-pid joins (`Pg.join(scope, key, [p1, p2])`) raise
`ArgumentError` in unique mode because they have no meaningful
semantics — at most one of the pids could ever succeed.

### Partitions

PgRegistry uses a single ETS table per scope. `Registry`'s
`partitions:` option shards the local table to reduce write
contention; for distributed workloads the dominant cost is
gossip/convergence, not local writes, so partitioning a node helps
much less. PgRegistry accepts `partitions: 1` as a no-op and raises
on anything else.

If you genuinely hit local write contention on a single scope, the
recommended fix is to split the scope into several scopes (one per
logical workload), not to partition a single one.

### Convergence and net-splits

PgRegistry inherits `:pg`'s eventually-consistent semantics. During
a netsplit, each side of the partition continues to accept joins
independently. When the cluster heals, both sides resync via gossip
and converge without conflict — there's no "winner" to choose
because duplicates are the normal state.

One known imperfection: on netsplit recovery, sync-driven membership
changes update ETS correctly but do *not* fire `:update`
notifications for entries whose metadata changed during the split.
Subscribers see correct state at every read; only the notification
stream during convergence is incomplete. See the source of
`PgRegistry.Pg.sync_one_group/4` for context.

### Storage layout

Each scope owns an ETS `:duplicate_bag` of rows shaped:

```
{key, pid, value, tag}
```

where `tag` is an opaque per-node monotonic integer that gives every
entry its own identity. Tags are internal — callers never see them.
They exist so that ref-counted multi-join semantics survive a
flat-row layout, and so that cross-node leaves can identify a
specific entry unambiguously even when `(key, pid, value)` is
otherwise duplicated.

This layout is what makes match-spec queries (`select/2`, `match/3`)
run natively against ETS — user-supplied match-specs against
`{key, pid, value}` are translated to operate on the 4-tuple by
appending `:_` for the tag.

## License

MIT — see [LICENSE](LICENSE).
