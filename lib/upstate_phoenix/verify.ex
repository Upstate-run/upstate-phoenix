defmodule UpstatePhoenix.Verify do
  @moduledoc """
  Read-only local check behind `mix upstate.verify`.

  It answers what can be answered inside this node: is the reporter on, is a token
  present (never printed), and does the plug reject a wrong token, accept the configured
  one and answer with schema 1. It sends nothing to Upstate, writes nothing, never
  changes credentials and does not query the database or Oban (a fresh `mix` run has not
  started them, and Upstate's observer reads them from the running app). Whether Upstate
  has received a report is a separate fact that only Upstate can confirm (`upstate doctor`).
  """

  @doc "Runs the checks. Options are the plug options (`:otp_app`, `:repos`, `:oban`)."
  def run(opts \\ []) do
    token = UpstatePhoenix.Config.token()
    config = UpstatePhoenix.Config.resolve(opts)
    # Never query the database or Oban from a fresh `mix` run: the repos are not started
    # there, so a query would fail for a healthy app. Upstate's observer reads both when
    # it scrapes the running app.
    plug_opts = UpstatePhoenix.Plug.init(Keyword.merge(opts, repos: [], oban: false))

    checks =
      case token do
        nil ->
          [disabled_check()]

        token ->
          token_checks(token, plug_opts)
      end

    %{
      reporter: %{name: "upstate_phoenix", version: UpstatePhoenix.version()},
      runtime: %{
        phoenix: loaded_version(:phoenix),
        elixir: System.version(),
        otp: System.otp_release()
      },
      environment: config.environment,
      token: %{present: not is_nil(token), length: if(token, do: String.length(token), else: 0)},
      checks: checks,
      ok: Enum.all?(checks, &(&1.status == "ok")),
      next_step:
        "A passing local check is not proof that Upstate receives data. After a deploy, run `upstate doctor` and wait for fresh evidence."
    }
  end

  @doc "Human-readable lines. Never includes the token or any part of it."
  def render(report) do
    token =
      if report.token.present,
        do: "present (#{report.token.length} characters, value not shown)",
        else: "not set"

    header =
      "Upstate Phoenix reporter #{report.reporter.version} (Phoenix #{report.runtime.phoenix}, " <>
        "Elixir #{report.runtime.elixir}, OTP #{report.runtime.otp}, #{report.environment || "unknown env"})"

    lines =
      Enum.flat_map(report.checks, fn check ->
        mark = if check.status == "ok", do: "ok  ", else: "FAIL"
        base = ["#{mark} #{check.name}: #{check.detail}"]
        if check.action, do: base ++ ["     next: #{check.action}"], else: base
      end)

    Enum.join([header, "Token: #{token}"] ++ lines ++ [report.next_step], "\n")
  end

  defp disabled_check do
    check(
      "configured",
      "disabled",
      "UPSTATE_HEALTH_TOKEN is not set in this environment, so /upstate/health answers 404 and nothing is reported.",
      "Generate a health token in Upstate, set UPSTATE_HEALTH_TOKEN for this environment (for example under env.secret in config/deploy.yml), then deploy."
    )
  end

  defp configured_check,
    do: check("configured", "ok", "UPSTATE_HEALTH_TOKEN is set; the endpoint is on.", nil)

  @max_token_bytes 256

  defp token_checks(token, _plug_opts) when byte_size(token) > @max_token_bytes do
    [
      configured_check(),
      check(
        "authorization",
        "failed",
        "UPSTATE_HEALTH_TOKEN is #{byte_size(token)} bytes; the plug rejects any token over #{@max_token_bytes} bytes.",
        "Generate a token in Upstate (they are well under the limit) and set it as UPSTATE_HEALTH_TOKEN, without extra characters."
      )
    ]
  end

  # One request with the configured token serves both the authorization and the response
  # check, so the health response is built once.
  defp token_checks(token, plug_opts) do
    conn = request(token, plug_opts)
    [configured_check(), auth_check(token, conn.status, plug_opts), health_check(conn)]
  end

  defp auth_check(token, accepted, plug_opts) do
    rejected = request(probe_token(token), plug_opts).status

    if rejected == 401 and accepted != 401 do
      check(
        "authorization",
        "ok",
        "The endpoint rejects a wrong token and accepts the configured one.",
        nil
      )
    else
      check(
        "authorization",
        "failed",
        "The endpoint did not behave as expected (wrong token: #{rejected}, configured token: #{accepted}).",
        "Check that UPSTATE_HEALTH_TOKEN has no stray characters or whitespace, and that this plug is the Upstate one, then redeploy."
      )
    end
  end

  # A wrong token that can never equal the configured one.
  defp probe_token(token) do
    candidate = "probe-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    if candidate == token, do: probe_token(token), else: candidate
  end

  defp health_check(conn) do
    case {conn.status, UpstatePhoenix.JSON.decode(conn.resp_body)} do
      {200, {:ok, %{"schema" => 1} = body}} ->
        check(
          "health response",
          "ok",
          "Schema 1, reporter version #{inspect(body["version"])}.",
          nil
        )

      {503, _} ->
        check(
          "health response",
          "failed",
          "A database is not answering (503).",
          "Fix database connectivity for this environment; the reporter will then answer 200."
        )

      {status, _} ->
        check(
          "health response",
          "failed",
          "Unexpected response #{status}.",
          "Run the app and request /upstate/health with the token to see the response."
        )
    end
  rescue
    error ->
      check(
        "health response",
        "failed",
        "Could not build the health response (#{inspect(error.__struct__)}).",
        "Run the app in this environment and check its logs for the error."
      )
  end

  defp request(token, plug_opts) do
    :get
    |> Plug.Test.conn("/upstate/health")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> UpstatePhoenix.Plug.call(plug_opts)
  end

  defp check(name, status, detail, action),
    do: %{name: name, status: status, detail: detail, action: action}

  defp loaded_version(app) do
    case Application.spec(app, :vsn) do
      nil -> "not loaded"
      vsn -> to_string(vsn)
    end
  end
end
