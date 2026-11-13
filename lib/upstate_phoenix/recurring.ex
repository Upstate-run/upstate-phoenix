defmodule UpstatePhoenix.Recurring do
  @moduledoc """
  The `recurring` section: the Oban cron schedule and recent runs of those jobs, so Upstate
  can propose a check-in for each recurring worker.

  Sent: for each crontab entry the worker module name (the key and class name) and the
  schedule expression; for recent runs an id, start, end and result. **Never** `args`,
  `meta` beyond the cron expression match, `errors`, queue names or tags: the runs query
  does not select them.

  The schedule is read from the running Oban instance's config (`Oban.Cron`, also known as
  `Oban.Plugins.Cron`, `crontab:`). A node that does not run the cron plugin reports no
  `recurring` section at all, so a web node without cron never makes the server think the
  schedule was emptied. `@reboot` entries are not recurring and are left out.

  Runs are read from `oban_jobs` rows that the cron plugin inserted (`meta.cron`), joined
  by worker and expression. This is the same shared table the `jobs` section uses, so any
  node reports every node's runs; Oban's own `[:oban, :job, ...]` telemetry would only see
  jobs executed in this VM. `executing` and `retryable` jobs are reported as `running`
  (a retryable job has not finished), `completed` as `success`, `discarded` as `fail`.
  A cancelled job that had started is `fail` (a run that did not complete; this closes a
  start already reported, and the next success recovers); a cancelled job that never
  started is skipped. Unfinished jobs are reported at any age; finished ones are the newest
  few per worker within 24 hours of finishing. Only unpruned rows are seen, as for the `jobs` section.
  """

  alias UpstatePhoenix.Jobs

  @window_seconds 24 * 3600
  @per_task 10
  @max_rows 1_500
  @max_tasks 100
  @query_timeout 1_500
  @cron_plugins [Oban.Cron, Oban.Plugins.Cron]

  @doc false
  def call(%{oban: false}, _now), do: nil

  def call(%{oban: name}, now), do: collect(Jobs.oban_config(name), now)

  @doc false
  def collect(nil, _now), do: nil

  def collect(config, now) do
    # Lite and Dolphin keep no finished-job rows Upstate can read, so an accepted check-in
    # could never see a run and would always page: nothing is offered for them.
    if cron_plugins(config) == [] or engine_without_history?(config) do
      nil
    else
      tasks = tasks(config)

      %{
        "adapter" => "oban",
        "tasks" => Enum.map(tasks, &Map.delete(&1, "worker")),
        "prune_max_age_seconds" => prune_max_age(config),
        "runs" => runs(config, tasks, now)
      }
    end
  end

  defp engine_without_history?(config),
    do: Map.get(config, :engine) in [Oban.Engines.Lite, Oban.Engines.Dolphin]

  # The Pruner plugin's `max_age` in seconds (Oban's default is 60), or nil when the instance
  # has no Pruner or the age cannot be read (`:infinity`, another pruner).
  defp prune_max_age(config) do
    config
    |> Map.get(:plugins, [])
    |> List.wrap()
    |> Enum.find_value(fn
      {Oban.Plugins.Pruner, opts} when is_list(opts) -> {:ok, Keyword.get(opts, :max_age, 60)}
      Oban.Plugins.Pruner -> {:ok, 60}
      _ -> nil
    end)
    |> case do
      {:ok, age} when is_integer(age) and age >= 0 -> age
      _ -> nil
    end
  end

  # [{module, opts}] for every cron plugin in the instance's config.
  defp cron_plugins(config) do
    config
    |> Map.get(:plugins, [])
    |> List.wrap()
    |> Enum.flat_map(fn
      {module, opts} when module in @cron_plugins and is_list(opts) -> [opts]
      module when module in @cron_plugins -> [[]]
      _ -> []
    end)
  end

  @doc false
  # => [%{"key", "class_name", "schedule", "worker"}]; "worker" (the module) is only used to
  # match runs and is dropped from the payload.
  def tasks(config) do
    entries =
      config
      |> cron_plugins()
      |> Enum.flat_map(&List.wrap(Keyword.get(&1, :crontab, [])))
      |> Enum.flat_map(fn
        {expr, worker} when is_binary(expr) and is_atom(worker) -> [{expr, worker}]
        {expr, worker, _opts} when is_binary(expr) and is_atom(worker) -> [{expr, worker}]
        _ -> []
      end)
      |> Enum.reject(fn {expr, _} -> String.downcase(String.trim(expr)) == "@reboot" end)
      |> Enum.uniq()
      |> Enum.take(@max_tasks)

    # Every entry is keyed by its worker and expression, `Worker (expr)`, so a key depends only
    # on the entry itself: not on its position, on how many other entries the worker has, or
    # on the order of the crontab. Editing an expression is a new job (a new proposal), and
    # the old accepted check-in is flagged as no longer in the schedule.
    Enum.map(entries, fn {expr, worker} ->
      name = inspect(worker)
      schedule = String.trim(expr)

      %{
        "key" => "#{name} (#{schedule})",
        "class_name" => name,
        "schedule" => schedule,
        "worker" => worker
      }
    end)
  end

  defp runs(config, tasks, now) do
    table = Jobs.job_table(Map.get(config, :prefix))

    if tasks == [] or is_nil(table) or
         Map.get(config, :engine) in [Oban.Engines.Lite, Oban.Engines.Dolphin],
       do: [],
       else: query_runs(config, table, tasks, now)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # `args`, `meta`, `errors` and `tags` are never selected; the cron expression is read out
  # of meta as one text value to tell two schedules of the same worker apart.
  defp query_runs(config, table, tasks, now) do
    since = now |> DateTime.to_naive() |> NaiveDateTime.add(-@window_seconds, :second)
    workers = tasks |> Enum.map(&worker_string(&1["worker"])) |> Enum.uniq()

    # Ranked per worker and expression (not one global limit, so a frequent worker cannot
    # push a daily worker's completion out). Unfinished rows are kept whatever their age (a
    # long run's completion must still be reported); finished rows are the newest
    # @per_task inside the window, by terminal timestamp rather than insertion time.
    sql = """
    SELECT id, worker, state, cron_expr, attempted_at, completed_at, discarded_at, cancelled_at
    FROM (
      SELECT id, worker, state, meta ->> 'cron_expr' AS cron_expr, attempted_at, completed_at,
             discarded_at, cancelled_at,
             GREATEST(attempted_at, completed_at, discarded_at, cancelled_at) AS activity,
             ROW_NUMBER() OVER (
               PARTITION BY worker, meta ->> 'cron_expr', state IN ('executing', 'retryable')
               ORDER BY GREATEST(attempted_at, completed_at, discarded_at, cancelled_at)
                        DESC NULLS LAST, id DESC
             ) AS rank
      FROM #{table}
      WHERE meta ->> 'cron' = 'true'
        AND worker = ANY($1)
        AND (
          state IN ('executing', 'retryable')
          OR (
            state IN ('completed', 'discarded', 'cancelled')
            AND (state <> 'cancelled' OR attempted_at IS NOT NULL)
            AND GREATEST(attempted_at, completed_at, discarded_at, cancelled_at) >= $2
          )
        )
    ) runs
    WHERE state IN ('executing', 'retryable') OR rank <= #{@per_task}
    ORDER BY rank, activity DESC NULLS LAST, id DESC
    LIMIT #{@max_rows}
    """

    {:ok, %{rows: rows}} =
      apply(Oban.Repo, :query, [
        config,
        sql,
        [workers, since],
        [timeout: @query_timeout, log: false]
      ])

    by_task = Map.new(tasks, &{{worker_string(&1["worker"]), &1["schedule"]}, &1["key"]})
    single = single_worker_keys(tasks)

    rows
    |> Enum.flat_map(fn [id, worker, state, expr, attempted, completed, discarded, cancelled] ->
      key = task_key(by_task, single, worker, expr)
      run(key, id, state, attempted, completed, discarded, cancelled)
    end)
  end

  # A stored expression decides the entry exactly: a row from an old expression of the same
  # worker belongs to no current entry. Only a row with no expression at all (older Oban)
  # falls back to a worker that is scheduled once.
  defp task_key(by_task, _single, worker, expr) when is_binary(expr),
    do: Map.get(by_task, {worker, String.trim(expr)})

  defp task_key(_by_task, single, worker, nil), do: Map.get(single, worker)

  # Workers scheduled once can be matched on worker alone when the stored expression is
  # absent (older Oban versions).
  defp single_worker_keys(tasks) do
    tasks
    |> Enum.group_by(&worker_string(&1["worker"]))
    |> Enum.flat_map(fn
      {worker, [task]} -> [{worker, task["key"]}]
      _ -> []
    end)
    |> Map.new()
  end

  defp worker_string(worker),
    do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp run(nil, _id, _state, _attempted, _completed, _discarded, _cancelled), do: []

  defp run(key, id, state, attempted, completed, discarded, cancelled) do
    base = %{"key" => key, "run_id" => "oban-#{id}", "started_at" => iso(attempted)}

    case state do
      "completed" -> [Map.merge(base, %{"finished_at" => iso(completed), "result" => "success"})]
      "discarded" -> [Map.merge(base, %{"finished_at" => iso(discarded), "result" => "fail"})]
      "cancelled" -> [Map.merge(base, %{"finished_at" => iso(cancelled), "result" => "fail"})]
      _ -> [Map.merge(base, %{"finished_at" => nil, "result" => "running"})]
    end
  end

  defp iso(nil), do: nil

  defp iso(%NaiveDateTime{} = at),
    do:
      at
      |> NaiveDateTime.truncate(:second)
      |> DateTime.from_naive!("Etc/UTC")
      |> DateTime.to_iso8601()
end
