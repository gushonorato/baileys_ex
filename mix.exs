defmodule Baileys.MixProject do
  use Mix.Project

  def project do
    [
      app: :baileys,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :logger, :ssl],
      mod: {Baileys.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:castore, "~> 1.0"},
      {:ex_aws, "~> 2.6"},
      {:ex_aws_s3, "~> 2.5"},
      {:jason, "~> 1.4"},
      {:mint, "~> 1.7"},
      {:mint_web_socket, "~> 1.0"},
      {:protobuf, "~> 0.17"},
      {:qr_code, "~> 3.2", only: :dev},
      # Remove the override after iodevs/matrix_reloaded#18 is released.
      {:matrix_reloaded,
       github: "peaceful-james/matrix_reloaded",
       ref: "dc4fcb1698ff2aad273632696eadf78334c1541d",
       only: :dev,
       override: true},
      {:req, "~> 0.6.0"}
    ]
  end

  defp aliases do
    [
      "proto.generate": "cmd scripts/generate_protobuf.sh",
      "proto.check": [
        "proto.generate",
        "cmd git diff --exit-code -- proto lib/baileys/proto/generated"
      ]
    ]
  end
end
