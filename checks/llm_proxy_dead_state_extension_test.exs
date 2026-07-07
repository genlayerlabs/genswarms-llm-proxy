# A dead/absent proxy still renders its DURABLE dashboard story when a store is
# given (observability of a stopped proxy); with NO store it stays %{}.
#   mix run checks/llm_proxy_dead_state_extension_test.exs
ExUnit.start()

defmodule DeadStateStore do
  def list_llm_usage(_limit) do
    [
      %{
        budget_identity: "llmb_x",
        day: Date.utc_today(),
        session_id: "llms_x",
        spent_usd: Decimal.new("0.0012"),
        limit_usd: Decimal.new("0.50"),
        requests: 2,
        prompt_tokens: 120,
        completion_tokens: 30,
        total_tokens: 150,
        cached_tokens: 40
      }
    ]
  end
end

defmodule GenswarmsLlmProxyDeadStateExtensionTest do
  use ExUnit.Case, async: false
  alias Genswarms.LlmProxy, as: Proxy

  test "durable-only extension with a dead state Agent" do
    {:ok, sp} = Agent.start(fn -> %{sessions: %{}, usage: %{}, notified: MapSet.new(), global: %{}} end)
    Agent.stop(sp)

    ext = Proxy.dashboard_extension(state_pid: sp, store_mod: DeadStateStore, day: Date.utc_today())
    assert ext["llm_proxy"]["requests"] == 2
    assert Enum.any?(ext["dashboard_pages"], &(&1["id"] == "proxy-router"))
    assert ext["proxy_router"]["source"] == "postgres"

    # A dead proxy has no live quota Agent to read from — the budget block still
    # publishes (durable spend + shipped rules) but the ceiling goes inert (0.0)
    # rather than false-alarming on a config it can no longer see.
    budget = ext["llm_proxy_budget"]
    assert budget["v"] == 1
    assert budget["ceiling_usd"] == 0.0
    assert budget["spent_usd"] == 0.0012
    assert budget["default_daily_limit_usd"] == 0.0
    assert Enum.map(budget["health_rules"], & &1["id"]) == ["budget_guard_75", "budget_guard_90"]
  end

  test "dead state and NO store stays empty" do
    {:ok, sp} = Agent.start(fn -> %{} end)
    Agent.stop(sp)
    assert Proxy.dashboard_extension(state_pid: sp) == %{}
  end
end
