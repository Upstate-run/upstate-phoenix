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

  Counts only: no queue names, worker names, args, errors or meta are read.

  The counts see only rows still in `oban_jobs`. If `Oban.Plugins.Pruner` keeps jobs for
  less than 5 minutes (its default `max_age` is 60 seconds), processed and failed counts
  are undercounted.

  Postgres only (the Basic and Pro Smart engines). Oban on SQLite or MySQL reports the
  adapter `"unsupported"` with no numbers.
  """

  @window_seconds 300
  @query_timeout 1_500
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
      "recent_processing_at" => latest(attempted, finished)
    }
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
      "recent_processing_at" => nil
    }
  end
end
