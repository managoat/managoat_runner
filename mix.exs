defmodule Managoat.Runner.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/managoat/managoat_runner"

  def project do
    [
      app: :managoat_runner,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "The self-hosted runner wire protocol: a WebSock connection process and a Managoat.Sandbox adapter over it, behind a host behaviour.",
      package: package(),
      source_url: @source_url,
      docs: docs(),
      dialyzer: dialyzer(),
      test_coverage: [
        # What this suite measures on its own: the connection, the adapter,
        # the names, the two hosts and the fake daemon, all driven end to end
        # by the conformance suite against Managoat.Runner.Host.Local. Raise
        # it as the library's own tests grow; never lower it.
        summary: [threshold: 85]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      # Tooling for the repository, not the package: docs for hexdocs.pm (built
      # by `mix hex.publish`), credo and dialyzer for CI. dialyxir is pinned to
      # the commit that added OTP 28 support; 1.4.7 crashes on OTP 28 warnings.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir,
       github: "jeremyjh/dialyxir",
       ref: "3553678f4d69281ac6db61034bcf35bcb30cfd78",
       only: [:dev, :test],
       runtime: false},
      # The behaviour, Handle, Command, Session, NetworkPolicy and the
      # conformance case. The direction runner -> sandbox is the one
      # decisions/0037 pins. From hex since managoat_sandbox graduated
      # (#1345): the umbrella resolves it the same way apps/fountain does,
      # and `mix hex.build` for this app succeeds inside the umbrella, which
      # is what lets it graduate next.
      {:managoat_sandbox, "~> 0.1.0"},
      # The WebSock behaviour only. The adapter that mounts a handler on a
      # Plug connection (websock_adapter) belongs to the host application.
      {:websock, "~> 0.5"},
      {:jason, "~> 1.2"}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE NOTICE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp dialyzer do
    [
      ignore_warnings: ".dialyzer_ignore.exs",
      # A fixed path so CI can cache the PLT across runs.
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end
end
