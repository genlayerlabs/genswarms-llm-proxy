# Users-by-period tabs on the proxy-router page — probed store contract
# `store_mod.llm_usage_by_budget_since/2` (days | :all, limit) feeding a
# frontend-0.3.5 "tabs" section (Today / 7 days / 30 days / All-time). Same
# fail-open discipline as every probed section: absent contract or raising
# store falls back to the classic flat Users table, never a crashed snapshot.
#   mix run checks/llm_proxy_period_tabs_test.exs
ExUnit.start()

defmodule PeriodStore do
  def llm_usage_by_budget_since(period, limit) do
    send(:period_tabs_test_proc, {:since_called, period, limit})

    [
      %{
        budget_identity: "llmb_alpha00000000",
        requests: 40,
        prompt_tokens: 4_000,
        total_tokens: 4_400,
        cached_tokens: 2_000,
        spent_usd: Decimal.new("0.40")
      },
      %{
        budget_identity: "llmb_beta000000000",
        requests: 2,
        prompt_tokens: 100,
        total_tokens: 120,
        cached_tokens: 0,
        spent_usd: Decimal.new("0.02")
      }
    ]
  end
end

defmodule NoPeriodStore do
end

defmodule RaisingPeriodStore do
  def llm_usage_by_budget_since(_period, _limit), do: raise("boom")
end

defmodule GenswarmsLlmProxyPeriodTabsTest do
  use ExUnit.Case, async: false
  alias Genswarms.LlmProxy, as: Proxy

  defp dead_state do
    {:ok, sp} =
      Agent.start(fn -> %{sessions: %{}, usage: %{}, notified: MapSet.new(), global: %{}} end)

    sp
  end

  defp page(ext), do: Enum.find(ext["dashboard_pages"], &(&1["id"] == "proxy-router"))

  defp tabs_section(ext),
    do: Enum.find(page(ext)["sections"], &(&1["type"] == "tabs"))

  defp flat_users_table(ext),
    do:
      Enum.find(
        page(ext)["sections"],
        &(&1["type"] == "table" and (&1["title"] || "") == "Users")
      )

  test "with the contract, the Users table becomes period tabs" do
    Process.register(self(), :period_tabs_test_proc)

    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: PeriodStore)

    sec = tabs_section(ext)
    assert sec != nil
    assert sec["title"] == "Users"
    assert Enum.map(sec["tabs"], & &1["label"]) == ["Today", "7 days", "30 days", "All-time"]

    # each period tab queried the store with its window
    assert_receive {:since_called, 7, 100}
    assert_receive {:since_called, 30, 100}
    assert_receive {:since_called, :all, 100}

    # a period tab is a plain sortable table with user-mapped rows
    seven = Enum.find(sec["tabs"], &(&1["label"] == "7 days"))["section"]
    assert seven["type"] == "table"
    keys = Enum.map(seven["columns"], & &1["key"])
    assert "user" in keys and "spent" in keys and "requests" in keys
    refute "limit" in keys
    refute "status" in keys

    [top, second] = seven["rows"]
    assert top["spent"] == "$0.400000"
    assert top["budget"] == "llmb_alpha00000"
    assert second["spent"] == "$0.020000"
    assert top["cache"] == "50%"

    # the flat Users table is REPLACED by the tabs section, not duplicated
    assert flat_users_table(ext) == nil

    # the Today tab keeps the live-day semantics (limit/status columns)
    today = Enum.find(sec["tabs"], &(&1["label"] == "Today"))["section"]
    today_keys = Enum.map(today["columns"], & &1["key"])
    assert "limit" in today_keys and "status" in today_keys
  after
    Process.unregister(:period_tabs_test_proc)
  end

  test "without the contract the classic flat Users table renders" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: NoPeriodStore)
    assert tabs_section(ext) == nil
    assert flat_users_table(ext) != nil
  end

  test "a raising store falls back to the flat table (never a crashed snapshot)" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: RaisingPeriodStore)
    assert tabs_section(ext) == nil
    assert flat_users_table(ext) != nil
  end
end
