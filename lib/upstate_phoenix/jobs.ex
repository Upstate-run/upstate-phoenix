defmodule UpstatePhoenix.Jobs do
  @moduledoc """
  The `jobs` section, read from Oban's `oban_jobs` table with one aggregate query through
  the repo and prefix of the running Oban instance. Job-only nodes therefore do not need
  to be scraped: any web container reports the shared queue.

    * `queue_depth` - jobs `available`, plus `scheduled` jobs whose time has come.
    * `oldest_queued_age_seconds` - age of the oldest of those, from `scheduled_at`.
    * `processed_last_5m` - jobs `completed` in the last 5 minutes.
    * `failed_last_5m` - jobs `discarded` in the last 5 minutes, plus `retryable` jobs whose
      failed attempt started in the last 5 minutes.
    * `recent_processing_at` - the latest `attempted_at` or `completed_at`.
    * `workers` - `nil`. Oban has no per-node heartbeat table outside Oban Pro.

    * `queues` - per queue: `depth` and `oldest_queued_age_seconds` (same definition as
      `queue_depth`), and this node's configured `concurrency` (`nil` when the queue is not
      configured here). Configured queues with no jobs report depth 0. Top 50 by depth.
    * `served_queues` - `{"all" => false, "names" => [...]}`: the queues this node's running
      Oban instance is configured to run (empty with `queues: false`).
    * `classes` - per worker module over the last 5 minutes: `processed_last_5m` and
      `failed_last_5m` (same definitions as above), and the average and maximum run time in
      milliseconds of completed jobs (`completed_at - attempted_at`). Top 50 by processed
      plus failed.

  Queue names (at most 120 characters) and worker module names (at most 200) are sent.
  Args, errors and meta are never read. `queues`, `served_queues` and `classes` are each
  `nil` on their own if they cannot be read.

  The counts see only rows still in `oban_jobs`. If `Oban.Plugins.Pruner` keeps jobs for
  less than 5 minutes (its default `max_age` is 60 seconds), processed and failed counts
  are undercounted.

  Postgres only (the Basic and Pro Smart engines). Oban on SQLite or MySQL reports the
  adapter `"unsupported"` with no numbers.
  """

  @window_seconds 300
  @query_timeout 1_500
  @extra_timeout 600
  # The health endpoint kills sections still running at 2s; the optional per-queue and
  # per-worker queries share what is left of this budget so they can never cost the
  # aggregate counts.
  @budget_ms 1_800
  @min_extra_ms 50
  @top 50
  @max_queue_name 120
  @max_worker_name 200
  @unsupported_engines [Oban.Engines.Lite, Oban.Engines.Dolphin]

  @doc false
  def call(%{oban: false}, _now), do: empty("none")

  def call(%{oban: name}, now) do
    case oban_config(name) do
      nil ->
        empty("none")

      config ->
        collect(config, now)
    end
  end

  @doc false
  def collect(config, now) do
    engine = Map.get(config, :engine)
    table = job_table(Map.get(config, :prefix))

    if engine in @unsupported_engines or is_nil(table),
      do: empty("unsupported"),
      else: stats(config, table, now)
  end

  @doc false
  def job_table(false), do: ~s("oban_jobs")
  def job_table(nil), do: ~s("oban_jobs")

  def job_table(prefix) when is_binary(prefix) and byte_size(prefix) in 1..63 do
    if String.valid?(prefix) and not String.contains?(prefix, <<0>>),
      do: ~s("#{String.replace(prefix, "\"", "\"\"")}"."oban_jobs")
  end

  def job_table(_prefix), do: nil

  @doc false
  def oban_config(name) do
    if Code.ensure_loaded?(Oban) do
      try do
        apply(Oban, :config, [name])
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end
    end
  end

  # Oban stores utc_datetime_usec in `timestamp without time zone` columns, so naive UTC
  # values are compared and returned.
  defp stats(config, table, now) do
    deadline = System.monotonic_time(:millisecond) + @budget_ms
    now_naive = now |> DateTime.to_naive() |> NaiveDateTime.truncate(:microsecond)
    since = NaiveDateTime.add(now_naive, -@window_seconds, :second)

    sql = """
    SELECT
      count(*) FILTER (WHERE state = 'available' OR (state = 'scheduled' AND scheduled_at <= $1)),
      min(scheduled_at) FILTER (WHERE state = 'available' OR (state = 'scheduled' AND scheduled_at <= $1)),
      count(*) FILTER (WHERE state = 'completed' AND completed_at >= $2),
      count(*) FILTER (WHERE state = 'discarded' AND discarded_at >= $2),
      count(*) FILTER (WHERE state = 'retryable' AND attempted_at >= $2),
      max(attempted_at),
      max(completed_at)
    FROM #{table}
    WHERE state IN ('available', 'scheduled', 'executing', 'completed', 'discarded', 'retryable', 'cancelled')
    """

    {:ok, %{rows: [[depth, oldest, completed, discarded, retryable, attempted, finished]]}} =
      apply(Oban.Repo, :query, [
        config,
        sql,
        [now_naive, since],
        [timeout: @query_timeout, log: false]
      ])

    %{
      "adapter" => "oban",
      "queue_depth" => depth,
      "oldest_queued_age_seconds" => oldest && max(NaiveDateTime.diff(now_naive, oldest), 0),
      "workers" => nil,
      "processed_last_5m" => completed,
      "failed_last_5m" => discarded + retryable,
      "recent_processing_at" => latest(attempted, finished),
      "queues" => field(fn -> queues(config, table, now_naive, extra_timeout(deadline)) end),
      "served_queues" => field(fn -> served_queues(config) end),
      "classes" => field(fn -> classes(config, table, since, extra_timeout(deadline)) end)
    }
  end

  # Remaining budget for one optional query, capped at @extra_timeout; raises (so the field
  # is null) when too little is left to be worth starting.
  defp extra_timeout(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining < @min_extra_ms, do: raise("job stats budget spent")
    min(remaining, @extra_timeout)
  end

  defp field(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp queues(config, table, now_naive, timeout) do
    sql = """
    SELECT queue, count(*), min(scheduled_at)
    FROM #{table}
    WHERE (state = 'available' OR (state = 'scheduled' AND scheduled_at <= $1))
      AND char_length(queue) <= #{@max_queue_name}
    GROUP BY queue
    ORDER BY count(*) DESC, queue
    LIMIT #{@top}
    """

    {:ok, %{rows: rows}} =
      apply(Oban.Repo, :query, [config, sql, [now_naive], [timeout: timeout, log: false]])

    limits = configured_limits(config)

    found =
      Map.new(rows, fn [name, depth, oldest] ->
        {name,
         %{
           "name" => name,
           "depth" => depth,
           "oldest_queued_age_seconds" => oldest && max(NaiveDateTime.diff(now_naive, oldest), 0),
           "concurrency" => Map.get(limits, name)
         }}
      end)

    empty_configured =
      for {name, limit} <- limits, not Map.has_key?(found, name), into: %{} do
        {name,
         %{
           "name" => name,
           "depth" => 0,
           "oldest_queued_age_seconds" => nil,
           "concurrency" => limit
         }}
      end

    found
    |> Map.merge(empty_configured)
    |> Map.values()
    |> Enum.sort_by(&{-&1["depth"], &1["name"]})
    |> Enum.take(@top)
  end

  defp served_queues(config) do
    names =
      config
      |> configured_limits()
      |> Map.keys()
      |> Enum.sort()
      |> Enum.take(@top)

    %{"all" => false, "names" => names}
  end

  # %{"queue" => limit | nil}, from the running instance's `:queues` option. Queue names
  # longer than the cap are left out.
  defp configured_limits(config) do
    case Map.get(config, :queues) do
      queues when is_list(queues) ->
        for {name, opts} <- queues,
            name = to_string(name),
            String.length(name) <= @max_queue_name,
            into: %{},
            do: {name, queue_limit(opts)}

      _ ->
        %{}
    end
  end

  defp queue_limit(limit) when is_integer(limit), do: limit
  defp queue_limit(opts) when is_list(opts), do: queue_limit(Keyword.get(opts, :limit))
  defp queue_limit(_), do: nil

  defp classes(config, table, now_naive_since, timeout) do
    sql = """
    SELECT
      worker,
      count(*) FILTER (WHERE state = 'completed'),
      count(*) FILTER (WHERE state <> 'completed'),
      (avg(extract(epoch FROM completed_at - attempted_at) * 1000)
         FILTER (WHERE state = 'completed'))::float8,
      (max(extract(epoch FROM completed_at - attempted_at) * 1000)
         FILTER (WHERE state = 'completed'))::float8
    FROM #{table}
    WHERE ((state = 'completed' AND completed_at >= $1)
        OR (state = 'discarded' AND discarded_at >= $1)
        OR (state = 'retryable' AND attempted_at >= $1))
      AND char_length(worker) <= #{@max_worker_name}
    GROUP BY worker
    ORDER BY count(*) DESC, worker
    LIMIT #{@top}
    """

    {:ok, %{rows: rows}} =
      apply(Oban.Repo, :query, [
        config,
        sql,
        [now_naive_since],
        [timeout: timeout, log: false]
      ])

    for [worker, processed, failed, avg, max] <- rows do
      %{
        "name" => worker,
        "processed_last_5m" => processed,
        "failed_last_5m" => failed,
        "duration_ms_avg" => avg && round(avg),
        "duration_ms_max" => max && round(max)
      }
    end
  end

  defp latest(nil, nil), do: nil

  defp latest(a, b) do
    [a, b]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(NaiveDateTime)
    |> NaiveDateTime.truncate(:second)
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp empty(adapter) do
    %{
      "adapter" => adapter,
      "queue_depth" => nil,
      "oldest_queued_age_seconds" => nil,
      "workers" => nil,
      "processed_last_5m" => nil,
      "failed_last_5m" => nil,
      "recent_processing_at" => nil,
      "queues" => nil,
      "served_queues" => nil,
      "classes" => nil
    }
  end
end
