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

  test "disabled without a token in production, with a next action" do
    report = Verify.run(repos: [], oban: false, environment: "prod")
    refute report.ok
    refute report.token.present
    assert [%{status: "disabled", action: action}] = report.checks
    assert action =~ "UPSTATE_HEALTH_TOKEN"
  end

  test "no token in dev or test is a note, not a failure, with the production command" do
    for env <- ["dev", "test"] do
      report = Verify.run(repos: [], oban: false, otp_app: :my_app, environment: env)
      assert report.ok
      assert [%{status: "note", action: action}] = report.checks

      assert action =~
               "kamal app exec --reuse 'bin/my_app eval \"UpstatePhoenix.Verify.main()\"'"

      text = Verify.render(report)
      assert text =~ "note configured:"
      assert text =~ "expected outside production"
      refute text =~ "FAIL"
    end
  end

  test "execute returns the exit status without halting" do
    assert {text, 1} = Verify.execute(repos: [], oban: false, environment: "prod")
    assert text =~ "FAIL configured"
    assert {_, 0} = Verify.execute(repos: [], oban: false, environment: "dev")
    System.put_env("UPSTATE_HEALTH_TOKEN", @token)
    assert {_, 0} = Verify.execute(repos: [], oban: false)
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

    assert [%{status: "disabled"}] =
             Verify.run(repos: [], oban: false, environment: "prod").checks

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

  test "mix task raises when disabled in production and prints no token when enabled" do
    Application.put_env(:upstate_phoenix, :environment, "prod")
    on_exit(fn -> Application.delete_env(:upstate_phoenix, :environment) end)

    assert_raise Mix.Error, ~r/check failed/, fn ->
      ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Upstate.Verify.run([]) end)
    end

    Application.put_env(:upstate_phoenix, :environment, "test")
    ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Upstate.Verify.run([]) end)

    System.put_env("UPSTATE_HEALTH_TOKEN", @token)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    Mix.Tasks.Upstate.Verify.run([])
    assert_received {:mix_shell, :info, [text]}
    refute text =~ @token
  end

  describe "mix task environment" do
    test "uses the invoking project's Mix env when :environment is not configured" do
      Application.delete_env(:upstate_phoenix, :environment)
      assert Mix.Tasks.Upstate.Verify.task_opts(:dev) == [environment: "dev"]
    end

    test "an explicit :environment wins over the Mix env" do
      Application.put_env(:upstate_phoenix, :environment, "prod")
      on_exit(fn -> Application.delete_env(:upstate_phoenix, :environment) end)
      assert Mix.Tasks.Upstate.Verify.task_opts(:dev) == []
    end

    test "a dev run without a token is a note, not a failure, even though deps compile as prod" do
      report = UpstatePhoenix.Verify.run(Mix.Tasks.Upstate.Verify.task_opts(:dev))
      assert report.ok
      assert [%{status: "note"}] = report.checks
    end
  end

  test "execute loads the reporter application before reading its configuration" do
    Application.put_env(:upstate_phoenix, :environment, "prod")
    on_exit(fn -> Application.delete_env(:upstate_phoenix, :environment) end)
    assert {text, 1} = UpstatePhoenix.Verify.execute()
    assert text =~ "UPSTATE_HEALTH_TOKEN is not set"

    assert Enum.any?(Application.loaded_applications(), fn {app, _, _} ->
             app == :upstate_phoenix
           end)
  end

  test "execute loads an unloaded :otp_app before reading configuration" do
    # :upstate_phoenix is already started in the test VM and cannot be unloaded, so define
    # a throwaway application that is on the code path but not loaded.
    app = :upstate_verify_probe

    dir =
      Path.join(System.tmp_dir!(), "upstate_verify_probe_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "#{app}.app"),
      ~s|{application,#{app},[{vsn,"0.0.1"},{modules,[]},{registered,[]},{applications,[kernel,stdlib]}]}.|
    )

    Code.prepend_path(dir)

    on_exit(fn ->
      Application.unload(app)
      Code.delete_path(dir)
      File.rm_rf!(dir)
    end)

    loaded? = fn -> Enum.any?(Application.loaded_applications(), &(elem(&1, 0) == app)) end
    refute loaded?.()

    UpstatePhoenix.Verify.execute(otp_app: app)

    assert loaded?.()
  end
end
