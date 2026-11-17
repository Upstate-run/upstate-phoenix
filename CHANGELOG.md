# 0.4.0

- Add `mix upstate.verify`, a read-only check that sends nothing to Upstate and writes nothing (it does not query the database or Oban): disabled or configured, token presence (never the value), reporter and runtime versions, and plug authorization and response. It runs only when invoked and sends nothing to Upstate.

# 0.3.0

- Report the Oban cron schedule and its recent runs in a new `recurring` section, so Upstate
  can propose a check-in for each recurring worker:
  - `tasks`: `{key, class_name, schedule}` per `crontab` entry (worker module and cron
    expression) read from the running Oban instance's `Oban.Cron` / `Oban.Plugins.Cron`
    config. `@reboot` entries are skipped. `args` and every other option are never read.
    Every entry is keyed `Worker (expression)`, so a key never depends on position, order or how
    many other entries the worker has. Editing an expression is a new key; when exactly one
    accepted entry of a worker is replaced by exactly one new entry of that worker, Upstate
    moves the accepted check-in to the new key and updates its interval.
  - `prune_max_age_seconds`: the `Oban.Plugins.Pruner` `max_age` (60 when the plugin has no
    option), or null with no Pruner or an unreadable value. Below 5 minutes Upstate warns that
    it can miss runs and holds back missed-run alerts for those check-ins.
  - Oban Lite and Dolphin keep no finished-job rows, so they send no `recurring` section and
    nothing is offered.
  - `runs`: `{key, run_id, started_at, finished_at, result}` (newest 10 finished runs per entry within 24 hours of finishing, plus every run still going at any age), from the cron-inserted rows of `oban_jobs` (`executing` and `retryable` are
    `running`, `completed` is `success`, `discarded` is `fail`; `cancelled` after a start is `fail`, never-started cancelled is skipped).
    `run_id` is `oban-<job id>`. The query never selects args, meta (beyond the cron
    expression), errors, tags or queue names. Reading the shared table reports every node's
    runs, which `[:oban, :job, ...]` telemetry (this VM only) would not.
  - A node that does not run the cron plugin sends no `recurring` section, so a web node
    without cron never makes Upstate think the schedule was emptied.
  - The schema stays 1 and the section is additive: servers that predate it ignore it.

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
