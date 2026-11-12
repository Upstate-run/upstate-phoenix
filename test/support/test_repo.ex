defmodule UpstatePhoenix.TestRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :upstate_phoenix, adapter: Ecto.Adapters.Postgres
end
