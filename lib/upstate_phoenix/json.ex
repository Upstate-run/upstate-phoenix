defmodule UpstatePhoenix.JSON do
  @moduledoc false

  # Elixir 1.18+ ships JSON. Older apps almost always have Jason through Phoenix.
  def encode!(term) do
    cond do
      Code.ensure_loaded?(JSON) -> apply(JSON, :encode!, [term])
      Code.ensure_loaded?(Jason) -> apply(Jason, :encode!, [term])
      true -> raise "upstate_phoenix needs Elixir 1.18+ or the :jason package to encode JSON"
    end
  end

  @doc false
  def decode(binary) do
    cond do
      Code.ensure_loaded?(JSON) -> apply(JSON, :decode, [binary])
      Code.ensure_loaded?(Jason) -> apply(Jason, :decode, [binary])
      true -> raise "upstate_phoenix needs Elixir 1.18+ or the :jason package to decode JSON"
    end
  end
end
