# 0.2.0

- Report database health in the `database` section, for the first repo on PostgreSQL:
  - `size_bytes`: `pg_database_size(current_database())` (this database only, not WAL or
    other databases on the server);
  - `connections`: `{"in_use", "max"}` (client connections and `max_connections`);
  - `oldest_transaction_age_seconds` (0 when none is open) and `idle_in_transaction`, for
    sessions the app's role can see;
  - `xid_age`: `age(datfrozenxid)` (transaction ID wraparound headroom used);
  - `replication`: replica replay lag, or the replica count and largest `replay_lag` on a
    primary where visible; left out otherwise;
  - `largest_tables`: the 5 largest tables with total size and estimated live/dead rows.
    Table names and numbers only, never row data.
- One transaction with a 250ms `SET LOCAL statement_timeout`, each query behind a
  savepoint, collected concurrently with the migration check. Anything that fails or runs on
  another adapter is left out; it never changes `database.ok` or the status. The schema stays
  1 (all fields are additive) and servers that predate them ignore them.

# 0.1.1

- Report unknown migration status when `migrations_paths: []` disables inspection.

# Changelog

## 0.1.0 (unreleased)

- `UpstatePhoenix.Plug` answers `GET /upstate/health` with the Upstate app-health schema 1:
  version, boot time, Phoenix/Elixir/OTP versions, database reachability and pending
  migrations, and Oban job counts.
- Bearer token from `UPSTATE_HEALTH_TOKEN`, compared in constant time. No token configured
  means 404. A missing or wrong token means 401.
- `UpstatePhoenix.private_host?/1` for `force_ssl` so the observer's plain-HTTP request to the
  container's private IP is not redirected.
