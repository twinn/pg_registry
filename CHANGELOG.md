# Changelog

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
