defmodule UpstatePhoenix.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([UpstatePhoenix.Actions],
      strategy: :one_for_one,
      name: UpstatePhoenix.Supervisor
    )
  end
end
