defmodule UpstatePhoenix.Actions do
  @moduledoc """
  A bounded, in-memory rollup of Phoenix actions per minute, reported as `actions` in the
  health response. It stores only the action name, request and error counts, duration
  buckets, database milliseconds and total milliseconds. Never paths, parameters, query
  text, headers or user data.

  ## What is measured

  `[:phoenix, :router_dispatch, :start | :stop | :exception]` telemetry is the source, so
  the duration is the time spent in the router's pipelines and the controller or LiveView
  mount, not endpoint plugs before the router.

  The action name is the closest analogue of Rails' `Controller#action`:

    * a controller route is `MyAppWeb.PostController#index`;
    * a LiveView route is the LiveView module, plus `#live_action` when the route has one
      (`MyAppWeb.PostLive.Index#edit`);
    * any other plug routed to is its module name.

  Only the initial HTTP request of a LiveView is a router dispatch. Events and queries on
  the connected socket are not counted.

  A `forward` to another router dispatches twice in one process. Such a request is counted
  once: the action is the innermost (most specific) route that completed, the duration is
  the outermost dispatch's, and database time is everything the request spent.

  Phoenix emits `:start` before running a route's pipeline but emits `:stop` or
  `:exception` only once the pipeline has finished or the action ran. A request that
  raises inside a pipeline plug therefore produces no completion event, and is not counted
  here (the request is not recorded as a slow action or as an error). Reconstructing it
  would need endpoint-level exception handling that Phoenix does not expose as telemetry.

  An action counts as an error when it raises or the response status is 500 or higher.

  ## Database time

  `[..., :repo, :query]` Ecto telemetry runs in the process that issued the query. Between
  a request's `:start` and `:stop`, that process adds up query time, decode time and pool
  queue time, so `db_ms` is what the request waited on the database. Queries sent from
  other processes (a `Task`, for example) are not attributed. A repo is attached when it is
  listed in `config :upstate_phoenix, repos: [...]`, passed as `repos:` to
  `UpstatePhoenix.Plug`, or in any loaded application's `:ecto_repos`.

  ## Bounds

  The top 10 actions per minute by total time are reported, for the last 15 closed minutes.
  At most 200 distinct action names are kept per minute (further names are dropped), and
  minutes older than 20 minutes are discarded. The state is per VM, in ETS.
  """

  use GenServer

  @table :upstate_phoenix_actions
  @buckets_ms [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10_000]
  @bucket_count length(@buckets_ms) + 1
  @max_names 200
  @max_name_bytes 200
  @retain_minutes 20
  @window_minutes 15
  @top 10
  @prune_every :timer.seconds(30)
  @dispatch_id "upstate-phoenix-actions-dispatch"
  @query_id "upstate-phoenix-actions-query"
  @repo_attach_key :upstate_phoenix_actions_repos_attached
  @pdict_key :upstate_phoenix_action_db

  # A row is {{minute, name}, count, errors, total_us, db_us, bucket_0 .. bucket_11}.
  # update_counter positions are 1-based.
  @count 2
  @errors 3
  @total 4
  @db 5
  @first_bucket 6

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Upper bounds (ms) of the first 11 duration buckets; the 12th is unbounded."
  def buckets_ms, do: @buckets_ms

  @doc "The bucket index (0..11) for a duration in milliseconds."
  def bucket_index(ms), do: Enum.find_index(@buckets_ms, &(ms <= &1)) || length(@buckets_ms)

  @doc "Records one request. Never raises."
  def record(name, duration_ms, db_ms, error?, now \\ System.os_time(:second)) do
    minute = div(now, 60)
    name = clean_name(name)

    if name && :ets.whereis(@table) != :undefined && admit?(minute, name) do
      :ets.update_counter(@table, {minute, name}, [
        {@count, 1},
        {@errors, if(error?, do: 1, else: 0)},
        {@total, round(duration_ms * 1000)},
        {@db, round(db_ms * 1000)},
        {@first_bucket + bucket_index(duration_ms), 1}
      ])
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  The `actions` section: the last 15 closed minutes, ascending, each with at most 10 items
  by total time. Minutes with no data are omitted.
  """
  def snapshot(now \\ System.os_time(:second)) do
    current = div(now, 60)
    first = current - @window_minutes

    if :ets.whereis(@table) == :undefined do
      []
    else
      @table
      |> :ets.tab2list()
      |> Enum.filter(fn row ->
        case elem(row, 0) do
          {minute, name} when is_integer(minute) and is_binary(name) ->
            minute >= first and minute < current

          _ ->
            false
        end
      end)
      |> Enum.group_by(fn row -> row |> elem(0) |> elem(0) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {minute, rows} ->
        %{
          "minute" => minute |> Kernel.*(60) |> DateTime.from_unix!() |> DateTime.to_iso8601(),
          "items" => rows |> Enum.sort_by(&(-elem(&1, 3))) |> Enum.take(@top) |> Enum.map(&item/1)
        }
      end)
    end
  end

  defp item(row) do
    {_minute, name} = elem(row, 0)

    %{
      "name" => name,
      "count" => elem(row, 1),
      "errors" => elem(row, 2),
      "duration_buckets" => for(i <- 5..(4 + @bucket_count), do: elem(row, i)),
      "db_ms" => round(elem(row, 4) / 1000)
    }
  end

  # New names are admitted while the minute has room. The row is created first, then the
  # per-minute name count is bumped, so concurrent first sightings cannot exceed the cap.
  defp admit?(minute, name) do
    key = {minute, name}

    cond do
      :ets.member(@table, key) ->
        true

      :ets.insert_new(@table, empty_row(key)) ->
        if :ets.update_counter(@table, {:names, minute}, 1, {{:names, minute}, 0}) <= @max_names do
          true
        else
          :ets.delete(@table, key)
          false
        end

      true ->
        true
    end
  end

  defp empty_row(key), do: List.to_tuple([key | List.duplicate(0, 4 + @bucket_count)])

  defp clean_name(name) when is_binary(name) do
    name =
      name |> String.replace(~r/[^A-Za-z0-9_:#\/.\-]/u, "_") |> String.slice(0, @max_name_bytes)

    if name == "", do: nil, else: name
  end

  defp clean_name(_), do: nil

  @doc "Removes minutes older than the retention window."
  def prune(now \\ System.os_time(:second)) do
    oldest = div(now, 60) - @retain_minutes

    if :ets.whereis(@table) != :undefined do
      for row <- :ets.tab2list(@table) do
        minute =
          case elem(row, 0) do
            {:names, minute} -> minute
            {minute, _name} -> minute
          end

        if is_integer(minute) and minute < oldest, do: :ets.delete(@table, elem(row, 0))
      end
    end

    :ok
  end

  @doc false
  def reset, do: if(:ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table))

  ## Telemetry

  # The per-request frame lives in the process dictionary. `depth` counts nested router
  # dispatches (a `forward` runs the inner router in the same process); `key` identifies
  # the HTTP request so a frame leaked by a raising pipeline is not mistaken for the outer
  # dispatch of the next request on the same process.
  @doc false
  def handle_dispatch([:phoenix, :router_dispatch, :start], _measurements, metadata, _config) do
    key = request_key(metadata)

    case Process.get(@pdict_key) do
      %{key: ^key, depth: depth} = frame -> Process.put(@pdict_key, %{frame | depth: depth + 1})
      _ -> Process.put(@pdict_key, %{key: key, depth: 1, db_us: 0, name: nil, error?: false})
    end

    :ok
  rescue
    _ -> :ok
  end

  def handle_dispatch([:phoenix, :router_dispatch, :stop], %{duration: d}, metadata, _config),
    do: finish(d, metadata, status_error?(metadata))

  def handle_dispatch(
        [:phoenix, :router_dispatch, :exception],
        %{duration: d},
        metadata,
        _config
      ),
      do: finish(d, metadata, true)

  def handle_dispatch(_event, _measurements, _metadata, _config), do: :ok

  defp request_key(%{conn: %Plug.Conn{} = conn}) do
    :erlang.phash2({elem(conn.adapter, 0), conn.method, conn.request_path, conn.req_headers})
  end

  defp request_key(_), do: nil

  defp finish(duration, metadata, error?) do
    case Process.get(@pdict_key) do
      %{depth: depth} = frame when depth > 1 ->
        # An inner dispatch of a forwarded request: remember the most specific action.
        Process.put(@pdict_key, %{
          frame
          | depth: depth - 1,
            name: frame.name || action_name(metadata),
            error?: frame.error? or error?
        })

      frame ->
        Process.delete(@pdict_key)
        frame = frame || %{db_us: 0, name: nil, error?: false}
        ms = System.convert_time_unit(duration, :native, :microsecond) / 1000

        if name = frame.name || action_name(metadata),
          do: record(name, ms, frame.db_us / 1000, error? or frame.error?)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp status_error?(%{conn: %{status: status}}) when is_integer(status), do: status >= 500
  defp status_error?(_), do: false

  @doc false
  def handle_query(_event, measurements, _metadata, _config) do
    case Process.get(@pdict_key) do
      %{db_us: us} = frame ->
        native =
          Enum.reduce([:query_time, :decode_time, :queue_time], 0, fn key, acc ->
            case measurements do
              %{^key => t} when is_integer(t) -> acc + t
              _ -> acc
            end
          end)

        Process.put(@pdict_key, %{
          frame
          | db_us: us + System.convert_time_unit(native, :native, :microsecond)
        })

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc false
  def action_name(%{plug: plug} = metadata) do
    case live_view(Map.get(metadata, :conn)) do
      nil ->
        controller_name(plug, Map.get(metadata, :plug_opts))

      {view, action} ->
        module_name(view) <> if(action, do: "#" <> Atom.to_string(action), else: "")
    end
  end

  def action_name(_), do: nil

  defp controller_name(plug, action)
       when is_atom(plug) and not is_nil(plug) and is_atom(action) and not is_nil(action),
       do: module_name(plug) <> "#" <> Atom.to_string(action)

  defp controller_name(plug, _) when is_atom(plug) and not is_nil(plug), do: module_name(plug)
  defp controller_name(_, _), do: nil

  # Phoenix LiveView stores the route in conn.private.phoenix_live_view; the first element
  # is the LiveView module and the second carries the live action across versions.
  defp live_view(%{private: %{phoenix_live_view: tuple}})
       when is_tuple(tuple) and tuple_size(tuple) >= 2 do
    view = elem(tuple, 0)

    action =
      case elem(tuple, 1) do
        action when is_atom(action) and not is_nil(action) -> action
        opts when is_list(opts) -> if Keyword.keyword?(opts), do: Keyword.get(opts, :action)
        %{action: action} when is_atom(action) -> action
        _ -> nil
      end

    if is_atom(view) and not is_nil(view), do: {view, action}
  end

  defp live_view(_), do: nil

  defp module_name(module), do: module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    {:ok, %{}, {:continue, :attach}}
  end

  @impl true
  def handle_continue(:attach, state) do
    attach()
    Process.send_after(self(), :prune, @prune_every)
    {:noreply, state}
  end

  @impl true
  def handle_info(:prune, state) do
    prune()
    Process.send_after(self(), :prune, @prune_every)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def attach(extra_repos \\ []) do
    :telemetry.detach(@dispatch_id)

    # Query handlers are left in place: they don't depend on this process, their ids are
    # per event (so re-attaching is a no-op), and plug-only repos registered through
    # ensure_repos/1 would otherwise be lost on a collector restart.
    :telemetry.attach_many(
      @dispatch_id,
      [
        [:phoenix, :router_dispatch, :start],
        [:phoenix, :router_dispatch, :stop],
        [:phoenix, :router_dispatch, :exception]
      ],
      &__MODULE__.handle_dispatch/4,
      nil
    )

    attach_repos(repos() ++ extra_repos)
  end

  @doc """
  Attaches query telemetry for these repos (modules or `{module, opts}`). Idempotent: one
  handler per telemetry event, however many times or from however many places it is called.
  """
  def attach_repos(repos) do
    for repo <- repos,
        repo = repo_module(repo),
        event <- [telemetry_prefix(repo) ++ [:query]] do
      :telemetry.attach("#{@query_id}-#{inspect(event)}", event, &__MODULE__.handle_query/4, nil)
    end

    :ok
  end

  @doc false
  # Called by the plug on requests; attaches the plug's `repos:` once per distinct options.
  def ensure_repos(opts) do
    key = {@repo_attach_key, :erlang.phash2(opts)}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)
      opts |> UpstatePhoenix.Config.resolve() |> Map.fetch!(:repos) |> attach_repos()
    end

    :ok
  rescue
    _ -> :ok
  end

  defp repo_module({repo, _opts}), do: repo_module(repo)
  defp repo_module(repo) when is_atom(repo) and not is_nil(repo), do: repo
  defp repo_module(_), do: nil

  defp repos do
    configured = :upstate_phoenix |> Application.get_env(:repos, []) |> List.wrap()

    discovered =
      for {app, _, _} <- Application.loaded_applications(),
          repo <- List.wrap(Application.get_env(app, :ecto_repos, [])),
          do: repo

    (configured ++ discovered)
    |> Enum.map(&repo_module/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Ecto's default prefix is the repo module name underscored, one atom per segment; a repo
  # may override it with `:telemetry_prefix`.
  defp telemetry_prefix(repo) do
    configured =
      try do
        repo.config()[:telemetry_prefix]
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end

    configured ||
      repo |> Module.split() |> Enum.map(&(&1 |> Macro.underscore() |> String.to_atom()))
  end
end
