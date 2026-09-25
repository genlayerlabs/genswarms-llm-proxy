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

  defp financials do
    %{
      spent_usd: Decimal.new(13),
      router_cost_usd: Decimal.new(10),
      gross_margin_usd: Decimal.new(3),
      gross_margin_pct: Decimal.new(30),
      authoritative: true,
      reconciled: true,
      days: 1,
      legacy_router_included: true
    }
  end

  defp section(ext, title), do: Enum.find(sections(ext), &(&1["title"] == title))

  test "malformed optional financial amounts cannot become zero" do
    for key <- [
          :lifetime_spent_usd,
          :lifetime_router_cost_usd,
          :gross_margin_usd,
          :gross_margin_pct
        ],
        bad <- ["bad", Decimal.new("NaN"), Decimal.new("Infinity")] do
      Process.put(:financials, Map.put(financials(), key, bad))
      ext = extension()
      assert section(ext, "Accounting")["meta"] =~ "unavailable"
      assert metric(ext, "Requests") == 501
    end
  end

  test "missing margin amounts stay unavailable instead of fabricated zero" do
    for key <- [:gross_margin_usd, :gross_margin_pct] do
      Process.put(:financials, Map.delete(financials(), key))
      ext = extension()

      margin =
        section(ext, "Comparable accounting")["items"]
        |> Enum.find(&(&1["label"] == "Cost-plus margin"))

      if key == :gross_margin_usd do
        assert margin["value"] == "unavailable"
      else
        assert margin["value"] == "$3.00"
        assert margin["sub"] =~ "unavailable"
      end

      assert metric(ext, "Requests") == 501
    end
  end

  test "optional nil amounts remain unavailable while absent lifetime fields use legacy totals" do
    Process.put(:financials, financials())
    assert metric(extension(), "Repriced user total") == "$13.00"

    for key <- [
          :lifetime_spent_usd,
          :lifetime_router_cost_usd,
          :gross_margin_usd,
          :gross_margin_pct
        ] do
      Process.put(:financials, Map.put(financials(), key, nil))
      ext = extension()
      refute section(ext, "Accounting")

      label =
        case key do
          :lifetime_spent_usd -> "Repriced user total"
          :lifetime_router_cost_usd -> "Router evidence"
          _ -> "Cost-plus margin"
        end

      if key == :gross_margin_pct do
        margin =
          section(ext, "Comparable accounting")["items"] |> Enum.find(&(&1["label"] == label))

        assert margin["sub"] =~ "unavailable"
      else
        assert metric(ext, label) == "unavailable"
      end
    end
  end

  test "malformed accounting metadata does not hide healthy today sections" do
    {:ok, usage} = ReliabilityProxyStore.llm_usage_summary(Date.utc_today())
    Process.put(:alltime, Map.put(usage, :days, %{}))
    Process.put(:financials, Map.put(financials(), :days, %{}))
    ext = extension()
    assert metric(ext, "Requests") == 501
    assert section(ext, "All-time usage")["meta"] =~ "unavailable"
    assert section(ext, "Accounting")["meta"] =~ "unavailable"
  end

  test "history rejects malformed optional router amounts but accepts nil" do
    {:ok, row} = ReliabilityProxyStore.llm_usage_summary(Date.utc_today())
    row = Map.put(row, :day, Date.utc_today())

    for bad <- ["bad", Decimal.new("NaN"), Decimal.new("Infinity")] do
      Process.put(:history, [Map.put(row, :router_cost_usd, bad)])
      ext = extension()
      assert section(ext, "History")["meta"] =~ "unavailable"
      assert metric(ext, "Requests") == 501
    end

    Process.put(:history, [
      Map.put(row, :router_cost_usd, nil),
      Map.put(row, :router_cost_usd, Decimal.new(1))
    ])

    history = section(extension(), "History · last 30 UTC days")
    assert hd(history["rows"])["router"] == "—"
  end

  test "unavailable summary publishes no arithmetic health rules" do
    Process.put(:summary, {:error, :unavailable})
    ext = extension()
    assert ext["llm_proxy_budget"]["health_rules"] == []
    assert ext["llm_proxy_budget"]["available"] == false
    assert ext["llm_proxy_budget"]["spent_usd"] == nil
    assert extension(ReliabilityProxyLegacyStore)["llm_proxy_budget"]["health_rules"] == []
  end
end
