defmodule UpstatePhoenix.RecurringTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Ecto.Adapters.SQL.Sandbox
  alias UpstatePhoenix.{Recurring, TestRepo}

  defmodule CleanupWorker do
    use Oban.Worker
    @impl true
    def perform(_job), do: :ok
  end

  defmodule SyncWorker do
    use Oban.Worker
    @impl true
    def perform(_job), do: :ok
  end

  @token "uph_test_token_0123456789"
  @cleanup "UpstatePhoenix.RecurringTest.CleanupWorker"

  setup do
    :ok = Sandbox.checkout(TestRepo)
    Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  defp config(crontab, plugin \\ Oban.Cron) do
    %{Oban.config(UpstatePhoenix.TestOban) | plugins: [{plugin, crontab: crontab}]}
  end

  defp insert_cron_job(worker, state, expr, times, extra_meta \\ %{}) do
    now = NaiveDateTime.utc_now()
    at = fn seconds_ago -> seconds_ago && NaiveDateTime.add(now, -seconds_ago, :second) end

    {1, [%{id: id}]} =
      TestRepo.insert_all(
        "oban_jobs",
        [
          %{
            state: state,
            queue: "secret_queue",
            worker: worker,
            args: %{"email" => "SECRET-JOB-ARG"},
            meta: Map.merge(%{"cron" => true, "cron_expr" => expr}, extra_meta),
            errors: [%{"error" => "boom SECRET-JOB-ARG"}],
            tags: ["pii"],
            attempt: 1,
            max_attempts: 3,
            inserted_at: at.(Keyword.get(times, :inserted, 120)),
            scheduled_at: at.(Keyword.get(times, :inserted, 120)),
            attempted_at: at.(Keyword.get(times, :attempted)),
            completed_at: at.(Keyword.get(times, :completed)),
            discarded_at: at.(Keyword.get(times, :discarded)),
            cancelled_at: at.(Keyword.get(times, :cancelled))
          }
        ],
        returning: [:id]
      )

    id
  end

  test "tasks: worker and schedule only, @reboot skipped, args never read" do
    config =
      config([
        {"0 3 * * *", CleanupWorker, args: %{"email" => "SECRET-JOB-ARG"}},
        {"*/10 * * * *", SyncWorker},
        {"@reboot", SyncWorker}
      ])

    section = Recurring.collect(config, DateTime.utc_now())

    assert section["adapter"] == "oban"

    assert section["tasks"] == [
             %{
               "key" => "#{@cleanup} (0 3 * * *)",
               "class_name" => @cleanup,
               "schedule" => "0 3 * * *"
             },
             %{
               "key" => "UpstatePhoenix.RecurringTest.SyncWorker (*/10 * * * *)",
               "class_name" => "UpstatePhoenix.RecurringTest.SyncWorker",
               "schedule" => "*/10 * * * *"
             }
           ]

    refute inspect(section) =~ "SECRET-JOB-ARG"
  end

  test "the deprecated Oban.Plugins.Cron module name is read too" do
    section =
      Recurring.collect(
        config([{"0 3 * * *", CleanupWorker}], Oban.Plugins.Cron),
        DateTime.utc_now()
      )

    assert [%{"schedule" => "0 3 * * *"}] = section["tasks"]
  end

  defp keys(crontab) do
    crontab
    |> config()
    |> Recurring.collect(DateTime.utc_now())
    |> Map.fetch!("tasks")
    |> Enum.map(& &1["key"])
  end

  test "keys depend only on the entry: not on count, order or position" do
    three = "#{@cleanup} (0 3 * * *)"
    fifteen = "#{@cleanup} (0 15 * * *)"

    assert keys([{"0 3 * * *", CleanupWorker}]) == [three]
    # one -> two keeps the first key; two -> one (either removed) keeps the survivor's key
    assert keys([{"0 3 * * *", CleanupWorker}, {"0 15 * * *", CleanupWorker}]) == [three, fifteen]
    assert keys([{"0 15 * * *", CleanupWorker}]) == [fifteen]
    # reordering changes nothing about which key an expression has
    assert keys([{"0 15 * * *", CleanupWorker}, {"0 3 * * *", CleanupWorker}]) == [fifteen, three]
  end

  test "an edited expression is a different job (new key)" do
    assert keys([{"0 3 * * *", CleanupWorker}]) != keys([{"0 4 * * *", CleanupWorker}])
  end

  test "rows from a previous expression of the worker are not the current entry's runs" do
    stale = insert_cron_job(@cleanup, "discarded", "0 1 * * *", attempted: 80, discarded: 70)
    current = insert_cron_job(@cleanup, "completed", "0 3 * * *", attempted: 80, completed: 70)

    legacy =
      insert_cron_job(@cleanup, "completed", "ignored", [attempted: 60, completed: 50], %{
        "cron_expr" => nil
      })

    section = Recurring.collect(config([{"0 3 * * *", CleanupWorker}]), DateTime.utc_now())
    ids = Enum.map(section["runs"], & &1["run_id"])

    assert "oban-#{current}" in ids
    assert "oban-#{legacy}" in ids
    refute "oban-#{stale}" in ids
  end

  test "a run still going is kept when ten newer runs finished" do
    old = insert_cron_job(@cleanup, "executing", "0 3 * * *", attempted: 5000)

    for n <- 1..12 do
      insert_cron_job(@cleanup, "completed", "0 3 * * *",
        attempted: 4000 - n,
        completed: 3000 - n
      )
    end

    section = Recurring.collect(config([{"0 3 * * *", CleanupWorker}]), DateTime.utc_now())
    runs = section["runs"]

    assert Enum.count(runs, &(&1["result"] == "success")) == 10
    assert Enum.any?(runs, &(&1["run_id"] == "oban-#{old}" and &1["result"] == "running"))
  end

  test "a running job older than 24 hours is kept, and so is its late completion" do
    day = 26 * 3600

    done =
      insert_cron_job(@cleanup, "completed", "0 3 * * *",
        inserted: day + 100,
        attempted: day,
        completed: 60
      )

    going =
      insert_cron_job(@cleanup, "executing", "0 3 * * *", inserted: day + 100, attempted: day)

    runs = Recurring.collect(config([{"0 3 * * *", CleanupWorker}]), DateTime.utc_now())["runs"]
    ids = Enum.map(runs, & &1["run_id"])

    assert "oban-#{done}" in ids
    assert "oban-#{going}" in ids
  end

  test "a frequent worker cannot hide a slower worker's completion" do
    daily = insert_cron_job(@cleanup, "completed", "0 3 * * *", attempted: 9000, completed: 8900)

    for n <- 1..600 do
      insert_cron_job(
        "UpstatePhoenix.RecurringTest.SyncWorker",
        "completed",
        "* * * * *",
        attempted: 1000 - div(n, 2),
        completed: 900 - div(n, 2)
      )
    end

    runs =
      Recurring.collect(
        config([{"0 3 * * *", CleanupWorker}, {"* * * * *", SyncWorker}]),
        DateTime.utc_now()
      )["runs"]

    assert Enum.any?(runs, &(&1["run_id"] == "oban-#{daily}" and &1["result"] == "success"))
    assert Enum.count(runs, &(&1["key"] =~ "SyncWorker")) == 10
  end

  test "fifty frequent entries cannot take every slot from a daily one" do
    daily = insert_cron_job(@cleanup, "completed", "0 3 * * *", attempted: 9000, completed: 8900)

    entries =
      for n <- 1..50 do
        expr = "#{n} * * * *"

        for k <- 1..12 do
          insert_cron_job("UpstatePhoenix.RecurringTest.SyncWorker", "completed", expr,
            attempted: 1000 - k,
            completed: 900 - k
          )
        end

        {expr, SyncWorker}
      end

    runs =
      Recurring.collect(config([{"0 3 * * *", CleanupWorker} | entries]), DateTime.utc_now())[
        "runs"
      ]

    assert Enum.any?(runs, &(&1["run_id"] == "oban-#{daily}"))
  end

  test "the Pruner's max_age is reported, nil without a Pruner" do
    with_pruner = fn plugin ->
      cfg = config([{"0 3 * * *", CleanupWorker}])
      %{cfg | plugins: [plugin | cfg.plugins]}
    end

    now = DateTime.utc_now()

    assert Recurring.collect(with_pruner.({Oban.Plugins.Pruner, max_age: 120}), now)[
             "prune_max_age_seconds"
           ] == 120

    # Oban's default is 60 seconds.
    assert Recurring.collect(with_pruner.(Oban.Plugins.Pruner), now)["prune_max_age_seconds"] ==
             60

    assert Recurring.collect(with_pruner.({Oban.Plugins.Pruner, max_age: :infinity}), now)[
             "prune_max_age_seconds"
           ] == nil

    assert Recurring.collect(config([{"0 3 * * *", CleanupWorker}]), now)["prune_max_age_seconds"] ==
             nil
  end

  test "Lite and Dolphin engines offer nothing, since their runs cannot be read" do
    for engine <- [Oban.Engines.Lite, Oban.Engines.Dolphin] do
      cfg = %{config([{"0 3 * * *", CleanupWorker}]) | engine: engine}
      assert Recurring.collect(cfg, DateTime.utc_now()) == nil
    end
  end

  test "a node without the cron plugin reports no recurring section" do
    assert Recurring.collect(
             %{Oban.config(UpstatePhoenix.TestOban) | plugins: []},
             DateTime.utc_now()
           ) ==
             nil

    assert Recurring.collect(nil, DateTime.utc_now()) == nil
    assert Recurring.call(%{oban: false}, DateTime.utc_now()) == nil
  end

  test "runs: start, end and result, correlated by job id, without args or errors" do
    done = insert_cron_job(@cleanup, "completed", "0 3 * * *", attempted: 100, completed: 90)
    failed = insert_cron_job(@cleanup, "discarded", "0 3 * * *", attempted: 80, discarded: 70)
    going = insert_cron_job(@cleanup, "executing", "0 3 * * *", attempted: 10)
    retrying = insert_cron_job(@cleanup, "retryable", "0 3 * * *", attempted: 5)
    cancelled = insert_cron_job(@cleanup, "cancelled", "0 3 * * *", attempted: 4, cancelled: 2)
    insert_cron_job(@cleanup, "cancelled", "0 3 * * *", [])
    # Not a cron job, a different expression and a different worker are all ignored.
    insert_cron_job(@cleanup, "completed", "0 3 * * *", [attempted: 100, completed: 90], %{
      "cron" => false
    })

    insert_cron_job(
      "UpstatePhoenix.RecurringTest.SyncWorker",
      "completed",
      "*/10 * * * *",
      attempted: 20,
      completed: 15
    )

    insert_cron_job("Some.Other.Worker", "completed", "* * * * *", attempted: 20, completed: 15)

    section = Recurring.collect(config([{"0 3 * * *", CleanupWorker}]), DateTime.utc_now())
    runs = Map.new(section["runs"], &{&1["run_id"], &1})

    assert Map.keys(runs) |> Enum.sort() ==
             Enum.sort(Enum.map([done, failed, going, retrying, cancelled], &"oban-#{&1}"))

    assert %{
             "result" => "success",
             "key" => "#{@cleanup} (0 3 * * *)",
             "started_at" => s,
             "finished_at" => f
           } =
             runs["oban-#{done}"]

    assert {:ok, started, 0} = DateTime.from_iso8601(s)
    assert {:ok, finished, 0} = DateTime.from_iso8601(f)
    assert DateTime.diff(finished, started) == 10
    assert %{"result" => "fail", "finished_at" => _} = runs["oban-#{failed}"]
    assert %{"result" => "running", "finished_at" => nil} = runs["oban-#{going}"]
    assert %{"result" => "running"} = runs["oban-#{retrying}"]
    assert %{"result" => "fail", "finished_at" => f2} = runs["oban-#{cancelled}"]
    assert is_binary(f2)

    encoded = Jason.encode!(section)
    refute encoded =~ "SECRET-JOB-ARG"
    refute encoded =~ "secret_queue"
    refute encoded =~ "boom"
    refute encoded =~ "pii"
  end

  test "the health response carries recurring only when cron is configured, additively" do
    System.put_env("UPSTATE_HEALTH_TOKEN", @token)
    on_exit(fn -> System.delete_env("UPSTATE_HEALTH_TOKEN") end)

    get = fn opts ->
      conn(:get, "/upstate/health")
      |> put_req_header("authorization", "Bearer " <> @token)
      |> UpstatePhoenix.Plug.call(UpstatePhoenix.Plug.init(opts))
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()
    end

    body = get.(repos: [], oban: UpstatePhoenix.TestOban)
    refute Map.has_key?(body, "recurring")
    assert body["schema"] == 1
    assert body["jobs"]["adapter"] == "oban"
  end
end
