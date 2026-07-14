# TWO spends, deliberately distinct: what USERS are charged (default
# pricing_mode :cost_plus uses provider cost + margin, with the rate card as a
# zero/unknown/invalid fallback) vs what the router says the traffic cost
# (provider_cost_usd per call + the host-synced day estimate on the page).
#   mix run checks/llm_proxy_two_spends_test.exs
ExUnit.start()

defmodule RouterCostStore do
  def llm_router_cost_today do
    %{
      cost_usd: Decimal.new("0.919472"),
      estimated: true,
      authoritative: true,
      fetched_at: ~U[2026-07-15 13:42:00Z]
    }
  end

  def llm_usage_days(_days) do
    [
      %{
        day: Date.utc_today(),
        budgets: 3,
        requests: 10,
        prompt_tokens: 1000,
        total_tokens: 1100,
        cached_tokens: 0,
        spent_usd: Decimal.new("0.5"),
        router_cost_usd: Decimal.new("0.9")
      },
      %{
        day: Date.add(Date.utc_today(), -1),
        budgets: 1,
        requests: 5,
        prompt_tokens: 500,
        total_tokens: 550,
        cached_tokens: 0,
        spent_usd: Decimal.new("0.1"),
        router_cost_usd: nil
      }
    ]
  end
end

defmodule NoRouterStore do
  def list_llm_usage(_limit), do: []
end

defmodule LegacyRouterCostStore do
  def llm_router_cost_today do
    %{
      cost_usd: Decimal.new("0.919472"),
      estimated: true,
      authoritative: false,
      fetched_at: ~U[2026-07-14 12:05:00Z]
    }
  end
end

defmodule OneBudgetStore do
  def list_llm_usage(_limit) do
    [
      %{
        budget_identity: "llmb_x",
        day: Date.utc_today(),
        session_id: "llms_x",
        spent_usd: Decimal.new("0.01"),
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

defmodule GenswarmsLlmProxyTwoSpendsTest do
  use ExUnit.Case, async: false
  alias Genswarms.LlmProxy, as: Proxy
  alias Genswarms.LlmProxy.Plug, as: ProxyPlug

  @usage %{"prompt_tokens" => 1_000_000, "completion_tokens" => 0, "total_tokens" => 1_000_000}
  @prices %{prompt_per_mtok: 2.0, completion_per_mtok: 10.0}

  defp opts(mode, margin_pct \\ 0),
    do: %{prices: @prices, margin_pct: margin_pct, pricing_mode: mode}

  test "rate_card_first: the SET price bills even when the router call was free" do
    {charge, false} =
      ProxyPlug.executed_cost_usd(@usage, opts(:rate_card_first), %{"cost_usd" => 0}, nil)

    assert Decimal.equal?(charge, Decimal.new("2"))

    # ... and even when the router reports a REAL (different) cost
    {charge2, false} =
      ProxyPlug.executed_cost_usd(@usage, opts(:rate_card_first), %{"cost_usd" => 0.3}, nil)

    assert Decimal.equal?(charge2, Decimal.new("2"))
  end

  test "cost_plus charges the direct provider cost plus the configured margin" do
    {charge, false} =
      ProxyPlug.executed_cost_usd(@usage, opts(:cost_plus, 30), %{"cost_usd" => 0.3}, nil)

    assert Decimal.equal?(charge, Decimal.new("0.39"))
  end

  test "cost_plus uses rate card plus margin for zero, unknown, invalid, and session-only cost" do
    routers = [
      %{"cost_usd" => 0},
      %{},
      %{"cost_usd" => "junk"},
      %{"session_acc" => %{"cost_usd" => 99}}
    ]

    for router <- routers do
      {charge, false} = ProxyPlug.executed_cost_usd(@usage, opts(:cost_plus, 30), router, nil)
      assert Decimal.equal?(charge, Decimal.new("2.6"))
    end
  end

  # 0.2.10 (micromarkets#450 review): a HALF-configured card must never count
  # as configured — with the old `or` semantics, rate_card_first billed the
  # missing leg at $0 while ignoring the real router cost (undercharge, ≈$0
  # on completion-heavy calls). A half card now falls back to router cost.
  test "rate_card_first with a HALF card falls back to the router cost (never a $0 bill)" do
    completion_heavy = %{
      "prompt_tokens" => 0,
      "completion_tokens" => 1_000_000,
      "total_tokens" => 1_000_000
    }

    for half <- [
          %{prompt_per_mtok: 2.0},
          %{prompt_per_mtok: 2.0, completion_per_mtok: nil},
          %{completion_per_mtok: 10.0},
          %{"prompt_per_mtok" => 2.0}
        ] do
      half_opts = %{prices: half, margin_pct: 0, pricing_mode: :rate_card_first}

      {charge, false} =
        ProxyPlug.executed_cost_usd(completion_heavy, half_opts, %{"cost_usd" => 0.3}, nil)

      assert Decimal.equal?(charge, Decimal.new("0.3")),
             "half card #{inspect(half)} must bill router cost, got #{inspect(charge)}"
    end
  end

  test "rate_card_first with an EMPTY card falls back to the router cost" do
    empty_opts = %{prices: %{}, margin_pct: 0, pricing_mode: :rate_card_first}

    {charge, false} =
      ProxyPlug.executed_cost_usd(@usage, empty_opts, %{"cost_usd" => 0.3}, nil)

    assert Decimal.equal?(charge, Decimal.new("0.3"))
  end

  test "rate_card_first with BOTH prices (string keys too) still bills the card" do
    string_opts = %{
      prices: %{"prompt_per_mtok" => 2.0, "completion_per_mtok" => 10.0},
      margin_pct: 0,
      pricing_mode: :rate_card_first
    }

    {charge, false} =
      ProxyPlug.executed_cost_usd(@usage, string_opts, %{"cost_usd" => 0.3}, nil)

    assert Decimal.equal?(charge, Decimal.new("2"))
  end

  test "provider cost classification preserves known zero and distinguishes bad data" do
    assert ProxyPlug.provider_cost_result(%{"cost_usd" => 0}) == {:known, Decimal.new("0")}
    assert ProxyPlug.provider_cost_result(%{}) == :unknown
    assert ProxyPlug.provider_cost_result(%{"cost_usd" => nil}) == :unknown
    assert ProxyPlug.provider_cost_result(%{"cost_usd" => "junk"}) == :invalid
    assert ProxyPlug.provider_cost_result(%{"cost_usd" => -1}) == :invalid
    assert ProxyPlug.provider_cost_result(%{"cost_usd" => "Infinity"}) == :invalid

    assert Decimal.equal?(ProxyPlug.provider_cost_usd(%{"cost_usd" => 0.3}), Decimal.new("0.3"))
    assert Decimal.equal?(ProxyPlug.provider_cost_usd(%{}), Decimal.new("0"))
    assert Decimal.equal?(ProxyPlug.provider_cost_usd(%{"cost_usd" => "junk"}), Decimal.new("0"))
    assert ProxyPlug.provider_cost_state(%{"cost_usd" => 0.3}) == "known"
    assert ProxyPlug.provider_cost_state(%{"cost_usd" => 0}) == "zero"
    assert ProxyPlug.provider_cost_state(%{}) == "missing"
    assert ProxyPlug.provider_cost_state(%{"cost_usd" => "junk"}) == "invalid"
    assert ProxyPlug.charge_basis(opts(:cost_plus), %{"cost_usd" => 0.3}) == "provider_cost"
    assert ProxyPlug.charge_basis(opts(:cost_plus), %{}) == "rate_card"
  end

  test "cost-plus boot contract requires a complete valid fallback card" do
    assert :ok = Proxy.validate_pricing_config!(:cost_plus, @prices)
    assert :ok = Proxy.validate_pricing_config!(:rate_card_first, %{})

    for bad <- [
          %{},
          %{prompt_per_mtok: 2.0},
          %{prompt_per_mtok: -1, completion_per_mtok: 2},
          %{prompt_per_mtok: "junk", completion_per_mtok: 2}
        ] do
      assert_raise ArgumentError, fn -> Proxy.validate_pricing_config!(:cost_plus, bad) end
    end

    for bad_margin <- [-1, "junk", "Infinity"] do
      assert_raise ArgumentError, fn ->
        Proxy.validate_pricing_config!(:cost_plus, @prices, bad_margin)
      end
    end
  end

  test "pricing_mode config canonicalizes cost-plus aliases and defaults cost-plus" do
    assert Proxy.pricing_mode(:rate_card_first) == :rate_card_first
    assert Proxy.pricing_mode("rate_card_first") == :rate_card_first
    assert Proxy.pricing_mode(:cost_plus) == :cost_plus
    assert Proxy.pricing_mode("cost_plus") == :cost_plus
    assert Proxy.pricing_mode(:provider_first) == :cost_plus
    assert Proxy.pricing_mode("provider_first") == :cost_plus
    assert Proxy.pricing_mode("anything") == :cost_plus
    assert Proxy.pricing_mode(nil) == :cost_plus
  end

  # ── page: both numbers, clearly labeled ─────────────────────────────────────

  defp dead_state do
    {:ok, sp} =
      Agent.start(fn -> %{sessions: %{}, usage: %{}, notified: MapSet.new(), global: %{}} end)

    sp
  end

  defp page(ext), do: Enum.find(ext["dashboard_pages"], &(&1["id"] == "proxy-router"))

  test "Today separates usage from user charges and the fresh router cost" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: RouterCostStore)
    usage = Enum.find(page(ext)["sections"], &(&1["title"] == "Today usage"))
    costs = Enum.find(page(ext)["sections"], &(&1["title"] == "Today costs"))
    usage_labels = Enum.map(usage["items"], & &1["label"])
    cost_labels = Enum.map(costs["items"], & &1["label"])

    refute "User charges" in usage_labels
    refute "Router cost" in usage_labels
    assert "User charges" in cost_labels
    assert "Router cost" in cost_labels
    assert costs["columns"] == 2
    assert costs["meta"] == "same-scope UTC day"
    user = Enum.find(costs["items"], &(&1["label"] == "User charges"))
    router = Enum.find(costs["items"], &(&1["label"] == "Router cost"))
    assert user["value"] == "$0.00"
    assert router["value"] == "$0.92"
    assert router["sub"] == "router estimate · updated 13:42 UTC"
    assert router["wrap_sub"] == true
  end

  test "a store without llm_router_cost_today/0 contributes no Router-cost tile" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: NoRouterStore)
    costs = Enum.find(page(ext)["sections"], &(&1["title"] == "Today costs"))
    refute Enum.any?(costs["items"], &(&1["label"] == "Router cost"))
    assert costs["meta"] == "router cost unavailable"
  end

  test "Today shows legacy router evidence but marks it non-comparable" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: LegacyRouterCostStore)
    costs = Enum.find(page(ext)["sections"], &(&1["title"] == "Today costs"))
    router = Enum.find(costs["items"], &(&1["label"] == "Router cost"))

    assert router["value"] == "$0.92"
    assert router["sub"] == "router estimate · updated 12:05 UTC"
    assert costs["meta"] == "legacy shared key · not comparable"
  end

  test "Users rows carry _cid metadata (never a column) for the dashboard's inspector" do
    ext =
      Proxy.dashboard_extension(
        state_pid: dead_state(),
        store_mod: OneBudgetStore,
        origins_by_budget: %{"llmb_x" => %{conversation_id: "tg:9:0", kind: "dm"}}
      )

    users = Enum.find(page(ext)["sections"], &(&1["title"] == "Users"))
    [row] = users["rows"]

    assert row["_cid"] == "tg:9:0"
    refute Enum.any?(users["columns"], &(&1["key"] == "_cid"))
  end

  test "History grows a router column when any day carries router_cost_usd" do
    ext = Proxy.dashboard_extension(state_pid: dead_state(), store_mod: RouterCostStore)
    hist = Enum.find(page(ext)["sections"], &String.starts_with?(&1["title"] || "", "History"))

    assert Enum.any?(hist["columns"], &(&1["key"] == "router"))
    assert Enum.any?(hist["columns"], &(&1["label"] == "user spent"))

    [today_row, yesterday_row] = hist["rows"]
    assert today_row["router"] == "$0.90"
    assert today_row["spent"] == "$0.50"
    # a day the host has no router estimate for renders an em-dash, not $0
    assert yesterday_row["router"] == "—"
  end
end
