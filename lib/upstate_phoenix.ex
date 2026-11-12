defmodule UpstatePhoenix do
  @moduledoc """
  Phoenix app health for [Upstate](https://upstate.cloud).

  Mount `UpstatePhoenix.Plug` in your endpoint. Upstate's host observer reads
  `GET /upstate/health` from inside your server, over the private Docker network, every
  minute. The package sends nothing anywhere by itself.

  See `UpstatePhoenix.Plug` for options and the README for what is (and is never) sent.
  """

  @version Mix.Project.config()[:version]

  @doc "The package version, reported as `reporter.version`."
  def version, do: @version

  @doc """
  True for `localhost` and private IPv4/IPv6 literals (10/8, 172.16/12, 192.168/16,
  127/8, fc00::/7, ::1).

  For Plug older than 1.19, whose `Plug.SSL` `:exclude` option takes only hosts, use it to
  keep `force_ssl` from redirecting the observer's plain-HTTP request to the container's
  private IP:

      force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: {UpstatePhoenix, :private_host?, []}]

  On Plug 1.19+ prefer `exclude: [hosts: ["localhost", "127.0.0.1"], paths: ["/upstate/health"]]`.
  """
  def private_host?("localhost"), do: true

  def private_host?(host) when is_binary(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {10, _, _, _}} -> true
      {:ok, {172, b, _, _}} when b in 16..31 -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {a, _, _, _, _, _, _, _}} when a >= 0xFC00 and a <= 0xFDFF -> true
      _ -> false
    end
  end

  def private_host?(_), do: false
end
