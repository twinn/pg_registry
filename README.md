# PgRegistry

[![CI](https://github.com/twinn/pg_registry/actions/workflows/ci.yml/badge.svg)](https://github.com/twinn/pg_registry/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/pg_registry.svg)](https://hex.pm/packages/pg_registry)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/pg_registry)
[![License](https://img.shields.io/hexpm/l/pg_registry.svg)](https://github.com/twinn/pg_registry/blob/main/LICENSE)

A distributed, cluster-aware process registry for Elixir with per-entry
metadata.

PgRegistry provides a `Registry`-shaped API on top of a self-contained
Elixir port of Erlang's `:pg` extended with per-entry metadata. Entries
are replicated across the cluster through gossip-based eventually
consistent membership. The API supports duplicate and per-node unique
keys, per-process values, listener notifications, ETS-native match-spec
queries, and runtime subscriptions.

## Installation

```elixir
def deps do
  [
    {:pg_registry, "~> 0.4"}
  ]
end
```

## Quick start

```elixir
# In a supervision tree
children = [
  {PgRegistry, :my_registry}
]

# Register a process via a :via tuple
GenServer.start_link(MyServer, arg,
  name: {:via, PgRegistry, {:my_registry, :my_key}})

# Register the calling process directly with metadata
{:ok, _} = PgRegistry.register(:my_registry, :worker, %{role: :primary})

# Look up entries across the cluster
PgRegistry.lookup(:my_registry, :worker)
#=> [{#PID<0.123.0>, %{role: :primary}}]

PgRegistry.whereis_name({:my_registry, :my_key})
#=> #PID<0.456.0>
```

## Comparison

PgRegistry is a duplicate-keyed, cluster-aware process registry.
Multiple processes can register under one key, entries are gossiped
between nodes automatically, and the API follows the shape of Elixir's
`Registry`.

| | `Registry` | `:pg` | `:global` | `Horde.Registry` | `PgRegistry` |
|---|---|---|---|---|---|
| Scope | one node | cluster | cluster | cluster | cluster |
| Underlying model | ETS + GenServer | GenServer + gossip | cluster-wide lock | delta-CRDT | GenServer + gossip |
| Cost per register | µs | µs + async broadcast | ms (cluster-wide lock) | µs + async CRDT delta | µs + async broadcast |
| Convergence model | n/a | eventual, gossip | synchronous, lock-based | eventual, CRDT merge | eventual, gossip |
| Net-split behaviour | n/a | diverges, converges on heal without conflict | collisions on heal resolved by user-supplied resolver; may kill processes | CRDT merge picks a winner; losing registrations are dropped | diverges, converges on heal without conflict |
| Duplicate keys | yes | yes (only mode) | no | no | yes (default) |
| Unique keys | yes (per-node) | no | yes (cluster-wide) | yes (cluster-wide) | yes (per-node only) |
| Per-process values | yes | no | no | yes | yes |
| Match-spec queries | yes (ETS-native) | no | no | yes | yes (ETS-native) |
| Listeners | yes | no | no | yes | yes |
| Part of OTP | yes | yes | yes | no | no |
| Interop with other Erlang/OTP apps | no | yes | yes | no | no |

### Choosing a registry

| Requirement | Recommended |
|---|---|
| Cluster-wide process groups with values and a `Registry`-shaped API | `PgRegistry` |
| Cluster-wide process groups (pids only), or interop with existing `:pg` scopes | `:pg` |
| Exactly one process per name, cluster-wide | `Horde.Registry` |
| Single-node registry with metadata and match-specs | `Registry` |
| Cluster-wide name uniqueness with strong consistency | `:global` |
| Both cluster-wide singletons and cluster-wide groups in the same application | `Horde.Registry` and `PgRegistry` together |

## API

### Configuration

Three start-link forms are accepted:

```elixir
# Bare scope name
{PgRegistry, :my_registry}

# Scope with options
{PgRegistry, {:my_registry, listeners: [MyListener]}}

# Keyword form (same option names as Registry.start_link/1)
{PgRegistry, name: :my_registry, listeners: [MyListener], keys: :duplicate}
```

Supported options:

- `:listeners` - a list of locally-registered process names that receive
  `{:register, scope, key, pid, value}` and
  `{:unregister, scope, key, pid}` messages on join/leave events.
- `:keys` - `:duplicate` (default) or `:unique`. In `:unique` mode,
  uniqueness is enforced per-node only; see
  [Per-node uniqueness](#per-node-uniqueness) below.
- `:partitions` - accepted for compatibility with `Registry`. Only the
  value `1` is supported; other values raise `ArgumentError`. See
  [Partitions](#partitions) below.

### Registering processes

```elixir
# Using a :via tuple (compatible with GenServer, Agent, and Task names)
{:via, PgRegistry, {scope, key}}                # value defaults to nil
{:via, PgRegistry, {scope, key, value}}         # 3-tuple attaches a value

# Using the self()-based API
PgRegistry.register(scope, key, value)          #=> {:ok, self()}
PgRegistry.unregister(scope, key)               #=> :ok

# Using the explicit-pid API
PgRegistry.register_name({scope, key}, pid)
PgRegistry.register_name({scope, key, value}, pid)
PgRegistry.unregister_name({scope, key})
```

> #### `:via` tuples in `:duplicate` mode {: .info}
>
> As with `Registry`, `:via` tuple registration succeeds in
> `:duplicate` mode, but name resolution (`whereis_name/1`, `send/2`,
> and by extension `GenServer.call/3`) raises `ArgumentError` because
> a duplicate-keyed scope may have many pids under one key. Use
> `lookup/2` or `dispatch/3` to address members instead.

A process may register multiple times under the same key with different
values. Each registration is independent and must be unregistered
separately. When a registered process exits, all of its entries are
automatically removed and listeners and subscribers are notified.

### Reading

```elixir
PgRegistry.lookup(scope, key)              # [{pid, value}, ...] (cluster-wide)
PgRegistry.lookup_local(scope, key)        # [{pid, value}, ...] (local node only)
PgRegistry.values(scope, key, pid)         # [value, ...] for one pid
PgRegistry.keys(scope, pid)                # [key, ...] for one pid
PgRegistry.which_groups(scope)             # [key, ...]
PgRegistry.count(scope)                    # total entries
```

To extract pids without values:

```elixir
for {pid, _} <- PgRegistry.lookup(scope, key), do: pid
```

All read functions operate directly against ETS from the calling
process. They do not go through the scope GenServer.

`lookup_local/2` has no equivalent in `Registry`. It returns only
entries whose pid is on the local node, which is useful for draining a
node before shutdown, collecting per-node metrics, or preferring a
local process before falling back to a remote one.

### Updating values

```elixir
PgRegistry.update_value(scope, key, new_value)        # updates self()'s entries
PgRegistry.update_value(scope, key, pid, new_value)   # updates a specific pid's entries
```

Updates every entry under `key` whose pid matches. Returns
`:not_joined` if the pid has no entry under the key. Subscribers
receive `{ref, :update, key, [{pid, old, new}]}` events. Listeners
do not receive update events, matching `Registry`'s behaviour.

### Match-spec queries

```elixir
PgRegistry.match(scope, key, pattern)
PgRegistry.match(scope, key, pattern, guards)
PgRegistry.count_match(scope, key, pattern)
PgRegistry.count_match(scope, key, pattern, guards)
PgRegistry.unregister_match(scope, key, pattern)
PgRegistry.unregister_match(scope, key, pattern, guards)

PgRegistry.select(scope, match_spec)
PgRegistry.count_select(scope, match_spec)
```

`match/3,4` matches against the value position. `select/2` accepts a
full ETS match-spec whose patterns are shaped as `{key, pid, value}`,
the same shape used by `Registry.select/2`. All of these execute as
native ETS queries against the underlying table.

### Subscriptions and listeners

There are two mechanisms for reacting to scope changes.

**Listeners** are configured at scope start-up and receive messages
matching `Registry`'s listener contract:

```elixir
{PgRegistry, name: :my_registry, listeners: [MyListener]}

# MyListener receives:
{:register,   :my_registry, key, pid, value}
{:unregister, :my_registry, key, pid}
```

Listeners are addressed by registered name (atom). A listener that
crashes and restarts under the same name continues to receive events.
Listeners do **not** fire on `update_value`, matching `Registry`.

**Runtime subscriptions** are dynamic and ref-based. They also
deliver `:update` events:

```elixir
{ref, snapshot} = PgRegistry.Pg.monitor_scope(:my_registry)
# snapshot :: %{key => [{pid, value}, ...]}

# The subscriber receives:
{^ref, :join,   key, [{pid, value}, ...]}
{^ref, :leave,  key, [{pid, value}, ...]}
{^ref, :update, key, [{pid, old, new}, ...]}

PgRegistry.Pg.demonitor(:my_registry, ref)
```

Listeners are suited to fixed system-level integrations such as logging
or metrics. Subscriptions are suited to consumers that start and stop
dynamically.

### Scope-level metadata

```elixir
PgRegistry.put_meta(scope, :config, %{retries: 3})
PgRegistry.meta(scope, :config)        #=> {:ok, %{retries: 3}}
PgRegistry.delete_meta(scope, :config)
```

Scope metadata is local to the node and is not gossiped. It is stored
in a sibling ETS table for lock-free reads.

### Dispatch

```elixir
PgRegistry.dispatch(scope, key, fn members ->
  for pid <- members, do: send(pid, {:work, payload})
end)
```

Invokes the callback with the list of pids registered under `key`.
If no processes are registered, the callback is not invoked.

## Design notes

### Per-node uniqueness

PgRegistry supports `keys: :unique`, but **uniqueness is enforced
per-node, not cluster-wide**. This follows the same scope as
`Registry`'s `:unique` mode, extended to a distributed setting:

- On a single node, only one pid can hold a given key. A second
  `register/3` returns `{:error, {:already_registered, holder}}`.
- Across the cluster, each node may independently hold the same key.
  There is no cross-node arbitration.

```elixir
{PgRegistry, name: :singletons, keys: :unique}

# On node A:
{:ok, _} = PgRegistry.register(:singletons, :worker, :v)

# Same node, second call:
{:error, {:already_registered, ^pid_a}} =
  PgRegistry.register(:singletons, :worker, :v)

# Node B succeeds independently:
{:ok, _} = PgRegistry.register(:singletons, :worker, :v)
```

The `:via` tuple integrates with this: `register_name/2` returns `:no`
on collision, so `GenServer.start_link(name: {:via, PgRegistry, ...})`
surfaces `{:error, {:already_started, pid}}`.

When the holding process exits or calls `unregister/2`, the key
becomes available again on that node.

Per-node uniqueness is appropriate for patterns such as one connection
pool per node or one cache per node. For cluster-wide singletons, use
`:global` or a leader election library.

Multi-pid joins (`Pg.join(scope, key, [p1, p2])`) raise
`ArgumentError` in `:unique` mode because at most one pid can hold a
unique key.

### Partitions

PgRegistry uses a single ETS table per scope. `Registry`'s
`:partitions` option shards the local table to reduce write contention;
in distributed workloads the dominant cost is gossip and convergence,
not local writes, so partitioning provides less benefit. PgRegistry
accepts `partitions: 1` for compatibility and raises on other values.

If local write contention on a single scope becomes a bottleneck,
splitting the scope into multiple scopes (one per logical workload) is
the recommended approach.

### Convergence and net-splits

PgRegistry inherits `:pg`'s eventually consistent semantics. During a
network partition, each side continues to accept joins independently.
When the cluster heals, both sides resync through gossip and converge
without conflict, since duplicate entries are the expected state.

**Limitation:** on netsplit recovery, sync-driven membership changes
update ETS correctly but do not fire `:update` notifications for
entries whose metadata changed during the split. Subscribers observe
correct state on every read; only the notification stream during
convergence is incomplete. See the comment on `sync_one_group/4` in
`lib/pg_registry/pg.ex` for details.

### Storage layout

Each scope owns an ETS `:duplicate_bag` of rows shaped:

```
{key, pid, value, tag}
```

`tag` is an opaque per-node monotonic integer that gives every entry
its own identity. Tags are not exposed through the public API. They
allow ref-counted multi-join semantics to survive a flat-row layout and
enable cross-node leaves to identify a specific entry unambiguously,
even when `{key, pid, value}` would otherwise collide.

This layout allows match-spec queries (`select/2`, `match/3`) to run
as native ETS operations. User-supplied match-specs against
`{key, pid, value}` are translated to the 4-tuple storage shape by
appending `:_` for the tag.

## License

MIT. See [LICENSE](LICENSE).
