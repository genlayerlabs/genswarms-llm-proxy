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
      mismatched_days: 0,
      reconciled: true,
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
      mismatched_days: 1,
      reconciled: false,
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

  test "all-time metrics section renders both spends from the probed contracts" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: AlltimeStore)

    sec = section(ext, "All-time")
    assert sec["type"] == "metrics"
    # summary blocks share a row on wide screens (frontend 0.3.6 span grammar)
    assert sec["span"] == "half"
    assert section(ext, "Today")["span"] == "half"
    assert sec["meta"] =~ "since 2026-06-26"
    assert sec["meta"] =~ "14 day"

    assert item(sec, "Charged users")["value"] == "$12.50"
    assert item(sec, "Router charged us")["value"] == "$7.25"
    assert item(sec, "Router charged us")["sub"] =~ "estimate"
    assert item(sec, "Requests")["value"] == 12_345
    assert item(sec, "Tokens")["value"] == "95M"
    assert item(sec, "Cache")["value"] == "50%"
  end

  test "router tile is omitted when the host has no router-total contract" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: AlltimeNoRouterStore)

    sec = section(ext, "All-time")
    assert sec != nil
    assert item(sec, "Charged users")["value"] == "$0.01"
    assert item(sec, "Router charged us") == nil
  end

  test "authoritative financial contract separates reconstructed history from same-scope margin" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: AlltimeAuthoritativeStore)

    usage = section(ext, "All-time usage")
    financials = section(ext, "Costs")

    assert item(usage, "Repriced spend") == nil
    assert item(usage, "Tokens")["value"] == "95M"
    assert item(usage, "Router charged us") == nil

    assert financials["meta"] =~ "authoritative source since 2026-07-15"
    assert financials["meta"] =~ "reconciled"
    assert financials["meta"] =~ "scope test-production-v1"
    assert item(financials, "Charged users")["value"] == "$13.00"
    assert item(financials, "Router charged us")["value"] == "$10.00"
    assert item(financials, "Cost-plus margin")["value"] == "$3.00"

    assert item(financials, "Cost-plus margin")["sub"] ==
             "30.0% of comparable router cost since cutover"

    assert item(financials, "Request coverage")["value"] == "100/100"
    assert item(financials, "Request coverage")["sub"] == "ledger/router matched"
  end

  test "unreconciled financials expose raw totals but withhold numeric margin" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: AlltimeUnreconciledStore)
    financials = section(ext, "Costs")

    assert financials["meta"] =~ "UNRECONCILED"
    assert item(financials, "Charged users")["value"] == "$13.00"
    assert item(financials, "Router charged us")["value"] == "$11.00"
    assert item(financials, "Cost-plus margin")["value"] == "—"
    assert item(financials, "Cost-plus margin")["sub"] =~ "withheld"
    assert item(financials, "Request coverage")["value"] == "99/100"
    assert item(financials, "Request coverage")["sub"] =~ "mismatch"
  end

  test "historical evidence shows both lifetime totals without implying comparability" do
    ext =
      Proxy.dashboard_extension(
        state_pid: dead_state(),
        store_mod: AlltimeHistoricalEvidenceStore
      )

    usage = section(ext, "All-time usage")
    costs = section(ext, "Costs")

    assert length(usage["items"]) == 3
    assert costs["meta"] =~ "not comparable"
    assert costs["meta"] =~ "legacy-shared-key"
    assert item(costs, "Charged users")["value"] == "$133.63"
    assert item(costs, "Charged users")["sub"] =~ "all-time"
    assert item(costs, "Router charged us")["value"] == "$68.49"
    assert item(costs, "Router charged us")["sub"] =~ "not comparable"
    assert item(costs, "Cost-plus margin")["value"] == "—"
    assert item(costs, "Comparable")["value"] == "No"
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
