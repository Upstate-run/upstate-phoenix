defmodule UpstatePhoenix.BlockedRepo do
  @moduledoc false
  def query(_sql, _params, _opts) do
    send(Application.fetch_env!(:upstate_phoenix, :budget_test_owner), {:blocked_query, self()})

    receive do
      :release -> {:ok, %{rows: [[1]]}}
    end
  end
end
