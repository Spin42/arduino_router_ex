defmodule ArduinoRouterEx.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :arduino_router_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps(),
      description: "The Arduino Router's MessagePack-RPC bridge to an Arduino sketch, in Elixir",
      package: package(),
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.8", runtime: false},
      {:msgpax, "~> 2.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/Spin42/arduino_router_ex"},
      files: ["lib", "c_src", "Makefile", "mix.exs", "README.md", "LICENSES"]
    ]
  end
end
