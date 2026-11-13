defmodule UpstatePhoenix.Health do
  @moduledoc """
  Builds the schema 1 response. Every section catches its own errors and reports `nil`,
  so one failing check never hides the others. A database that does not answer reports
  `database.ok: false` and the status is 503.

  Sections that only make sense for Rails (`rails`, `ruby`, `puma`, `active_record_pool`,
  `cache`, `actions`) are omitted.
  """

  alias UpstatePhoenix.{Database, Jobs, Recurring}

  @schema 1

  @doc "Returns `{http_status, body}` for the resolved config (see `UpstatePhoenix.Config`)."
  def call(config, now \\ DateTime.utc_now()) do
    tasks = [
      Task.async(fn -> section(fn -> Database.call(config.repos) end) end),
      Task.async(fn -> section(fn -> Jobs.call(config, now) end) end),
      Task.async(fn -> section(fn -> Recurring.call(config, now) end) end)
    ]

    results = Task.yield_many(tasks, 2_000)

    [database, jobs, recurring] =
      Enum.map(results, fn {task, result} ->
        case result || Task.shutdown(task, :brutal_kill) do
          {:ok, value} -> value
          _ -> nil
        end
      end)

    body = %{
      "schema" => @schema,
      "version" => version(),
      "reporter" => %{"name" => "upstate_phoenix", "version" => UpstatePhoenix.version()},
      "phoenix" => section(fn -> phoenix(config) end),
      "booted_at" => booted_at(),
      "database" => database,
      "jobs" => jobs
    }

    body = if recurring, do: Map.put(body, "recurring", recurring), else: body

    status = if match?(%{"ok" => false}, database), do: 503, else: 200
    {status, body}
  end

  @doc false
  def section(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp version do
    ["APP_VERSION", "KAMAL_VERSION"]
    |> Enum.map(&(System.get_env(&1) || ""))
    |> Enum.map(&String.trim/1)
    |> Enum.find("unknown", &(&1 != ""))
  end

  defp phoenix(config) do
    %{
      "version" => app_version(:phoenix),
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "environment" => config.environment
    }
  end

  defp app_version(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  # When this VM started, computed once from its wall-clock uptime.
  defp booted_at do
    case :persistent_term.get({__MODULE__, :booted_at}, nil) do
      nil ->
        {uptime_ms, _} = :erlang.statistics(:wall_clock)

        at =
          DateTime.utc_now()
          |> DateTime.add(-uptime_ms, :millisecond)
          |> DateTime.truncate(:second)
          |> DateTime.to_iso8601()

        :persistent_term.put({__MODULE__, :booted_at}, at)
        at

      at ->
        at
    end
  end
end
