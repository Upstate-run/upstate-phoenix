defmodule UpstatePhoenix.Runtime do
  @moduledoc """
  The `beam` and `ecto_pool` sections: process facts about the running VM, never
  application data.

  `beam` is `run_queue`, `schedulers_online`, `scheduler_utilization` (0..1, or `nil`),
  `memory_bytes`, `process_count` and `process_limit`. Utilization is the average across
  schedulers since the previous report, from scheduler wall time (switched on by the supervised collector process, never by a request); the first report after
  boot, or a report with no earlier sample, sends `nil`.

  `ecto_pool` describes the first configured repo only (the same repo the `database`
  statistics come from): `size` is its configured `:pool_size`, `queue_time_ms_p95` is the
  95th percentile of the queue time (the wait for a pooled connection) of its last 256
  queries seen by Ecto query telemetry, and `busy` is always `nil` because DBConnection
  does not expose the checked-out count publicly. Without queries yet, the p95 is `nil`.
  """

  @table :upstate_phoenix_runtime
  @ring 256
  @min_sample_ms 5_000

  @doc false
  # Called from the long-lived `UpstatePhoenix.Actions` process. Scheduler wall time is a
  # node-wide switch kept on by a per-process counter that disappears with its process, so
  # it must be enabled here and never in a request process (`:scheduler.sample/0` would
  # enable it in the caller, and turn it off again when that process exits). If this
  # process restarts, the new one enables it again; the node stays enabled while any owner
  # lives.
  def create_table do
    enable_wall_time()
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
  end

  @doc false
  def enable_wall_time do
    :erlang.system_flag(:scheduler_wall_time, true)
    :ok
  rescue
    _ -> :ok
  end

  @doc "Returns the `beam` section."
  def beam do
    %{
      "run_queue" => :erlang.statistics(:run_queue),
      "schedulers_online" => :erlang.system_info(:schedulers_online),
      "scheduler_utilization" => utilization(),
      "memory_bytes" => :erlang.memory(:total),
      "process_count" => :erlang.system_info(:process_count),
      "process_limit" => :erlang.system_info(:process_limit)
    }
  end

  @doc "Returns the `ecto_pool` section for the first repo, or nil with no repos."
  def ecto_pool([]), do: nil

  def ecto_pool([first | _]) do
    repo = repo_module(first)

    %{
      "size" => section(fn -> pool_size(repo) end),
      "queue_time_ms_p95" => section(fn -> queue_p95(repo) end),
      "busy" => nil
    }
  end

  @doc false
  # Records one query's pool queue time (native units) in the repo's ring.
  def record_queue_time(repo, native) when is_atom(repo) and is_integer(native) do
    if :ets.whereis(@table) != :undefined do
      n = :ets.update_counter(@table, {:n, repo}, 1, {{:n, repo}, 0})
      ms = System.convert_time_unit(native, :native, :microsecond) / 1000
      :ets.insert(@table, {{:q, repo, rem(n, @ring)}, ms})
    end

    :ok
  rescue
    _ -> :ok
  end

  def record_queue_time(_repo, _native), do: :ok

  defp queue_p95(repo) do
    if :ets.whereis(@table) == :undefined do
      nil
    else
      values = :ets.select(@table, [{{{:q, repo, :_}, :"$1"}, [], [:"$1"]}])

      case Enum.sort(values) do
        [] -> nil
        sorted -> sorted |> Enum.at(max(ceil(length(sorted) * 0.95) - 1, 0)) |> Float.round(3)
      end
    end
  end

  defp pool_size(repo) do
    case repo.config()[:pool_size] do
      size when is_integer(size) and size > 0 -> size
      _ -> nil
    end
  end

  defp utilization do
    if :ets.whereis(@table) == :undefined do
      nil
    else
      now = System.monotonic_time(:millisecond)
      current = sample()

      case :ets.lookup(@table, :sched_sample) do
        [{_, previous, at}] ->
          if current && now - at >= @min_sample_ms,
            do: :ets.insert(@table, {:sched_sample, current, now})

          compute(previous, current)

        [] ->
          if current, do: :ets.insert(@table, {:sched_sample, current, now})
          nil
      end
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # A tagged sample `:scheduler.utilization/2` accepts, read without enabling anything:
  # `nil` unless the collector process has switched scheduler wall time on.
  defp sample do
    case :scheduler.get_sample() do
      {:scheduler_wall_time, _} = sample -> sample
      _ -> nil
    end
  end

  defp compute(nil, _current), do: nil
  defp compute(_previous, nil), do: nil

  defp compute(previous, current) do
    {:total, util, _} = List.keyfind(:scheduler.utilization(previous, current), :total, 0)
    util |> min(1.0) |> max(0.0) |> Float.round(4)
  rescue
    _ -> nil
  end

  defp repo_module({repo, _opts}), do: repo
  defp repo_module(repo), do: repo

  defp section(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
