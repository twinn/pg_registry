# Changelog

## 0.3.0

This release replaces the `:pg` backend with `PgRegistry.Pg` — a
self-contained Elixir port of OTP-27 `pg.erl` extended with
per-entry metadata — and grows the public surface to roughly match
Elixir's `Registry`.

### Backwards-incompatible changes

- **Backend swap.** `PgRegistry` no longer uses Erlang `:pg` under
  the hood. Anyone reaching past the public API into
  `:pg.get_local_members(scope, key)` (or similar) must switch to
  `PgRegistry.Pg.get_local_members/2`. The two storage worlds are
  now disjoint — a scope started by `PgRegistry.start_link/1` lives
  in `PgRegistry.Pg`'s ETS table, not in `:pg`'s.

- **Wire format.** `PgRegistry.Pg` uses its own wire format and is
  no longer compatible with `:pg`. A protocol-version handshake
  (`@protocol_version 1`) was added — peers running mismatched
  versions refuse to peer with a `Logger.warning` rather than
  silently corrupting state. Bumping the constant on any future
  wire change is the migration story.

- **`register_name/2` may now return `:no`.** In a scope started
  with `keys: :unique`, registering under an already-held key
  returns `:no` so `GenServer.start_link(name: {:via, ...})`
  surfaces `{:error, {:already_started, pid}}` automatically.
  In `:duplicate` mode (the default) the return is unchanged.

- **`Pg.join` may return `{:error, {:already_registered, pid}}`**
  in unique mode.

### New: per-entry metadata

- `{:via, PgRegistry, {scope, key, value}}` — 3-tuple via name
  attaches a value at registration time.
- `PgRegistry.lookup/2` — `[{pid, value}]`, the metadata-aware view.
- `PgRegistry.update_value/3` and `update_value/4` — replace the
  value of self()'s entry, or any local pid's entry.
- `Pg.update_meta/4` — lower-level form, broadcasts a `{:update_meta, ...}`
  message so the change reaches every node.
- Subscription messages grow a third verb `:update` carrying
  `[{pid, old_meta, new_meta}]`.

### New: Registry-shaped API

- `register/3`, `unregister/2` — self()-shaped wrappers.
- `lookup/2`, `lookup_local/2`, `values/3`, `keys/2`, `count/1`.
- `match/3`, `match/4`, `count_match/3`, `count_match/4`.
- `select/2`, `count_select/2` — user-supplied match-specs against
  `{key, pid, value}` triples, translated to operate on the 4-tuple
  storage shape internally and run as native ETS queries.
- `unregister_match/3`, `unregister_match/4`.
- `meta/2`, `put_meta/3`, `delete_meta/2` — local-only registry
  metadata stored in a sibling ETS table named `:"#{scope}_meta"`.
- `dispatch/4` (with an `_opts` accumulator argument for Registry
  compat).
- `monitor_scope/1`, `monitor/2`, `demonitor/2` — runtime
  subscription with refs.

### New: listeners

- `start_link(name: :reg, listeners: [MyListener])` — Registry-shaped
  listener configuration. Listeners receive raw
  `{:register, scope, key, pid, value}` and
  `{:unregister, scope, key, pid}` messages on join/leave events
  (matching `Registry`'s contract). Local-only; addressed by
  registered name; missing names are silently dropped rather than
  crashing the scope.

### New: per-node `:unique` mode

- `start_link(name: :reg, keys: :unique)` — each node enforces local
  uniqueness, but the cluster can still have one holder per node.
  Use this for "one singleton per node" patterns. For cluster-wide
  unique names, use `:global`.

### New: Registry-shaped keyword start_link

- `PgRegistry.start_link(name: :reg, listeners: [...], keys: :duplicate)`
  for users porting from Registry. `:keys` (`:duplicate` or
  `:unique`) and `:partitions` (must be `1`) are validated and
  raise `ArgumentError` with helpful messages on unsupported values.
  Unknown options also raise. The same validation runs in the
  2-arity `start_link/2` form.

### Bug fixes

- `unregister_match` deleted the LIFO head of self()'s entries
  rather than the entry that matched the pattern. Fixed by adding
  a gen-server-side primitive that deletes by exact tag.
- `count_select` over-counted when the user's match-spec body
  filtered some matches out (we were stripping the body).
- `count/1` was O(N×M); now uses `:ets.info(scope, :size)`.
- A missing/crashed listener atom no longer crashes the scope —
  delivery uses `Process.whereis/1` first.
- The local DOWN handler no longer fabricates a `nil`-meta leave
  notification when the ETS row is missing during cleanup.
- `keys: :unique` registration now skips dead holders, closing the
  race where a `:DOWN` for the previous holder was queued in the
  GenServer mailbox but hadn't been processed yet.
- `Pg.leave(scope, key, [])` returns `:ok` instead of `:not_joined`.

### Known limitations

- `Pg.unregister_match` and friends are by-tag exact deletes, but
  sync-driven `:update` notifications after a netsplit are still
  not emitted (state converges correctly, only the notification
  stream during convergence is incomplete).
- No `lock/3`. No cluster-wide unique keys. No `partitions: > 1`.
  Each is a deliberate design decision; see the README.

## 0.2.2

- `unregister_name/1` now only removes local members
- `whereis_name/1` prefers local members, falls back to remote members

## 0.2.1

- Add typespecs for all public functions
- Add `scope`, `key`, and `via_name` types
- Fix `dispatch/3` to skip callback when no members (matches `Registry.dispatch/3`)
- Fix LICENSE doc warning

## 0.2.0

- Add `get_members/2` to retrieve all processes in a group
- Add `which_groups/1` to list all registered keys in a scope
- Add `dispatch/3` to invoke a callback on all members of a group
- **Breaking:** `register_name/2` now always joins the group (no uniqueness guard)

## 0.1.0

- Initial release
- `:via` tuple support (`register_name`, `unregister_name`, `whereis_name`, `send`)
- Backed by Erlang's `:pg` for automatic cross-cluster process discovery
- Supervisable with `{PgRegistry, scope}`
