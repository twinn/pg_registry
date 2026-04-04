# Changelog

## 0.1.0

- Initial release
- `:via` tuple support (`register_name`, `unregister_name`, `whereis_name`, `send`)
- Backed by Erlang's `:pg` for automatic cross-cluster process discovery
- Supervisable with `{PgRegistry, scope}`
