# All-time totals on the proxy-router page — probed store contracts
# (`store_mod.llm_usage_alltime/0` + `store_mod.llm_router_cost_alltime/0`,
# host-owned SQL), same fail-open discipline as the History/By-model sections:
# absent function, nil, or raising store contributes NOTHING. Also pins the
# widened history window (30 days) actually reaching the store contract.
#   mix run checks/llm_proxy_alltime_section_test.exs
ExUnit.start()

defmodule AlltimeStore do
  def llm_usage_alltime do
    %{
      since: ~D[2026-06-26],
      days: 14,
      budgets: 41,
      requests: 12_345,
      prompt_tokens: 90_000_000,
      total_tokens: 95_000_000,
      cached_tokens: 45_000_000,
      spent_usd: Decimal.new("12.5"),
      accounting_note: "legacy spend reconstructed",
      spend_label: "Repriced spend",
      spend_sub: "includes archive-backed pre-proxy pricing"
    }
  end

  def llm_router_cost_alltime, do: %{cost_usd: Decimal.new("7.25"), estimated_any: true}
end

defmodule AlltimeNoRouterStore do
  def llm_usage_alltime do
    %{
      since: ~D[2026-07-01],
      days: 3,
      budgets: 2,
      requests: 10,
      prompt_tokens: 1000,
      total_tokens: 1100,
      cached_tokens: 0,
      spent_usd: Decimal.new("0.01")
    }
  end
end

defmodule AlltimeAuthoritativeStore do
  defdelegate llm_usage_alltime(), to: AlltimeStore

  def llm_financials_alltime do
    %{
      since: ~D[2026-07-15],
      days: 2,
      spent_usd: Decimal.new("13.00"),
      router_cost_usd: Decimal.new("10.00"),
      gross_margin_usd: Decimal.new("3.00"),
      gross_margin_pct: Decimal.new("30.0"),
      estimated_any: false,
      ledger_requests: 100,
      router_requests: 100,
      ledger_tokens: 95_000_000,
      router_tokens: 95_000_000,
      mismatched_days: 0,
      reconciled: true,
      authoritative: true,
      accounting_scope: "test-production-v1"
    }
  end
end

defmodule AlltimeUnreconciledStore do
  defdelegate llm_usage_alltime(), to: AlltimeStore

  def llm_financials_alltime do
    %{
      since: ~D[2026-07-15],
      days: 1,
      spent_usd: Decimal.new("13.00"),
      router_cost_usd: Decimal.new("11.00"),
      gross_margin_usd: Decimal.new("2.00"),
      gross_margin_pct: Decimal.new("18.18"),
      estimated_any: true,
      ledger_requests: 99,
      router_requests: 100,
      ledger_tokens: 94_000_000,
      router_tokens: 95_000_000,
      mismatched_days: 1,
      reconciled: false,
      authoritative: true,
      accounting_scope: "test-production-v1"
    }
  end
end

defmodule AlltimeHistoricalEvidenceStore do
  defdelegate llm_usage_alltime(), to: AlltimeStore

  def llm_financials_alltime do
    %{
      since: ~D[2026-06-29],
      days: 16,
      spent_usd: Decimal.new("0"),
      router_cost_usd: Decimal.new("0"),
      lifetime_spent_usd: Decimal.new("133.63"),
      lifetime_router_cost_usd: Decimal.new("68.49"),
      authoritative: false,
      reconciled: false,
      accounting_scope: "legacy-shared-key",
      accounting_note: "historical cost evidence · totals are not comparable"
    }
  end
end

defmodule AlltimeMixedScopeStore do
  defdelegate llm_usage_alltime(), to: AlltimeStore

  def llm_financials_alltime do
    %{
      since: ~D[2026-07-15],
      days: 1,
      spent_usd: Decimal.new("1.30"),
      router_cost_usd: Decimal.new("1.00"),
      gross_margin_usd: Decimal.new("0.30"),
      gross_margin_pct: Decimal.new("30"),
      estimated_any: true,
      ledger_requests: 10,
      router_requests: 10,
      ledger_tokens: 1_000,
      router_tokens: 1_000,
      reconciled: true,
      authoritative: true,
      accounting_scope: "wingston-production-v1",
      lifetime_spent_usd: Decimal.new("136.61"),
      lifetime_router_cost_usd: Decimal.new("71.54"),
      legacy_router_included: true
    }
  end
end

defmodule AlltimeUnmarkedFinancialStore do
  defdelegate llm_usage_alltime(), to: AlltimeStore

  def llm_financials_alltime do
    AlltimeAuthoritativeStore.llm_financials_alltime()
    |> Map.delete(:authoritative)
  end
end

defmodule AlltimeContradictoryCoverageStore do
  defdelegate llm_usage_alltime(), to: AlltimeStore

  def llm_financials_alltime do
    AlltimeAuthoritativeStore.llm_financials_alltime()
    |> Map.put(:ledger_tokens, 94_999_999)
    |> Map.put(:reconciled, true)
  end
end

defmodule AlltimeEmptyStore do
  def llm_usage_alltime, do: nil
end

defmodule AlltimeRaisingStore do
  def llm_usage_alltime, do: raise("boom")
  def llm_router_cost_alltime, do: raise("boom")
end

defmodule HistoryWindowStore do
  # Records the days argument so the test can pin the widened window.
  def llm_usage_days(days) when is_integer(days) do
    send(:alltime_test_proc, {:history_days, days})
    []
  end
end

defmodule GenswarmsLlmProxyAlltimeSectionTest do
  use ExUnit.Case, async: false
  alias Genswarms.LlmProxy, as: Proxy

  defp dead_state do
    {:ok, sp} =
      Agent.start(fn -> %{sessions: %{}, usage: %{}, notified: MapSet.new(), global: %{}} end)

    sp
  end

  defp page(ext), do: Enum.find(ext["dashboard_pages"], &(&1["id"] == "proxy-router"))

  defp section(ext, title_prefix) do
    Enum.find(page(ext)["sections"], &String.starts_with?(&1["title"] || "", title_prefix))
  end

  defp item(sec, label), do: Enum.find(sec["items"], &(&1["label"] == label))

  test "legacy all-time contracts separate usage from lifetime cost evidence" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: AlltimeStore)

    usage = section(ext, "All-time usage")
    costs = section(ext, "Lifetime costs")
    assert usage["type"] == "metrics"
    # summary blocks share a row on wide screens (frontend 0.3.6 span grammar)
    assert usage["span"] == "half"
    assert section(ext, "Today")["span"] == "half"
    assert usage["meta"] =~ "since 2026-06-26"
    assert usage["meta"] =~ "14 day"

    assert item(usage, "Requests")["value"] == 12_345
    assert item(usage, "Tokens")["value"] == "95M"
    assert item(usage, "Cache")["value"] == "50%"
    assert costs["columns"] == 2
    assert costs["meta"] =~ "comparability unverified"
    assert item(costs, "Repriced user total")["value"] == "$12.50"
    assert item(costs, "Router evidence")["value"] == "$7.25"
    assert item(costs, "Router evidence")["sub"] =~ "estimate"
  end

  test "router tile is omitted when the host has no router-total contract" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: AlltimeNoRouterStore)

    usage = section(ext, "All-time usage")
    costs = section(ext, "Lifetime costs")
    assert usage != nil
    assert item(costs, "Reported user total")["value"] == "$0.01"
    assert item(costs, "Router evidence") == nil
  end

  test "authoritative financial contract separates reconstructed history from same-scope margin" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: AlltimeAuthoritativeStore)

    usage = section(ext, "All-time usage")
    financials = section(ext, "Comparable accounting")

    assert financials["span"] == "full"
    assert financials["columns"] == 4
    assert item(usage, "Repriced spend") == nil
    assert item(usage, "Tokens")["value"] == "95M"
    assert item(usage, "Router cost") == nil
    assert section(ext, "Historical evidence") == nil

    assert financials["meta"] =~ "since 2026-07-15"
    assert financials["meta"] =~ "scope test-production-v1"
    assert item(financials, "User charges")["value"] == "$13.00"
    assert item(financials, "Router cost")["value"] == "$10.00"
    assert item(financials, "Cost-plus margin")["value"] == "$3.00"

    assert item(financials, "Cost-plus margin")["sub"] == "30.0% of router cost"

    assert item(financials, "Coverage")["value"] == "Reconciled"
    assert item(financials, "Coverage")["sub"] == "req 100/100 · tokens 95M/95M"

    assert item(financials, "Coverage")["title"] ==
             "Requests 100/100; tokens 95000000/95000000"
  end

  test "unreconciled financials expose raw totals but withhold numeric margin" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: AlltimeUnreconciledStore)
    financials = section(ext, "Comparable accounting")

    assert item(financials, "User charges")["value"] == "$13.00"
    assert item(financials, "Router cost")["value"] == "$11.00"
    assert item(financials, "Cost-plus margin")["value"] == "—"
    assert item(financials, "Cost-plus margin")["sub"] =~ "withheld"
    assert item(financials, "Coverage")["value"] == "Mismatch"
    assert item(financials, "Coverage")["sub"] == "req 99/100 · tokens 94M/95M"
    assert item(financials, "Coverage")["tone"] == "warn"
  end

  test "historical evidence shows both lifetime totals without implying comparability" do
    ext =
      Proxy.dashboard_extension(
        state_pid: dead_state(),
        store_mod: AlltimeHistoricalEvidenceStore
      )

    usage = section(ext, "All-time usage")
    costs = section(ext, "Historical evidence")

    assert length(usage["items"]) == 3
    assert costs["meta"] =~ "not comparable"
    assert costs["meta"] =~ "legacy shared key"
    assert costs["columns"] == 2
    assert item(costs, "Repriced user total")["value"] == "$133.63"
    assert item(costs, "Repriced user total")["sub"] =~ "archive-backed"
    assert item(costs, "Router evidence")["value"] == "$68.49"
    assert item(costs, "Router evidence")["sub"] =~ "legacy shared-key"
    assert section(ext, "Comparable accounting") == nil
  end

  test "mixed history never places lifetime totals inside the comparable margin card" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: AlltimeMixedScopeStore)
    history = section(ext, "Historical evidence")
    comparable = section(ext, "Comparable accounting")

    assert item(history, "Repriced user total")["value"] == "$136.61"
    assert item(history, "Router evidence")["value"] == "$71.54"
    assert item(comparable, "User charges")["value"] == "$1.30"
    assert item(comparable, "Router cost")["value"] == "$1.00"
    assert item(comparable, "Cost-plus margin")["value"] == "$0.30"
    assert item(comparable, "Coverage")["value"] == "Reconciled"
  end

  test "an unmarked financial contract is historical evidence, never comparable accounting" do
    ext =
      Proxy.dashboard_extension(state_pid: dead_state(), store_mod: AlltimeUnmarkedFinancialStore)

    assert section(ext, "Historical evidence") != nil
    assert section(ext, "Comparable accounting") == nil
  end

  test "observed token mismatch overrides a contradictory reconciled flag" do
    ext =
      Proxy.dashboard_extension(
        state_pid: dead_state(),
        store_mod: AlltimeContradictoryCoverageStore
      )

    comparable = section(ext, "Comparable accounting")
    assert item(comparable, "Cost-plus margin")["value"] == "—"
    assert item(comparable, "Coverage")["value"] == "Mismatch"
  end

  test "nil usage (empty / persistence-off store) contributes no all-time section" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: AlltimeEmptyStore)
    assert section(ext, "All-time") == nil
  end

  test "a store without the contract contributes no all-time section" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: HistoryWindowStore)
    assert section(ext, "All-time") == nil
  end

  test "a raising store contributes no all-time section (never a crashed snapshot)" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: AlltimeRaisingStore)
    assert section(ext, "All-time") == nil
  end

  test "history window is 30 days" do
    Process.register(self(), :alltime_test_proc)
    Proxy.dashboard_extension(state_pid: dead_state(), store_mod: HistoryWindowStore)
    assert_receive {:history_days, 30}
  after
    Process.unregister(:alltime_test_proc)
  end
end
