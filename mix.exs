defmodule UpstatePhoenix.MixProject do
  use Mix.Project

  @version "0.5.0"
  @docs_url "https://upstate.cloud/docs/phoenix"

  def project do
    [
      app: :upstate_phoenix,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "Phoenix app health for Upstate: boot facts, pending migrations, database size, Oban job counts and cron schedule runs. Never job arguments.",
      package: package(),
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]],
      source_url: @docs_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Runtime: only Plug. Ecto SQL, Oban and Jason are optional and used when the host app
  # already has them. Postgrex is needed only for this package's own tests.
  defp deps do
    [
      {:plug, "~> 1.14"},
      {:ecto_sql, "~> 3.10", optional: true},
      {:oban, "~> 2.17", optional: true},
      {:jason, "~> 1.4", optional: true},
      {:postgrex, ">= 0.0.0", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "Upstate" => "https://upstate.cloud",
        "Docs" => @docs_url,
        "GitHub" => "https://github.com/Upstate-run/upstate-phoenix"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end
end
