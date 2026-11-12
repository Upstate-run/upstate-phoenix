defmodule UpstatePhoenix.Database do
  @moduledoc """
  The `database` section: whether every configured repo answers, and whether any of them
  has migrations on disk that are not in its `schema_migrations` table.

  Only booleans and one number leave the app. Migration names, versions and paths are
  never sent. The check reads `schema_migrations` without taking the migration lock and
  never creates the table.

  For PostgreSQL, `UpstatePhoenix.DatabaseStats` adds size, connections, transaction,
  wraparound, replication and largest-table numbers for the first repo. They are collected
  concurrently with the migration check under short statement timeouts and left out on any
  other adapter or error; they never change `ok` or the status.
  """

  alias UpstatePhoenix.DatabaseStats

  @query_timeout 1_000
  @stats_timeout 900

  @doc """
  Returns nil without repos, else
  `%{"ok" => bool, "pending_migrations" => bool | nil}` plus the `DatabaseStats` fields
  that could be read.
  """
  def call([]), do: nil

  def call([{first, _} | _] = repos) do
    if Enum.all?(repos, fn {repo, _opts} -> reachable?(repo) end) do
      stats_task = Task.async(fn -> DatabaseStats.collect(first) end)
      pending = Enum.map(repos, fn {repo, opts} -> pending?(repo, opts) end)

      stats =
        case Task.yield(stats_task, @stats_timeout) || Task.shutdown(stats_task, :brutal_kill) do
          {:ok, %{} = stats} -> stats
          _ -> %{}
        end

      pending_migrations =
        cond do
          true in pending -> true
          Enum.all?(pending, &(&1 == false)) -> false
          true -> nil
        end

      Map.merge(stats, %{"ok" => true, "pending_migrations" => pending_migrations})
    else
      %{"ok" => false, "pending_migrations" => nil}
    end
  end

  defp reachable?(repo) do
    match?({:ok, _}, repo.query("SELECT 1", [], timeout: @query_timeout, log: false))
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp pending?(repo, opts) do
    task = Task.async(fn -> pending_query(repo, opts) end)

    case Task.yield(task, 500) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> nil
    end
  end

  defp pending_query(repo, opts) do
    if Code.ensure_loaded?(Ecto.Migrator) do
      paths =
        Keyword.get_lazy(opts, :migrations_paths, fn ->
          [apply(Ecto.Migrator, :migrations_path, [repo])]
        end)

      opts = [skip_table_creation: true, migration_lock: false, timeout: 500, pool_timeout: 500]

      if paths != [] do
        Ecto.Migrator
        |> apply(:migrations, [repo, paths, opts])
        |> Enum.any?(&match?({:down, _, _}, &1))
      end
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
