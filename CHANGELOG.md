# Changelog

## 0.4.1

### Bug fixes

- Fire `:join`/`:leave` monitor notifications for membership changes
  arriving via the initial sync exchange or re-sync after reconnection.
  Previously, entries from a peer that registered before the local scope
  discovered it were silently added to ETS without notifying monitor
  subscribers.

## 0.4.0

### Backwards-incompatible changes

- **`:via` read callbacks require `keys: :unique`.** `whereis_name/1`
  and `send/2` now raise `ArgumentError` when called on a
  `:duplicate`-keyed scope. The write-side callbacks (`register_name/2`,
  `unregister_name/1`) continue to work in both modes. This makes the
  `:via` contract explicit: registration is always valid, but
  name-based resolution requires an unambiguous key-to-pid mapping.

### Enhancements

- All cross-node sends now use the `[:noconnect]` option, preventing
  the scope GenServer from inadvertently triggering node connections.

## 0.3.0

This release replaces the `:pg` backend with `PgRegistry.Pg`, a
self-contained Elixir port of OTP-27 `pg.erl` extended with per-entry
metadata, and expands the public API surface to cover most of
`Registry`'s functionality.

### Backwards-incompatible changes

- **Backend swap.** `PgRegistry` no longer uses Erlang `:pg`
  internally. Code that reached past the public API into
  `:pg.get_local_members(scope, key)` or similar must switch to
  `PgRegistry.Pg.get_local_members/2`. A scope started by
  `PgRegistry.start_link/1` now lives in `PgRegistry.Pg`'s ETS table,
  not in `:pg`'s.

- **Wire format.** `PgRegistry.Pg` uses its own wire format and is
  no longer compatible with `:pg`. A protocol-version handshake
  (`@protocol_version 1`) was added; peers running mismatched versions
  refuse to peer and log a warning instead of silently corrupting state.

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
  value of the calling process's entry, or a specific local pid's entry.
- `Pg.update_meta/4` — lower-level form, broadcasts a `{:update_meta, ...}`
  message so the change reaches every node.
- Subscription messages now include an `:update` verb carrying
  `[{pid, old_meta, new_meta}]`.

### New: Registry-shaped API

- `register/3`, `unregister/2` — register/unregister the calling process.
- `lookup/2`, `lookup_local/2`, `values/3`, `keys/2`, `count/1`.
- `match/3`, `match/4`, `count_match/3`, `count_match/4`.
- `select/2`, `count_select/2` — user-supplied match-specs against
  `{key, pid, value}` triples, translated to operate on the 4-tuple
  storage shape internally and run as native ETS queries.
- `unregister_match/3`, `unregister_match/4`.
- `meta/2`, `put_meta/3`, `delete_meta/2` — local-only registry
  metadata stored in a sibling ETS table named `:"#{scope}_meta"`.
- `dispatch/4` (fourth argument for `Registry.dispatch/4` signature
  compatibility).
- `monitor_scope/1`, `monitor/2`, `demonitor/2` — ref-based runtime
  subscriptions.

### New: listeners

- `start_link(name: :reg, listeners: [MyListener])` — Registry-shaped
  listener configuration. Listeners receive raw
  `{:register, scope, key, pid, value}` and
  `{:unregister, scope, key, pid}` messages on join/leave events
  (matching `Registry`'s contract). Listeners are local-only and
  addressed by registered name. Unregistered names are silently
  skipped.

### New: per-node `:unique` mode

- `start_link(name: :reg, keys: :unique)` — each node enforces local
  uniqueness while the cluster may still have one holder per node.
  For cluster-wide unique names, use `:global`.

### New: Registry-shaped keyword start_link

- `PgRegistry.start_link(name: :reg, listeners: [...], keys: :duplicate)`
  accepts the same option names as `Registry.start_link/1`. `:keys`
  (`:duplicate` or `:unique`) and `:partitions` (must be `1`) are
  validated; unsupported values raise `ArgumentError`. Unknown options
  also raise.

### Bug fixes

- `unregister_match` deleted the LIFO head of self()'s entries
  rather than the entry that matched the pattern. Fixed by adding
  a gen-server-side primitive that deletes by exact tag.
- `count_select` over-counted when the match-spec body filtered some
  matches out (the body was incorrectly stripped).
- `count/1` was O(N×M); now uses `:ets.info(scope, :size)`.
- A missing or crashed listener no longer crashes the scope process;
  delivery checks `Process.whereis/1` first.
- The local DOWN handler no longer fabricates a `nil`-meta leave
  notification when the ETS row is missing during cleanup.
- `keys: :unique` registration now skips dead holders, closing the
  race where a `:DOWN` for the previous holder was queued in the
  GenServer mailbox but hadn't been processed yet.
- `Pg.leave(scope, key, [])` returns `:ok` instead of `:not_joined`.

### Known limitations

- Sync-driven `:update` notifications after a netsplit are not emitted.
  State converges correctly; only the notification stream during
  convergence is incomplete.
- `lock/3`, cluster-wide unique keys, and `partitions: > 1` are not
  supported. See the README for the rationale.

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
