defmodule UpstatePhoenix.VerifyTest do
  use ExUnit.Case, async: false

  alias UpstatePhoenix.Verify

  @token "s3cr3t-0123456789abcdefghij"

  setup do
    previous = System.get_env("UPSTATE_HEALTH_TOKEN")
    System.delete_env("UPSTATE_HEALTH_TOKEN")
    Application.delete_env(:upstate_phoenix, :token)

    on_exit(fn ->
      if previous,
        do: System.put_env("UPSTATE_HEALTH_TOKEN", previous),
        else: System.delete_env("UPSTATE_HEALTH_TOKEN")
    end)

    :ok
  end

  test "disabled without a token, with a next action" do
    report = Verify.run(repos: [], oban: false)
    refute report.ok
    refute report.token.present
    assert [%{status: "disabled", action: action}] = report.checks
    assert action =~ "UPSTATE_HEALTH_TOKEN"
  end

  test "configured token authorizes and answers with schema 1" do
    System.put_env("UPSTATE_HEALTH_TOKEN", @token)
    report = Verify.run(repos: [], oban: false)
    assert report.ok, inspect(report.checks)

    assert Enum.map(report.checks, & &1.name) == [
             "configured",
             "authorization",
             "health response"
           ]

    assert report.reporter.version == UpstatePhoenix.version()
  end

  test "output never contains the token" do
    System.put_env("UPSTATE_HEALTH_TOKEN", @token)
    report = Verify.run(repos: [], oban: false)
    text = Verify.render(report) <> inspect(report)
    refute text =~ @token
    refute text =~ "s3cr3t"
    assert text =~ "value not shown"
    assert text =~ "not proof that Upstate receives data"
  end

  test "a blank token is disabled and verify is repeatable" do
    System.put_env("UPSTATE_HEALTH_TOKEN", "  ")
    assert [%{status: "disabled"}] = Verify.run(repos: [], oban: false).checks
    System.put_env("UPSTATE_HEALTH_TOKEN", @token)
    assert Verify.run(repos: [], oban: false).checks == Verify.run(repos: [], oban: false).checks
  end

  test "a token equal to a fixed probe string still verifies" do
    System.put_env("UPSTATE_HEALTH_TOKEN", "upstate-verify-probe")
    assert Verify.run(repos: [], oban: false).ok
  end

  test "an oversized token names the byte limit" do
    System.put_env("UPSTATE_HEALTH_TOKEN", String.duplicate("é", 200))
    report = Verify.run(repos: [], oban: false)
    refute report.ok
    detail = List.last(report.checks).detail
    assert detail =~ "400 bytes"
    assert detail =~ "256"
  end

  test "mix task raises when disabled and prints no token when enabled" do
    assert_raise Mix.Error, ~r/check failed/, fn ->
      ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Upstate.Verify.run([]) end)
    end

    System.put_env("UPSTATE_HEALTH_TOKEN", @token)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    Mix.Tasks.Upstate.Verify.run([])
    assert_received {:mix_shell, :info, [text]}
    refute text =~ @token
  end
end
