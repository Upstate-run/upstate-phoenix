defmodule Mix.Tasks.Upstate.Verify do
  @shortdoc "Checks the Upstate app-health reporter locally (read-only; prints no token)"

  @moduledoc """
  Checks the reporter without sending anything to Upstate.

      mix upstate.verify

  Shows whether the reporter is on or disabled, that a token is present (its value is
  never printed), the reporter, Phoenix, Elixir and OTP versions, and that the plug
  rejects a wrong token, accepts the configured one and answers with schema 1. It does
  not query the database or Oban. Exits non-zero when something needs fixing. It never runs on install, only when invoked.
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {_parsed, _, _} = OptionParser.parse(args, strict: [])
    report = UpstatePhoenix.Verify.run(task_opts(Mix.env()))
    Mix.shell().info(UpstatePhoenix.Verify.render(report))
    unless report.ok, do: Mix.raise("Upstate reporter check failed")
  end

  # Dependencies always compile with MIX_ENV=prod, so the reporter's compile-time
  # environment says "prod" even in the host app's dev or test. Use the invoking
  # project's Mix env unless the app configured :environment explicitly.
  @doc false
  def task_opts(mix_env) do
    if Application.get_env(:upstate_phoenix, :environment),
      do: [],
      else: [environment: to_string(mix_env)]
  end
end
