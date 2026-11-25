defmodule UpstatePhoenix.Plug do
  @moduledoc """
  Answers `GET /upstate/health` with Upstate's app-health schema 1. Every other request
  passes through untouched, so it can sit in the endpoint before the router:

      # lib/my_app_web/endpoint.ex
      plug UpstatePhoenix.Plug, otp_app: :my_app

  Put it above `plug Plug.Telemetry` so the once-a-minute poll stays out of request logs.

  ## Auth

  The token is `UPSTATE_HEALTH_TOKEN`, read at request time (or `config :upstate_phoenix,
  token: ...`). With no token configured the path answers 404, as if nothing were
  installed. A missing or wrong bearer token answers 401. Tokens are compared as SHA-256
  digests in constant time.

  ## Options

  Options come from the plug call, then `config :upstate_phoenix, ...`, then defaults:

    * `:otp_app` - your app. Used to find `:ecto_repos` when `:repos` is not set.
    * `:repos` - repos to check for reachability and pending migrations. Each entry is a
      repo module or `{repo, migrations_paths: [...]}`. Defaults to the app's `:ecto_repos`.
      Set `migrations_paths: []` when another application owns the schema; migration status
      is then unknown (`null`) while database reachability is still checked.
    * `:oban` - the Oban instance name (default `Oban`), or `false` to report no job system.
    * `:environment` - shown as `phoenix.environment`. Defaults to the Mix env the
      package was compiled in (`"prod"` in a release).
  """

  @behaviour Plug

  import Plug.Conn

  @max_token_bytes 256

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["upstate", "health"]} = conn, opts) do
    UpstatePhoenix.Actions.ensure_repos(opts)

    conn
    |> respond(opts)
    |> halt()
  end

  def call(conn, opts) do
    UpstatePhoenix.Actions.ensure_repos(opts)
    conn
  end

  defp respond(conn, opts) do
    case UpstatePhoenix.Config.token() do
      nil ->
        reply(conn, 404, "")

      expected ->
        cond do
          conn.method not in ["GET", "HEAD"] ->
            reply(conn, 405, "")

          not authorized?(get_req_header(conn, "authorization"), expected) ->
            conn
            |> put_resp_header("www-authenticate", "Bearer")
            |> reply(401, "")

          true ->
            {status, body} = UpstatePhoenix.Health.call(UpstatePhoenix.Config.resolve(opts))

            conn
            |> put_resp_content_type("application/json")
            |> reply(status, UpstatePhoenix.JSON.encode!(body))
        end
    end
  end

  defp authorized?(["Bearer " <> supplied], expected)
       when byte_size(supplied) in 1..@max_token_bytes do
    Plug.Crypto.secure_compare(digest(supplied), digest(expected))
  end

  defp authorized?(_header, _expected), do: false

  defp digest(value), do: :crypto.hash(:sha256, value)

  defp reply(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, body)
  end
end
