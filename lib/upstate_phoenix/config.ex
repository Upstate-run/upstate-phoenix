defmodule UpstatePhoenix.Config do
  @moduledoc false

  # Captured when the package is compiled. Deps compile in the host app's Mix env, so a
  # release built with MIX_ENV=prod reports "prod".
  @compile_env if Code.ensure_loaded?(Mix), do: to_string(Mix.env()), else: nil

  @doc "The expected bearer token, or nil when none is configured (the endpoint is off)."
  def token do
    case Application.get_env(:upstate_phoenix, :token) || System.get_env("UPSTATE_HEALTH_TOKEN") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc "Merges plug options over app config and defaults."
  def resolve(opts) do
    app_env = Application.get_all_env(:upstate_phoenix)
    get = fn key, default -> Keyword.get(opts, key, Keyword.get(app_env, key, default)) end
    otp_app = get.(:otp_app, nil)

    repos =
      case get.(:repos, nil) do
        nil when is_atom(otp_app) and not is_nil(otp_app) ->
          Application.get_env(otp_app, :ecto_repos, [])

        nil ->
          []

        repos ->
          List.wrap(repos)
      end

    %{
      otp_app: otp_app,
      repos: Enum.map(repos, &normalize_repo/1),
      oban: get.(:oban, Oban),
      environment: to_string_or_nil(get.(:environment, @compile_env))
    }
  end

  defp normalize_repo({repo, opts}) when is_atom(repo) and is_list(opts), do: {repo, opts}
  defp normalize_repo(repo) when is_atom(repo), do: {repo, []}

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)
end
