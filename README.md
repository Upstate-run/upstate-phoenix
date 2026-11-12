# upstate_phoenix

Phoenix app health for [Upstate](https://upstate.cloud): boot facts, pending migrations, database health and Oban jobs. Counts only.

The package adds one Plug that answers `GET /upstate/health`. Upstate's host observer reads it from inside your server, over your private Docker network, every minute. Nothing else is installed, and nothing is sent anywhere by the package itself.

It is the Phoenix counterpart of the [`upstate-rails`](https://github.com/Upstate-run/upstate-rails) gem and answers the same schema 1 response, so Upstate needs nothing new on the server side.

## What is sent

- App version (`APP_VERSION`, else `KAMAL_VERSION`, else `unknown`), Phoenix, Elixir and OTP versions, the environment (`prod`), and when the VM booted.
- The reporter name and version (`upstate_phoenix`, `0.2.0`).
- Whether every configured Ecto repo answers, and whether any of them has migrations that have not run.
- Database health for the first repo (PostgreSQL only): its size in bytes (`pg_database_size`, this database only, not WAL or other databases), connections in use and `max_connections`, the oldest open transaction's age and the number of sessions idle in transaction (as visible to the app's role), `age(datfrozenxid)` (wraparound headroom), replication lag where this connection can see it, and the 5 largest tables with their total size and estimated live and dead rows. Table names are sent; row data never is.
- Oban job numbers: queue depth (available, plus scheduled jobs whose time has come), age of the oldest of those, jobs completed and failed in the last 5 minutes, and when a job last ran.

## What is never sent

No params, URLs or paths, SQL, row data, IP addresses, user agents, headers, cookies, job arguments, job errors, queue names, worker names, migration names, exception classes or messages, logs, or traces. The Rails-only sections of the schema (`rails`, `ruby`, `puma`, `active_record_pool`, `cache`, `actions`) are left out.

## Install

```elixir
# mix.exs
def deps do
  [
    {:upstate_phoenix, "~> 0.2"}
  ]
end
```

```elixir
# lib/my_app_web/endpoint.ex, above `plug Plug.Telemetry`
plug UpstatePhoenix.Plug, otp_app: :my_app
```

Placing it above `Plug.Telemetry` keeps the once-a-minute poll out of your request logs. Every other path passes straight through.

The endpoint is off until `UPSTATE_HEALTH_TOKEN` is set. Without it, `/upstate/health` returns 404. With a missing or wrong token it returns 401. Tokens are compared as SHA-256 digests in constant time.

### force_ssl

The observer calls the container's private IP over plain HTTP, so `force_ssl` would answer with a redirect. Exclude the path:

```elixir
# config/prod.exs (Plug 1.19+)
config :my_app, MyAppWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [hosts: ["localhost", "127.0.0.1"], paths: ["/up", "/upstate/health"]]
  ]
```

Phoenix compiles `force_ssl` into its endpoint. Set this in `config/prod.exs` and rebuild the release; changing only `runtime.exs` does not update the compiled SSL plug.

On Plug older than 1.19, whose `:exclude` takes only hosts, use `exclude: {UpstatePhoenix, :private_host?, []}` to skip the redirect for private-IP hosts.

## Configuration

Everything has a default. Options can go on the plug call or in config, plug options first:

```elixir
# config/config.exs
config :upstate_phoenix,
  repos: [MyApp.Repo],         # default: the otp_app's :ecto_repos
  oban: Oban,                  # the Oban instance name, or false for no job system
  environment: "prod"          # default: the Mix env the package was compiled in
```

- `repos` entries can also be `{MyApp.Repo, migrations_paths: ["priv/repo/migrations"]}` when migrations live somewhere other than Ecto's default.
- The token is read from `UPSTATE_HEALTH_TOKEN` at request time. You can also set `config :upstate_phoenix, token: ...` in `config/runtime.exs`.

## Kamal secrets

1. In Upstate, open the environment page and generate a health token. It is shown once.
2. Add it to `.kamal/secrets`:

   ```sh
   UPSTATE_HEALTH_TOKEN=<the token>
   ```

3. List it in `config/deploy.yml`:

   ```yaml
   env:
     secret:
       - UPSTATE_HEALTH_TOKEN
   ```

4. `kamal deploy`.

## Verify

From the server (the observer uses the container's private IP and app port):

```sh
curl -i -H "Authorization: Bearer $UPSTATE_HEALTH_TOKEN" http://<container ip>:4000/upstate/health
```

You should get `200` and JSON with `"schema": 1`. A `503` means a database is not answering (the JSON says so). A section that fails reports `null` and the rest still answers.

## Example response

```json
{
  "schema": 1,
  "version": "4f2c1e7",
  "reporter": {"name": "upstate_phoenix", "version": "0.2.0"},
  "phoenix": {"version": "1.8.1", "elixir": "1.18.4", "otp": "27", "environment": "prod"},
  "booted_at": "2026-10-29T12:00:00Z",
  "database": {"ok": true, "pending_migrations": false, "size_bytes": 1342177280,
               "connections": {"in_use": 12, "max": 100}, "oldest_transaction_age_seconds": 0,
               "idle_in_transaction": 0, "xid_age": 48211934,
               "largest_tables": [{"name": "public.events", "total_bytes": 812646400,
                                   "live_rows": 4210000, "dead_rows": 1200}]},
  "jobs": {"adapter": "oban", "queue_depth": 0, "oldest_queued_age_seconds": null, "workers": null,
           "processed_last_5m": 42, "failed_last_5m": 0, "recent_processing_at": "2026-10-29T12:41:07Z"}
}
```

## Good to know

- Job numbers come from one aggregate query on `oban_jobs` through the running Oban instance's repo and prefix, so any web container reports the shared queue and job-only containers need no scraping.
- `failed_last_5m` counts jobs discarded in the last 5 minutes plus retryable jobs whose failed attempt started in that window.
- The counts only see rows still in `oban_jobs`. `Oban.Plugins.Pruner` defaults to keeping jobs for 60 seconds; keep them at least 5 minutes (`max_age: 300` or more) or processed and failed counts will be low.
- `workers` is always `null`: Oban has no per-node heartbeat table outside Oban Pro.
- Oban on PostgreSQL is supported (Basic and Pro Smart engines). SQLite and MySQL engines report the adapter `"unsupported"` with no numbers. No Oban, or `oban: false`, reports `"none"`.
- The migration check reads `schema_migrations` without taking Ecto's migration lock and never creates the table, so it is safe while a migration runs.
- Database calls time out after 1 to 1.5 seconds, inside the observer's 3-second budget.
- Database health runs concurrently with the migration check: one transaction with a 250ms statement timeout and a savepoint per query, so a failing query (a timeout or missing permission) drops only its own fields. Everything is left out (never an error) on non-PostgreSQL adapters. Row counts are PostgreSQL's estimates from the last analyze or vacuum. On a replica, the lag reads the time since the last replayed transaction, so an idle primary shows growing lag.
- Requires Elixir 1.15+ and Plug 1.14+. Ecto SQL and Oban are optional and used only when your app has them. JSON uses Elixir's built-in `JSON` (1.18+) or Jason.

## Development

```sh
mix deps.get
PGUSER=postgres PGPASSWORD=postgres mix test
```

Tests create and migrate the `upstate_phoenix_test` database (override with `UPSTATE_PHOENIX_TEST_DB`, `PGHOST`).

## License

MIT.

Health collection has a two-second total budget for database and Oban sections, collected concurrently. Migration reads have a separate 500ms budget, including connection checkout; missing evidence is reported as null. Cancelled jobs contribute their last attempt timestamp but not processed/failed counts.

An explicit `migrations_paths: []` disables Ecto migration inspection and reports
`pending_migrations: null`, retaining the database reachability check. Use this when
another application (such as Rails) owns the schema.
