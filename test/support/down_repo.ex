defmodule UpstatePhoenix.DownRepo do
  @moduledoc false
  # Configured but never started, so every query fails like an unreachable database.
  use Ecto.Repo, otp_app: :upstate_phoenix, adapter: Ecto.Adapters.Postgres
end
