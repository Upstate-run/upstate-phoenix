defmodule UpstatePhoenix.DatabaseStats do
  @moduledoc """
  Cheap, aggregate, read-only PostgreSQL health numbers for the first repo, added to the
  `database` section:

  - `size_bytes`: `pg_database_size(current_database())`, this database only (not WAL or
    other databases on the server);
  - `connections`: client connections in use and `max_connections` (server-wide);
  - `oldest_transaction_age_seconds` (0 when none is open) and `idle_in_transaction`, for
    sessions on this database that the app's role can see in `pg_stat_activity`;
  - `xid_age`: `age(datfrozenxid)`, the transaction ID wraparound headroom used;
  - `replication`: on a replica, the replay lag; on a primary, the number of replicas and
    the largest `replay_lag` when visible. Left out when there is none;
  - `largest_tables`: the 5 largest tables by total size with their estimated live and dead
    rows (`pg_stat_user_tables`). Names and numbers only, never row data. Names are
    `quote_ident`-ed per part, so two tables never collapse into the same `schema.table`.

  Everything runs in one transaction with `SET LOCAL statement_timeout`, each query behind
  its own savepoint, so one failing query (permissions, timeout) drops only its fields.
  Non-PostgreSQL repos and any error return `%{}`.
  """

  @statement_timeout 250

  @summary """
  SELECT
    pg_database_size(current_database()),
    (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend'),
    current_setting('max_connections')::int,
    COALESCE((SELECT floor(extract(epoch FROM now() - min(xact_start)))::bigint
              FROM pg_stat_activity
              WHERE datname = current_database() AND xact_start IS NOT NULL
                AND pid <> pg_backend_pid() AND backend_type = 'client backend'), 0),
    (SELECT count(*) FROM pg_stat_activity
     WHERE datname = current_database()
       AND state IN ('idle in transaction', 'idle in transaction (aborted)')),
    (SELECT age(datfrozenxid) FROM pg_database WHERE datname = current_database()),
    pg_is_in_recovery(),
    CASE WHEN pg_is_in_recovery()
      THEN floor(extract(epoch FROM now() - pg_last_xact_replay_timestamp()))::bigint END
  """

  @tables """
  SELECT quote_ident(schemaname) || '.' || quote_ident(relname), pg_total_relation_size(relid), n_live_tup, n_dead_tup
  FROM pg_stat_user_tables
  ORDER BY pg_total_relation_size(relid) DESC
  LIMIT 5
  """

  @replicas """
  SELECT count(*), floor(extract(epoch FROM max(replay_lag)))::bigint FROM pg_stat_replication
  """

  @doc "Returns a map of the fields above with string keys; any field may be missing."
  def collect(repo) do
    if postgres?(repo), do: run(repo), else: %{}
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp run(repo) do
    {:ok, stats} =
      repo.transaction(
        fn ->
          repo.query!("SAVEPOINT upstate_database_stats_collection", [], log: false)

          try do
            collect_in_transaction(repo)
          after
            # Ecto flattens nested transactions. Rolling back this read-only savepoint
            # restores SET LOCAL even when the caller owns the surrounding transaction.
            repo.query!("ROLLBACK TO SAVEPOINT upstate_database_stats_collection", [], log: false)
            repo.query!("RELEASE SAVEPOINT upstate_database_stats_collection", [], log: false)
          end
        end,
        timeout: @statement_timeout * 4
      )

    stats
  end

  defp collect_in_transaction(repo) do
    repo.query!("SET LOCAL statement_timeout = #{@statement_timeout}", [], log: false)

    summary = guarded(repo, @summary, "s1")
    tables = guarded(repo, @tables, "s2")
    primary? = match?([[_, _, _, _, _, _, false, _]], summary)
    replicas = if primary?, do: guarded(repo, @replicas, "s3")

    %{}
    |> put_summary(summary)
    |> put_tables(tables)
    |> put_replicas(replicas)
  end

  # Runs one query behind a savepoint; a failure rolls back to it and returns nil.
  defp guarded(repo, sql, savepoint) do
    repo.query!("SAVEPOINT #{savepoint}", [], log: false)

    case repo.query(sql, [], log: false, timeout: @statement_timeout * 2) do
      {:ok, %{rows: rows}} ->
        rows

      _ ->
        repo.query!("ROLLBACK TO SAVEPOINT #{savepoint}", [], log: false)
        nil
    end
  end

  defp put_summary(stats, [[size, in_use, max, oldest, idle, xid_age, recovery?, lag]]) do
    stats
    |> put("size_bytes", count(size))
    |> put("connections", connections(in_use, max))
    |> put("oldest_transaction_age_seconds", count(oldest))
    |> put("idle_in_transaction", count(idle))
    |> put("xid_age", count(xid_age))
    |> put(
      "replication",
      if(recovery? == true, do: %{"role" => "replica", "lag_seconds" => count(lag)})
    )
  end

  defp put_summary(stats, _), do: stats

  defp put_tables(stats, [_ | _] = rows) do
    tables =
      for [name, total, live, dead] <- rows, is_binary(name) do
        %{
          "name" => name,
          "total_bytes" => count(total),
          "live_rows" => count(live),
          "dead_rows" => count(dead)
        }
      end

    put(stats, "largest_tables", if(tables != [], do: tables))
  end

  defp put_tables(stats, _), do: stats

  defp put_replicas(stats, [[replicas, lag]]) when is_integer(replicas) and replicas > 0,
    do:
      put(stats, "replication", %{
        "role" => "primary",
        "replicas" => replicas,
        "lag_seconds" => count(lag)
      })

  defp put_replicas(stats, _), do: stats

  defp connections(in_use, max) when is_integer(in_use) and is_integer(max) and max > 0,
    do: %{"in_use" => in_use, "max" => max}

  defp connections(_, _), do: nil

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_), do: nil

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp postgres?(repo) do
    Code.ensure_loaded?(repo) and function_exported?(repo, :__adapter__, 0) and
      repo.__adapter__() == Ecto.Adapters.Postgres
  end
end
