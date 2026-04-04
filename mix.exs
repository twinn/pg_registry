defmodule PgRegistry.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/twinn/pg_registry"

  def project do
    [
      app: :pg_registry,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "A distributed process registry backed by Erlang's :pg module. Works like Elixir's Registry but discovers processes across clusters."
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
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
