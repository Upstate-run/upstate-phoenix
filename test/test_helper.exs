alias UpstatePhoenix.TestRepo

db_config = [
  database: System.get_env("UPSTATE_PHOENIX_TEST_DB", "upstate_phoenix_test"),
  username: System.get_env("PGUSER") || System.get_env("USER") || "postgres",
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  log: false
]

Application.put_env(:upstate_phoenix, TestRepo, db_config)
Application.put_env(:upstate_phoenix, UpstatePhoenix.DownRepo, db_config)

_ = Ecto.Adapters.Postgres.storage_up(TestRepo.config())
{:ok, _} = TestRepo.start_link()

migrations = Path.expand("support/migrations", __DIR__)
Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :auto)
Ecto.Migrator.run(TestRepo, migrations, :up, all: true, log: false)

{:ok, _} = Oban.start_link(name: UpstatePhoenix.TestOban, repo: TestRepo, testing: :manual)

Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
ExUnit.start()
