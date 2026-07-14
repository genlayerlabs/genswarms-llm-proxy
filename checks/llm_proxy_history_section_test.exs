# Durable day-history section on the proxy-router page — probed store contract
# (`store_mod.llm_usage_days/1`, host-owned SQL), same fail-open discipline as the
# By-model section: absent function or raising store contributes NOTHING.
#   mix run checks/llm_proxy_history_section_test.exs
ExUnit.start()

defmodule HistoryStore do
  # llm_usage_days/1 contract: newest-first day aggregates across ALL budgets.
  def llm_usage_days(days) when is_integer(days) do
    [
      %{
        day: Date.utc_today(),
        budgets: 36,
        requests: 295,
        prompt_tokens: 4_332_260,
        total_tokens: 4_363_794,
        cached_tokens: 1_147_392,
        spent_usd: Decimal.new("0")
      },
      %{
        day: Date.add(Date.utc_today(), -1),
        budgets: 1,
        requests: 216,
        prompt_tokens: 2_000_000,
        total_tokens: 2_100_000,
        cached_tokens: 0,
        spent_usd: Decimal.new("0.25")
      }
    ]
  end
end

defmodule NoHistoryStore do
  def list_llm_usage(_limit), do: []
end

defmodule RaisingStore do
  def llm_usage_days(_days), do: raise("boom")
  def list_llm_usage(_limit), do: []
end

defmodule GenswarmsLlmProxyHistorySectionTest do
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

  test "history table renders newest-first day rows from the probed store" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: HistoryStore)

    hist = section(ext, "History")
    assert hist["type"] == "table"

    [today_row, yesterday_row] = hist["rows"]
    assert today_row["day"] == Date.to_iso8601(Date.utc_today())
    assert today_row["req"] == 295
    assert today_row["tokens"] == 4_363_794
    assert today_row["budgets"] == 36
    # cache rate derived from cached/prompt, spend rendered as money
    assert is_binary(today_row["cache"])
    assert yesterday_row["spent"] == "$0.25"
  end

  test "a store without llm_usage_days/1 contributes no history section" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: NoHistoryStore)
    assert section(ext, "History") == nil
  end

  test "a raising store contributes no history section (never a crashed snapshot)" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: RaisingStore)
    assert section(ext, "History") == nil
    assert page(ext) != nil
  end
end
