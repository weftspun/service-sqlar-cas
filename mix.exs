defmodule SqlarCas.MixProject do
  use Mix.Project

  def project do
    [
      app: :sqlar_cas,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {SqlarCas.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:exqlite, "~> 0.30"},
      {:req, "~> 0.5"},
      {:req_s3, "~> 0.2"}
      # zstd: use OTP's built-in :zstd (Erlang/OTP 27+) — no dep needed.
    ]
  end
end
