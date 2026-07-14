defmodule GenswarmsLlmProxy.MixProject do
  use Mix.Project

  def project do
    [
      app: :genswarms_llm_proxy,
      version: "0.2.14",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/genlayerlabs/genswarms-llm-proxy",
      description:
        "LLM metering/budget proxy object for genswarms swarms — per-conversation " <>
          "quotas, global cost ceiling, cost tracking, prompt-cache marking, opaque agent tokens",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # genswarms is a peer/runtime dependency provided by the host app (the object
  # callbacks are implemented by convention). curl is a runtime tool dependency.
  defp deps do
    [
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.14"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 2.0 or ~> 3.0"}
    ]
  end
end
