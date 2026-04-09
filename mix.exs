defmodule PgRegistry.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/twinn/pg_registry"

  def project do
    [
      app: :pg_registry,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      dialyzer: dialyzer(),
      source_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.4", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warnings_as_errors, "priv/plts/project.plt"},
      plt_core_path: "priv/plts/core.plt",
      flags: [:error_handling, :unknown, :unmatched_returns]
    ]
  end

  defp description do
    "A distributed, metadata-aware process registry for Elixir. " <>
      "Cluster-aware like :pg, Registry-shaped API, per-process values, " <>
      "listener notifications, and native ETS match-spec queries."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "PgRegistry",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end
end
