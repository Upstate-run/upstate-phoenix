defmodule UpstatePhoenix.PlugTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Ecto.Adapters.SQL.Sandbox
  alias UpstatePhoenix.TestRepo

  @token "uph_test_token_0123456789"
  @migrations Path.expand("../support/migrations", __DIR__)
  @repos [{TestRepo, migrations_paths: [@migrations]}]
  @opts UpstatePhoenix.Plug.init(repos: @repos, oban: UpstatePhoenix.TestOban)

  setup do
    :ok = Sandbox.checkout(TestRepo)
    Sandbox.mode(TestRepo, {:shared, self()})

    for var <- ~w(UPSTATE_HEALTH_TOKEN APP_VERSION KAMAL_VERSION) do
      previous = System.get_env(var)
      System.delete_env(var)

      on_exit(fn ->
        if previous, do: System.put_env(var, previous), else: System.delete_env(var)
      end)
    end

    Application.delete_env(:upstate_phoenix, :token)
    on_exit(fn -> Application.delete_env(:upstate_phoenix, :token) end)
    :ok
  end

  defp health(opts \\ @opts, token \\ @token) do
    conn(:get, "/upstate/health")
    |> then(&if(token, do: put_req_header(&1, "authorization", "Bearer " <> token), else: &1))
    |> UpstatePhoenix.Plug.call(opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp enable, do: System.put_env("UPSTATE_HEALTH_TOKEN", @token)

  describe "auth" do
    test "without a configured token the endpoint is not installed (404)" do
      conn = health()
      assert conn.status == 404
      assert conn.halted
      assert conn.resp_body == ""
    end

    test "a blank token counts as not configured" do
      System.put_env("UPSTATE_HEALTH_TOKEN", "   ")
      assert health().status == 404
    end

    test "missing, wrong, non-bearer and oversized tokens get 401" do
      enable()

      for conn <- [
            health(@opts, nil),
            health(@opts, "wrong"),
            health(@opts, ""),
            health(@opts, String.duplicate("a", 257)),
            conn(:get, "/upstate/health")
            |> put_req_header("authorization", "Basic " <> @token)
            |> UpstatePhoenix.Plug.call(@opts)
          ] do
        assert conn.status == 401
        assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
        assert conn.resp_body == ""
      end
    end

    test "the right token gets 200 JSON that is never cached" do
      enable()
      conn = health()
      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
    end

    test "the token can come from app config" do
      Application.put_env(:upstate_phoenix, :token, @token)
      assert health().status == 200
    end

    test "other paths pass through untouched" do
      enable()
      conn = conn(:get, "/upstate/healthz") |> UpstatePhoenix.Plug.call(@opts)
      refute conn.halted
      assert conn.status == nil

      conn = conn(:get, "/") |> UpstatePhoenix.Plug.call(@opts)
      refute conn.halted
    end

    test "non-GET methods are refused after the token check is configured" do
      enable()

      conn =
        conn(:post, "/upstate/health")
        |> put_req_header("authorization", "Bearer " <> @token)
        |> UpstatePhoenix.Plug.call(@opts)

      assert conn.status == 405
    end
  end

  describe "response shape" do
    setup do
      enable()
      :ok
    end

    test "schema 1 with version, reporter, phoenix facts and booted_at" do
      System.put_env("APP_VERSION", "abc123")
      body = json(health())

      assert body["schema"] == 1
      assert body["version"] == "abc123"

      assert body["reporter"] == %{
               "name" => "upstate_phoenix",
               "version" => UpstatePhoenix.version()
             }

      assert %{"elixir" => elixir, "otp" => otp, "environment" => "test"} = body["phoenix"]
      assert elixir == System.version()
      assert otp == System.otp_release()
      assert Map.has_key?(body["phoenix"], "version")

      assert {:ok, booted, 0} = DateTime.from_iso8601(body["booted_at"])
      assert DateTime.compare(booted, DateTime.utc_now()) != :gt
      assert body["booted_at"] == json(health())["booted_at"]

      for key <- ~w(rails ruby puma active_record_pool cache solid_queue) do
        refute Map.has_key?(body, key), "#{key} should be omitted"
      end
    end

    test "beam and ecto_pool report runtime facts, numbers only" do
      first = json(health())["beam"]
      assert first["scheduler_utilization"] == nil or is_float(first["scheduler_utilization"])

      beam = json(health())["beam"]
      assert is_integer(beam["run_queue"]) and beam["run_queue"] >= 0
      assert beam["schedulers_online"] == :erlang.system_info(:schedulers_online)
      assert is_integer(beam["memory_bytes"]) and beam["memory_bytes"] > 0
      assert is_integer(beam["process_count"]) and beam["process_count"] > 0
      assert beam["process_limit"] >= beam["process_count"]
      assert is_float(beam["scheduler_utilization"])
      assert beam["scheduler_utilization"] >= 0 and beam["scheduler_utilization"] <= 1

      assert %{"size" => size, "busy" => nil} = json(health())["ecto_pool"]
      assert is_integer(size) and size > 0
    end

    test "scheduler wall time is owned by the collector, not by request processes" do
      assert is_list(:erlang.statistics(:scheduler_wall_time))

      # Each report runs in a short-lived process that exits afterwards.
      report = fn -> Task.async(&UpstatePhoenix.Runtime.beam/0) |> Task.await() end
      report.()
      assert is_float(report.()["scheduler_utilization"])

      # Still measuring after those processes are gone.
      assert is_list(:erlang.statistics(:scheduler_wall_time))
    end

    test "a restarted collector re-enables scheduler wall time" do
      old = Process.whereis(UpstatePhoenix.Actions)
      ref = Process.monitor(old)
      Process.exit(old, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}

      wait = fn wait ->
        pid = Process.whereis(UpstatePhoenix.Actions)

        if pid && pid != old && :ets.whereis(:upstate_phoenix_runtime) != :undefined,
          do: :ok,
          else:
            (
              Process.sleep(10)
              wait.(wait)
            )
      end

      wait.(wait)
      assert is_list(:erlang.statistics(:scheduler_wall_time))
      UpstatePhoenix.Runtime.beam()
      assert is_float(UpstatePhoenix.Runtime.beam()["scheduler_utilization"])
    end

    test "scheduler utilization is above zero after busy work between reports" do
      UpstatePhoenix.Runtime.beam()
      deadline = System.monotonic_time(:millisecond) + 200
      spin = fn spin -> if System.monotonic_time(:millisecond) < deadline, do: spin.(spin) end
      spin.(spin)

      assert UpstatePhoenix.Runtime.beam()["scheduler_utilization"] > 0
    end

    test "ecto_pool queue time p95 comes from query telemetry for the first repo" do
      # Earlier tests leave samples in the shared ring; start from an empty one.
      :ets.match_delete(:upstate_phoenix_runtime, {{:q, TestRepo, :_}, :_})
      :ets.delete(:upstate_phoenix_runtime, {:n, TestRepo})

      for ms <- 1..100 do
        UpstatePhoenix.Runtime.record_queue_time(
          TestRepo,
          System.convert_time_unit(ms * 1000, :microsecond, :native)
        )
      end

      assert %{"queue_time_ms_p95" => p95} = json(health())["ecto_pool"]
      assert p95 >= 90 and p95 <= 100
    end

    test "ecto_pool is omitted with no repos and a failing section reports null" do
      assert UpstatePhoenix.Runtime.ecto_pool([]) == nil

      assert %{"size" => nil, "queue_time_ms_p95" => nil, "busy" => nil} =
               UpstatePhoenix.Runtime.ecto_pool([NoSuchRepo])

      assert UpstatePhoenix.Health.section(fn -> raise "boom" end) == nil
    end

    test "actions is the closed-minute rollup, empty with no traffic" do
      UpstatePhoenix.Actions.reset()
      assert json(health())["actions"] == []

      now = System.os_time(:second)
      UpstatePhoenix.Actions.record("MyAppWeb.PostController#index", 12, 3, false, now - 120)
      on_exit(&UpstatePhoenix.Actions.reset/0)

      assert [%{"minute" => minute, "items" => [item]}] = json(health())["actions"]
      assert {:ok, _, 0} = DateTime.from_iso8601(minute)
      assert %{"name" => "MyAppWeb.PostController#index", "count" => 1, "errors" => 0} = item
      assert item["db_ms"] == 3
      assert length(item["duration_buckets"]) == 12
    end

    test "version falls back to KAMAL_VERSION, then unknown" do
      System.put_env("KAMAL_VERSION", "kamal-7")
      assert json(health())["version"] == "kamal-7"

      System.delete_env("KAMAL_VERSION")
      assert json(health())["version"] == "unknown"
    end

    test "the environment option is reported" do
      opts = UpstatePhoenix.Plug.init(repos: @repos, oban: false, environment: :prod)
      assert json(health(opts))["phoenix"]["environment"] == "prod"
    end
  end

  test "a blocked repo cannot consume the observer budget or hide jobs" do
    enable()
    Application.put_env(:upstate_phoenix, :budget_test_owner, self())
    on_exit(fn -> Application.delete_env(:upstate_phoenix, :budget_test_owner) end)
    started = System.monotonic_time(:millisecond)
    result = health(repos: [{UpstatePhoenix.BlockedRepo, []}], oban: false)
    assert System.monotonic_time(:millisecond) - started < 2_800
    assert json(result)["database"] == nil
    assert json(result)["jobs"]["adapter"] == "none"
    assert_receive {:blocked_query, pid}
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  test "documented production SSL exclusion lets private health requests reach the authenticated plug" do
    enable()

    ssl =
      Plug.SSL.init(
        rewrite_on: [:x_forwarded_proto],
        exclude: [hosts: ["localhost", "127.0.0.1"], paths: ["/up", "/upstate/health"]]
      )

    response =
      conn(:get, "http://172.17.0.2/upstate/health")
      |> put_req_header("authorization", "Bearer " <> @token)
      |> Plug.SSL.call(ssl)
      |> UpstatePhoenix.Plug.call(@opts)

    assert response.status == 200
    redirected = conn(:get, "http://app.example.com/app") |> Plug.SSL.call(ssl)
    assert redirected.status == 301
    assert get_resp_header(redirected, "location") == ["https://app.example.com/app"]
  end

  describe "database" do
    setup do
      enable()
      :ok
    end

    test "ok with no pending migrations when every file is applied" do
      database = json(health())["database"]
      assert %{"ok" => true, "pending_migrations" => false, "size_bytes" => size} = database
      assert is_integer(size) and size > 0
    end

    test "external schema ownership keeps reachability but reports unknown migrations" do
      opts = UpstatePhoenix.Plug.init(repos: [{TestRepo, migrations_paths: []}], oban: false)
      response = health(opts)
      assert response.status == 200

      assert %{"ok" => true, "pending_migrations" => nil, "size_bytes" => _} =
               json(response)["database"]
    end

    test "pending migrations when a file on disk is not applied" do
      dir = Path.join(System.tmp_dir!(), "upstate_phoenix_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.cp!(Path.join(@migrations, "1_add_oban.exs"), Path.join(dir, "1_add_oban.exs"))
      File.write!(Path.join(dir, "20991231000000_not_yet.exs"), "# never compiled")
      on_exit(fn -> File.rm_rf!(dir) end)

      opts = UpstatePhoenix.Plug.init(repos: [{TestRepo, migrations_paths: [dir]}], oban: false)
      body = json(health(opts))

      assert %{"ok" => true, "pending_migrations" => true} = body["database"]
      refute health(opts).resp_body =~ "not_yet"
    end

    test "a database that does not answer reports ok false and 503, with the rest intact" do
      opts = UpstatePhoenix.Plug.init(repos: [UpstatePhoenix.DownRepo], oban: false)
      conn = health(opts)

      assert conn.status == 503
      body = json(conn)
      assert body["database"] == %{"ok" => false, "pending_migrations" => nil}
      assert body["schema"] == 1
      assert is_map(body["phoenix"])
      assert body["jobs"]["adapter"] == "none"
    end

    test "database health numbers come from PostgreSQL, aggregate only" do
      %{rows: [[expected]]} =
        TestRepo.query!("SELECT pg_database_size(current_database())", [], log: false)

      database = json(health())["database"]
      # The database can grow between the two reads (Oban, other tests).
      assert database["size_bytes"] >= div(expected, 2) and database["size_bytes"] <= expected * 2

      assert %{"in_use" => in_use, "max" => max} = database["connections"]
      assert in_use >= 1 and max >= in_use
      assert is_integer(database["oldest_transaction_age_seconds"])
      assert is_integer(database["idle_in_transaction"])
      assert is_integer(database["xid_age"]) and database["xid_age"] > 0
      # A standalone test server has no replicas: the section is left out.
      refute Map.has_key?(database, "replication")

      allowed =
        ~w(ok pending_migrations size_bytes connections oldest_transaction_age_seconds idle_in_transaction xid_age largest_tables)

      assert Map.keys(database) -- allowed == []
    end

    test "the largest tables carry a name and three numbers, never row data" do
      TestRepo.query!("ANALYZE oban_jobs", [], log: false)
      tables = json(health())["database"]["largest_tables"]
      assert is_list(tables) and length(tables) in 1..5

      for table <- tables do
        assert Map.keys(table) |> Enum.sort() == ~w(dead_rows live_rows name total_bytes)
        assert is_binary(table["name"]) and String.contains?(table["name"], ".")
      end

      assert Enum.any?(tables, &(&1["name"] == "public.oban_jobs"))
    end

    test "collecting inside a caller's transaction leaves it usable" do
      assert {:ok, {%{"size_bytes" => _}, %{rows: [[1]]}}} =
               TestRepo.transaction(fn ->
                 TestRepo.query!("SET LOCAL statement_timeout = 5000", [], log: false)
                 before = TestRepo.query!("SHOW statement_timeout", [], log: false).rows
                 stats = UpstatePhoenix.DatabaseStats.collect(TestRepo)
                 assert TestRepo.query!("SHOW statement_timeout", [], log: false).rows == before
                 {stats, TestRepo.query!("SELECT 1", [], log: false)}
               end)
    end

    test "a repo that is not PostgreSQL, or that does not answer, adds nothing" do
      assert UpstatePhoenix.DatabaseStats.collect(UpstatePhoenix.BlockedRepo) == %{}
      assert UpstatePhoenix.DatabaseStats.collect(UpstatePhoenix.DownRepo) == %{}
    end

    test "no repos means no database section" do
      opts = UpstatePhoenix.Plug.init(repos: [], oban: false)
      conn = health(opts)
      assert conn.status == 200
      assert json(conn)["database"] == nil
    end

    test "repos default to the otp_app's :ecto_repos" do
      Application.put_env(:upstate_phoenix_host, :ecto_repos, [TestRepo])
      on_exit(fn -> Application.delete_env(:upstate_phoenix_host, :ecto_repos) end)

      config = UpstatePhoenix.Config.resolve(otp_app: :upstate_phoenix_host)
      assert config.repos == [{TestRepo, []}]
    end
  end

  describe "oban jobs" do
    setup do
      enable()
      :ok
    end

    defp insert_job(state, times, overrides \\ %{}) do
      now = NaiveDateTime.utc_now()
      at = fn seconds_ago -> seconds_ago && NaiveDateTime.add(now, -seconds_ago, :second) end

      row =
        Map.merge(
          %{
            state: state,
            queue: "default",
            worker: "MyApp.Worker",
            args: %{},
            attempt: if(state in ~w(available scheduled), do: 0, else: 1),
            max_attempts: 20,
            inserted_at: now,
            scheduled_at: at.(Keyword.get(times, :scheduled, 0)),
            attempted_at: at.(Keyword.get(times, :attempted)),
            completed_at: at.(Keyword.get(times, :completed)),
            discarded_at: at.(Keyword.get(times, :discarded))
          },
          overrides
        )

      TestRepo.insert_all("oban_jobs", [row])
    end

    test "quoted tenant prefixes and prefix false honor the intended schema" do
      prefix = "health-tenant-#{System.unique_integer([:positive])}"

      Sandbox.unboxed_run(TestRepo, fn ->
        TestRepo.query!(~s|CREATE SCHEMA "#{prefix}"|)

        TestRepo.query!(
          ~s|CREATE TABLE "#{prefix}".oban_jobs (LIKE public.oban_jobs INCLUDING ALL)|
        )

        %{rows: [[version]]} =
          TestRepo.query!("SELECT obj_description('public.oban_jobs'::regclass)")

        TestRepo.query!(~s|COMMENT ON TABLE "#{prefix}".oban_jobs IS '#{version}'|)
      end)

      on_exit(fn ->
        Sandbox.unboxed_run(TestRepo, fn ->
          TestRepo.query!(~s|DROP SCHEMA "#{prefix}" CASCADE|)
        end)
      end)

      :ok = Sandbox.checkout(TestRepo)
      Sandbox.mode(TestRepo, {:shared, self()})
      insert_job("available", scheduled: 10)

      start_supervised!(
        {Oban, name: UpstatePhoenix.TenantOban, repo: TestRepo, testing: :manual, prefix: prefix}
      )

      assert json(health(repos: @repos, oban: UpstatePhoenix.TenantOban))["jobs"]["queue_depth"] ==
               0

      TestRepo.query!(~s|SET LOCAL search_path TO "#{prefix}"|)

      # Oban 2.24's boot-time migration verifier rejects false, even though
      # its config contract supports it. Exercise the collector with that
      # supported config without invoking the unrelated boot verifier.
      for disabled_prefix <- [false, nil] do
        config = %{Oban.config(UpstatePhoenix.TenantOban) | prefix: disabled_prefix}
        assert UpstatePhoenix.Jobs.collect(config, DateTime.utc_now())["queue_depth"] == 0
      end
    end

    test "uses the configured Oban dynamic repository callback" do
      owner = self()

      start_supervised!(
        {Oban,
         name: UpstatePhoenix.DynamicOban,
         repo: TestRepo,
         testing: :manual,
         get_dynamic_repo: fn ->
           send(owner, :dynamic_repo_used)
           TestRepo
         end}
      )

      insert_job("available", scheduled: 10)
      result = health(repos: @repos, oban: UpstatePhoenix.DynamicOban)
      assert json(result)["jobs"]["queue_depth"] == 1
      assert_receive :dynamic_repo_used
    end

    test "queues, served_queues and classes come from oban_jobs and the running config" do
      # Oban's :manual testing mode clears `:queues`, so give the collector a config that
      # looks like a running node.
      start_supervised!({Oban, name: UpstatePhoenix.QueuesOban, repo: TestRepo, testing: :manual})

      config = %{
        Oban.config(UpstatePhoenix.QueuesOban)
        | queues: [default: 10, mailers: [limit: 3], idle: 1]
      }

      insert_job("available", scheduled: 120)
      insert_job("available", [scheduled: 10], %{queue: "mailers"})
      insert_job("available", [scheduled: 10], %{queue: "other"})
      insert_job("scheduled", scheduled: -600)

      insert_job("completed", [scheduled: 100, attempted: 90, completed: 88], %{
        worker: "MyApp.Mailer"
      })

      insert_job("completed", [scheduled: 100, attempted: 90, completed: 86], %{
        worker: "MyApp.Mailer"
      })

      insert_job("completed", scheduled: 1000, attempted: 990, completed: 900)

      insert_job("discarded", [scheduled: 100, attempted: 80, discarded: 80], %{
        worker: "MyApp.Mailer"
      })

      insert_job("retryable", scheduled: -60, attempted: 40)
      insert_job("available", [scheduled: 5], %{queue: String.duplicate("q", 121)})

      jobs = UpstatePhoenix.Jobs.collect(config, DateTime.utc_now())

      assert [%{"name" => "default", "depth" => 1, "concurrency" => 10} = default | rest] =
               jobs["queues"]

      assert default["oldest_queued_age_seconds"] in 119..122
      assert %{"depth" => 1, "concurrency" => 3} = Enum.find(rest, &(&1["name"] == "mailers"))
      assert %{"depth" => 1, "concurrency" => nil} = Enum.find(rest, &(&1["name"] == "other"))

      assert %{"depth" => 0, "oldest_queued_age_seconds" => nil, "concurrency" => 1} =
               Enum.find(rest, &(&1["name"] == "idle"))

      assert jobs["served_queues"] == %{"all" => false, "names" => ["default", "idle", "mailers"]}

      mailer = Enum.find(jobs["classes"], &(&1["name"] == "MyApp.Mailer"))
      assert mailer["processed_last_5m"] == 2
      assert mailer["failed_last_5m"] == 1
      assert mailer["duration_ms_avg"] in 3_000..5_000
      assert mailer["duration_ms_max"] in 3_000..5_000
      assert hd(jobs["classes"])["name"] == "MyApp.Mailer"

      other = Enum.find(jobs["classes"], &(&1["name"] == "MyApp.Worker"))
      assert other["processed_last_5m"] == 0
      assert other["failed_last_5m"] == 1
      refute Enum.any?(jobs["queues"], &(String.length(&1["name"]) > 120))
    end

    test "queues false serves no queues and a failing field is null on its own" do
      start_supervised!(
        {Oban, name: UpstatePhoenix.NoQueuesOban, repo: TestRepo, testing: :manual, queues: false}
      )

      jobs = json(health(repos: @repos, oban: UpstatePhoenix.NoQueuesOban))["jobs"]
      assert jobs["served_queues"] == %{"all" => false, "names" => []}
      assert jobs["queues"] == []
      assert jobs["classes"] == []

      config = %{Oban.config(UpstatePhoenix.NoQueuesOban) | queues: :bad}

      assert %{"served_queues" => %{"names" => []}} =
               UpstatePhoenix.Jobs.collect(config, DateTime.utc_now())

      # A missing table makes the whole section fail soundly; each new field is null on its own
      # when only its query fails.
      broken = %{Oban.config(UpstatePhoenix.NoQueuesOban) | prefix: "no_such_schema"}

      assert UpstatePhoenix.Health.section(fn ->
               UpstatePhoenix.Jobs.collect(broken, DateTime.utc_now())
             end) == nil
    end

    test "aggregate counts for depth, age, processed, failed and recent processing" do
      insert_job("available", scheduled: 120)
      insert_job("available", scheduled: 10)
      insert_job("scheduled", scheduled: 30)
      insert_job("scheduled", scheduled: -600)
      insert_job("executing", scheduled: 50, attempted: 5)
      insert_job("completed", scheduled: 100, attempted: 90, completed: 60)
      insert_job("completed", scheduled: 1000, attempted: 990, completed: 900)
      insert_job("discarded", scheduled: 100, attempted: 80, discarded: 80)
      insert_job("discarded", scheduled: 1000, attempted: 900, discarded: 900)
      insert_job("retryable", scheduled: -60, attempted: 40)
      insert_job("cancelled", scheduled: 10, attempted: 1)

      jobs = json(health())["jobs"]

      assert jobs["adapter"] == "oban"
      assert jobs["queue_depth"] == 3
      assert jobs["oldest_queued_age_seconds"] in 119..122
      assert jobs["processed_last_5m"] == 1
      assert jobs["failed_last_5m"] == 2
      assert jobs["workers"] == nil

      assert {:ok, recent, 0} = DateTime.from_iso8601(jobs["recent_processing_at"])
      assert DateTime.diff(DateTime.utc_now(), recent) in 0..3
    end

    test "an empty queue reports zeros and nil ages" do
      jobs = json(health())["jobs"]

      assert jobs == %{
               "adapter" => "oban",
               "queue_depth" => 0,
               "oldest_queued_age_seconds" => nil,
               "workers" => nil,
               "processed_last_5m" => 0,
               "failed_last_5m" => 0,
               "recent_processing_at" => nil,
               "queues" => [],
               "served_queues" => %{"all" => false, "names" => []},
               "classes" => []
             }
    end

    test "queue and worker names are sent, but never args, errors or meta" do
      insert_job("available", [scheduled: 5], %{
        queue: "secret_queue",
        worker: "SecretWorker",
        args: %{"email" => "SECRET@x.test"}
      })

      insert_job("discarded", [scheduled: 20, attempted: 10, discarded: 10], %{
        errors: [%{"error" => "SECRET-ERROR"}]
      })

      body = health().resp_body
      assert body =~ "secret_queue"
      refute body =~ "SECRET"
      refute body =~ @migrations
    end

    test "oban: false reports no job system" do
      opts = UpstatePhoenix.Plug.init(repos: @repos, oban: false)
      assert json(health(opts))["jobs"]["adapter"] == "none"
    end

    test "an Oban name that is not running reports no job system" do
      opts = UpstatePhoenix.Plug.init(repos: @repos, oban: NotRunningOban)
      assert json(health(opts))["jobs"]["adapter"] == "none"
    end

    test "a failing jobs query reports jobs as null and keeps 200" do
      # Hidden inside the sandbox transaction, so it is back after the test.
      TestRepo.query!("ALTER TABLE oban_jobs RENAME TO oban_jobs_hidden")
      conn = health()

      assert conn.status == 200
      body = json(conn)
      assert body["jobs"] == nil
      assert body["database"]["ok"] == true
    end
  end

  describe "private_host?/1" do
    test "private and loopback literals are private, public hosts are not" do
      for host <- ~w(localhost 10.0.1.4 172.18.0.3 192.168.1.9 127.0.0.1 ::1 [::1] fd00::1) do
        assert UpstatePhoenix.private_host?(host), host
      end

      for host <- ~w(example.com 8.8.8.8 172.32.0.1 2001:db8::1) ++ [nil] do
        refute UpstatePhoenix.private_host?(host), inspect(host)
      end
    end
  end
end
