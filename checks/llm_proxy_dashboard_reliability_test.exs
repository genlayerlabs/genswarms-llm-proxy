ExUnit.start()

defmodule ReliabilityProxyStore do
  def llm_usage_by_budget(day, limit) do
    read(
      :details,
      for(
        n <- 1..min(Process.get(:budgets, 501), limit),
        do: %{
          budget_identity: "budget_#{n}",
          day: day,
          spent_usd: Decimal.new("0.004"),
          limit_usd: Decimal.new(1),
          requests: 1,
          total_tokens: 10,
          prompt_tokens: 8,
          cached_tokens: 0
        }
      )
    )
  end

  def llm_usage_summary(_day) do
    n = Process.get(:budgets, 501)

    read(
      :summary,
      {:ok,
       %{
         budgets: n,
         requests: n,
         total_tokens: n * 10,
         prompt_tokens: n * 8,
         cached_tokens: 0,
         spent_usd: Decimal.mult("0.004", n)
       }}
    )
  end

  def llm_usage_alltime, do: read(:alltime, nil)
  def llm_router_cost_today, do: read(:router, nil)
  def llm_financials_alltime, do: read(:financials, nil)
  def llm_usage_by_model(_day), do: read(:models, [])
  def llm_usage_days(_days), do: read(:history, [])
  def llm_usage_by_budget_since(window, _limit), do: read({:period, window}, [])

  defp read(key, default) do
    case Process.get(key, default) do
      :raise -> raise "database unavailable"
      result -> result
    end
  end
end

defmodule ReliabilityProxyLegacyStore do
  defdelegate llm_usage_by_budget(day, limit), to: ReliabilityProxyStore
end

defmodule ProxyReliabilityTest do
  use ExUnit.Case, async: true

  defp extension(store \\ ReliabilityProxyStore),
    do:
      Genswarms.LlmProxy.dashboard_extension(
        store_mod: store,
        state_pid: :missing_reliability_proxy
      )

  defp sections(ext), do: hd(ext["dashboard_pages"])["sections"]

  defp metric(ext, label),
    do:
      sections(ext)
      |> Enum.flat_map(&Map.get(&1, "items", []))
      |> Enum.find(
        &(&1["label"] == label or (label == "Budget identities" and &1["label"] == "Users"))
      )
      |> Map.fetch!("value")

  test "101 and 501 budgets retain complete headlines and currency precision" do
    for n <- [100, 101, 501] do
      Process.put(:budgets, n)
      ext = extension()
      assert metric(ext, "Budget identities") == n
      assert metric(ext, "Requests") == n
      assert ext["proxy_router"]["budgets"] == n
      assert ext["llm_proxy_budget"]["spent_usd"] == Decimal.to_float(Decimal.mult("0.004", n))

      assert metric(ext, "User charges") ==
               "$" <> (Decimal.mult("0.004", n) |> Decimal.round(2) |> Decimal.to_string(:normal))

      users = Enum.find(sections(ext), &(&1["type"] == "tabs"))
      assert length(hd(users["tabs"])["section"]["rows"]) == 100
    end
  end

  test "absent summary makes old-store complete totals explicitly unavailable" do
    ext = extension(ReliabilityProxyLegacyStore)
    assert metric(ext, "Requests") == "unavailable"
    assert ext["llm_proxy"]["requests"] == nil
    assert ext["llm_proxy_budget"]["spent_usd"] == nil
  end

  test "bad summary never manufactures zero and keeps detail tables" do
    for bad <- [{:error, :unavailable}, {:ok, %{}}, {:ok, %{requests: "no"}}, :raise] do
      Process.put(:summary, bad)
      ext = extension()
      assert metric(ext, "Requests") == "unavailable"
      assert metric(ext, "User charges") == "unavailable"
      assert ext["llm_proxy_budget"]["spent_usd"] == nil
    end
  end

  test "malformed and failed detail sections preserve healthy aggregate sections" do
    for bad <- [{:error, :unavailable}, [nil], :raise] do
      Process.put(:models, bad)
      Process.put(:history, bad)
      Process.put(:details, bad)
      Process.put({:period, 7}, bad)
      ext = extension()
      assert metric(ext, "Requests") == 501

      for title <- ["By model", "History"] do
        assert Enum.find(sections(ext), &(&1["title"] == title))["meta"] =~ "unavailable"
      end

      users = Enum.find(sections(ext), &(&1["type"] == "tabs"))
      assert Enum.at(users["tabs"], 1)["section"]["meta"] =~ "unavailable"
      assert Enum.at(users["tabs"], 2)["section"]["rows"] == []
    end
  end

  test "malformed map fields are unavailable and lifetime failures preserve today" do
    for key <- [:alltime, :router, :financials], do: Process.put(key, %{})
    for key <- [:models, :history], do: Process.put(key, [%{}])
    ext = extension()
    assert metric(ext, "Requests") == 501
    assert metric(ext, "Router cost") == "unavailable"

    for title <- ["All-time usage", "Accounting", "By model", "History"] do
      assert Enum.find(sections(ext), &(&1["title"] == title))["meta"] =~ "unavailable"
    end
  end

  test "malformed budget fields cannot appear as zero-spend rows" do
    Process.put(:details, [%{budget_identity: "bad", spent_usd: "not money"}])
    ext = extension()
    users = Enum.find(sections(ext), &(&1["type"] == "tabs"))
    assert hd(users["tabs"])["section"]["meta"] =~ "unavailable"
    assert metric(ext, "Requests") == 501
  end

  test "101 budget identities exceed the 100 displayed rows" do
    Process.put(:budgets, 101)
    assert metric(extension(), "Budget identities") == 101
  end

  test "501 requests exceed the old 500-row read" do
    assert metric(extension(), "Requests") == 501
  end
end
