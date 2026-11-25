defmodule UpstatePhoenix.ActionsTest do
  use ExUnit.Case, async: false

  alias UpstatePhoenix.Actions

  # 2026-01-01 12:00:00 UTC is a minute boundary.
  @base 1_767_268_800
  @now @base + 120

  setup do
    Actions.reset()
    on_exit(&Actions.reset/0)
    :ok
  end

  defp minute_at(offset), do: @base + offset * 60

  defp rows do
    :upstate_phoenix_actions
    |> :ets.tab2list()
    |> Enum.reject(&match?({{:names, _}, _}, &1))
    |> Enum.map(fn row ->
      {_minute, name} = elem(row, 0)

      %{
        name: name,
        count: elem(row, 1),
        errors: elem(row, 2),
        total_us: elem(row, 3),
        db_us: elem(row, 4)
      }
    end)
  end

  defp snapshot, do: Actions.snapshot(@now)

  test "buckets use inclusive upper bounds with an unbounded last bucket" do
    assert Actions.bucket_index(0) == 0
    assert Actions.bucket_index(5) == 0
    assert Actions.bucket_index(5.1) == 1
    assert Actions.bucket_index(10_000) == 10
    assert Actions.bucket_index(10_000.5) == 11
  end

  test "rolls requests up per minute and name" do
    Actions.record("A.PostController#index", 4, 1, false, @base)
    Actions.record("A.PostController#index", 30, 4, false, @base + 5)
    Actions.record("A.PostController#index", 20_000, 2, true, @base + 10)

    assert [%{"minute" => "2026-01-01T12:00:00Z", "items" => [item]}] = snapshot()

    assert item == %{
             "name" => "A.PostController#index",
             "count" => 3,
             "errors" => 1,
             "duration_buckets" => [1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1],
             "db_ms" => 7
           }
  end

  test "reports only closed minutes in the last 15, ascending" do
    Actions.record("Old#a", 1, 0, false, minute_at(-20))
    Actions.record("Earlier#a", 1, 0, false, minute_at(-2))
    Actions.record("Closed#a", 1, 0, false, minute_at(1))
    Actions.record("Open#a", 1, 0, false, @now)

    assert Enum.map(snapshot(), &hd(&1["items"])["name"]) == ["Earlier#a", "Closed#a"]
  end

  test "keeps the top 10 per minute by total time" do
    for i <- 1..15, do: Actions.record("C#a#{i}", i * 10, 0, false, @base)

    [%{"items" => items}] = snapshot()
    assert length(items) == 10
    assert hd(items)["name"] == "C#a15"
    refute Enum.any?(items, &(&1["name"] == "C#a5"))
  end

  test "stores at most 200 names per minute" do
    for i <- 1..250, do: Actions.record("N#a#{i}", 1, 0, false, @base)
    Actions.record("N#a1", 1, 0, false, @base)
    Actions.record("Next#minute", 1, 0, false, minute_at(1))

    assert length(rows()) == 201

    # An admitted name keeps counting, and a new minute has its own allowance.
    assert [first, second] = snapshot()
    assert Enum.any?(first["items"], &(&1["name"] == "N#a1" and &1["count"] == 2))
    assert [%{"name" => "Next#minute"}] = second["items"]
  end

  test "names are clamped to the server's allowed characters and length" do
    Actions.record("Bad name/<script>é#x", 1, 0, false, @base)
    Actions.record(String.duplicate("a", 300), 1, 0, false, @base)
    Actions.record("", 1, 0, false, @base)

    [%{"items" => items}] = snapshot()
    names = Enum.map(items, & &1["name"])
    assert "Bad_name/_script__#x" in names
    assert Enum.all?(names, &Regex.match?(~r/\A[\w:#\/.\-]{1,200}\z/, &1))
    assert length(names) == 2
  end

  test "prune drops minutes older than 20" do
    Actions.record("Old#a", 1, 0, false, minute_at(-30))
    Actions.record("Keep#a", 1, 0, false, minute_at(-3))
    Actions.prune(@now)

    assert [%{name: "Keep#a"}] = rows()
  end

  describe "telemetry" do
    defmodule Repo do
      def config, do: []
    end

    defmodule PostController do
    end

    defmodule Forwarded do
    end

    defmodule LiveIndex do
    end

    setup do
      Actions.attach([UpstatePhoenix.ActionsTest.Repo])
      :ok
    end

    defp dispatch(metadata, work \\ fn -> :ok end) do
      :telemetry.execute([:phoenix, :router_dispatch, :start], %{system_time: 0}, metadata)
      work.()
      :telemetry.execute([:phoenix, :router_dispatch, :stop], %{duration: 2_000_000}, metadata)
    end

    test "a controller route is Controller#action with its duration" do
      dispatch(%{plug: PostController, plug_opts: :index, conn: %Plug.Conn{status: 200}})

      assert [%{name: name, count: 1, errors: 0, total_us: total_us, db_us: 0}] = rows()
      assert name == "UpstatePhoenix.ActionsTest.PostController#index"
      assert total_us == 2000
    end

    test "a LiveView route is the LiveView module plus the live action" do
      conn = %Plug.Conn{
        status: 200,
        private: %{phoenix_live_view: {LiveIndex, [action: :edit], %{}}}
      }

      dispatch(%{plug: Phoenix.LiveView.Plug, plug_opts: :edit, conn: conn})

      assert [%{name: "UpstatePhoenix.ActionsTest.LiveIndex#edit", count: 1}] = rows()
    end

    test "a 5xx response and an exception both count as errors" do
      dispatch(%{plug: PostController, plug_opts: :show, conn: %Plug.Conn{status: 503}})

      metadata = %{plug: PostController, plug_opts: :show, conn: %Plug.Conn{status: 200}}
      :telemetry.execute([:phoenix, :router_dispatch, :start], %{system_time: 0}, metadata)

      :telemetry.execute(
        [:phoenix, :router_dispatch, :exception],
        %{duration: 1_000_000},
        Map.merge(metadata, %{kind: :error, reason: :boom, stacktrace: []})
      )

      dispatch(%{plug: PostController, plug_opts: :show, conn: %Plug.Conn{status: 404}})

      assert [%{count: 3, errors: 2}] = rows()
    end

    test "database time from the request process is attributed; other time is not" do
      query = fn us ->
        :telemetry.execute(
          [:upstate_phoenix, :actions_test, :repo, :query],
          %{query_time: us, decode_time: 0, queue_time: 0, total_time: us},
          %{}
        )
      end

      native = fn ms -> System.convert_time_unit(ms, :millisecond, :native) end

      query.(native.(50))

      dispatch(%{plug: PostController, plug_opts: :index, conn: %Plug.Conn{status: 200}}, fn ->
        query.(native.(30))
        query.(native.(12))
        Task.async(fn -> query.(native.(1000)) end) |> Task.await()
      end)

      assert [%{count: 1, db_us: db_us}] = rows()
      assert_in_delta db_us, 42_000, 1
      assert Process.get(:upstate_phoenix_action_db) == nil
    end

    test "a forwarded (nested) dispatch counts once, innermost action, all database time" do
      query = fn ms ->
        us = System.convert_time_unit(ms, :millisecond, :native)

        :telemetry.execute(
          [:upstate_phoenix, :actions_test, :repo, :query],
          %{query_time: us, decode_time: 0, queue_time: 0, total_time: us},
          %{}
        )
      end

      outer = %{plug: Forwarded, plug_opts: [], conn: %Plug.Conn{status: 200}}
      inner = %{plug: PostController, plug_opts: :index, conn: %Plug.Conn{status: 200}}

      :telemetry.execute([:phoenix, :router_dispatch, :start], %{system_time: 0}, outer)
      query.(10)
      :telemetry.execute([:phoenix, :router_dispatch, :start], %{system_time: 0}, inner)
      query.(20)
      :telemetry.execute([:phoenix, :router_dispatch, :stop], %{duration: 1_000_000}, inner)
      query.(5)
      :telemetry.execute([:phoenix, :router_dispatch, :stop], %{duration: 3_000_000}, outer)

      assert [%{name: name, count: 1, errors: 0, total_us: 3000, db_us: db_us}] = rows()
      assert name == "UpstatePhoenix.ActionsTest.PostController#index"
      assert_in_delta db_us, 35_000, 1
      assert Process.get(:upstate_phoenix_action_db) == nil
    end

    test "repos passed to the plug get query telemetry, once" do
      defmodule PlugRepo do
        def config, do: [telemetry_prefix: [:plug_repo_test]]
      end

      handlers = fn ->
        for %{id: id} <- :telemetry.list_handlers([:plug_repo_test, :query]), do: id
      end

      assert handlers.() == []
      opts = [repos: [PlugRepo], otp_app: :plug_repo_test_app]
      Actions.ensure_repos(opts)
      Actions.ensure_repos(opts)
      Actions.attach_repos([PlugRepo])
      assert [_one] = handlers.()

      # A collector restart re-runs attach/0; plug-registered handlers survive it.
      Actions.attach()
      assert [_still_one] = handlers.()

      :telemetry.execute(
        [:plug_repo_test, :query],
        %{query_time: System.convert_time_unit(7, :millisecond, :native)},
        %{}
      )

      dispatch(%{plug: PostController, plug_opts: :index, conn: %Plug.Conn{status: 200}}, fn ->
        :telemetry.execute(
          [:plug_repo_test, :query],
          %{query_time: System.convert_time_unit(9, :millisecond, :native)},
          %{}
        )
      end)

      assert [%{db_us: db_us}] = rows()
      assert_in_delta db_us, 9000, 1
      for id <- handlers.(), do: :telemetry.detach(id)
    end
  end
end
