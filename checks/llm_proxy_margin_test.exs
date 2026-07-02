# Cost markup/margin test for Genswarms.LlmProxy: charge = (router-cost-or-rate-card) × (1 + margin%).
# Standalone — NO Postgres, NO network.
#
#   mix run tests/llm_proxy_margin_test.exs

repo_root = Path.expand(Path.join(__DIR__, ".."))


alias Genswarms.LlmProxy, as: Proxy

{:ok, failures} = Agent.start_link(fn -> [] end)

check = fn label, ok ->
  if ok do
    IO.puts("  ok   #{label}")
  else
    IO.puts("  FAIL #{label}")
    Agent.update(failures, &[label | &1])
  end
end

d = fn s -> Decimal.new(s) end
eq = fn a, b -> Decimal.equal?(a, b) end
# Final user-facing charge = sanitize_cost(markup_cost(base, rate_card, margin)).
charge = fn base, rate_card, margin ->
  {cost, invalid?} = Proxy.sanitize_cost(Proxy.markup_cost(base, rate_card, margin))
  {cost, invalid?}
end

zero = d.("0")

# ── 1. margin 0 + positive router cost → unchanged ───────────────────────────
{c, inv} = charge.(d.("0.10"), zero, "0")
check.("margin 0, paid base 0.10 → 0.10 (no markup)", eq.(c, d.("0.100000000")) and not inv)

# ── 2. margin 30 + positive router cost → base × 1.30 ────────────────────────
{c, _} = charge.(d.("0.10"), zero, "30")
check.("margin 30, paid base 0.10 → 0.13", eq.(c, d.("0.130000000")))

# ── 3. FREE model (base 0) + rate card + margin 30 → rate_card × 1.30 ────────
{c, _} = charge.(zero, d.("0.20"), "30")
check.("margin 30, FREE base 0 w/ rate_card 0.20 → 0.26", eq.(c, d.("0.260000000")))

# ── 4. FREE model + rate card + margin 0 → rate_card (no markup) ─────────────
{c, _} = charge.(zero, d.("0.20"), "0")
check.("margin 0, FREE base 0 w/ rate_card 0.20 → 0.20", eq.(c, d.("0.200000000")))

# ── 5. FREE model + NO rate card (0) → 0 (today's behaviour, safe default) ────
{c, _} = charge.(zero, zero, "30")
check.("FREE base 0, no rate_card, margin 30 → 0 (unchanged default)", eq.(c, zero))

# ── 6. margin as integer (not string) also works ─────────────────────────────
{c, _} = charge.(d.("0.10"), zero, 30)
check.("margin 30 (integer) → 0.13", eq.(c, d.("0.130000000")))

# ── 7. non-finite base (hostile upstream "Infinity") → passthrough → flagged ─
{c, inv} = charge.("Infinity", d.("0.20"), "30")
check.("non-finite base 'Infinity' → 0 + invalid flag (NOT silently rate-carded)", eq.(c, zero) and inv)

# ── 8. negative base is anomalous → floored to 0 (NOT rate-carded) ───────────
{c, inv} = charge.(d.("-0.05"), d.("0.20"), "30")
check.("negative base → floored to 0 (NOT rate-carded), not flagged", eq.(c, zero) and not inv)

# ── 9. apply_margin/2 is a pure no-op for margin 0 / blank / negative ─────────
check.("apply_margin(x, 0) == x", eq.(Proxy.apply_margin(d.("0.10"), "0"), d.("0.10")))
check.("apply_margin(x, '') == x", eq.(Proxy.apply_margin(d.("0.10"), ""), d.("0.10")))
check.("apply_margin(x, nil) == x", eq.(Proxy.apply_margin(d.("0.10"), nil), d.("0.10")))
check.("apply_margin(x, 50) == x*1.5", eq.(Proxy.apply_margin(d.("0.10"), "50"), d.("0.15")))

# ── 10. markup does not amplify a positive base via the rate card ────────────
# A paid base BELOW the rate card still bills the paid base (× margin), not the rate card.
{c, _} = charge.(d.("0.01"), d.("0.20"), "30")
check.("paid base 0.01 (< rate_card) → 0.013, NOT rate-carded", eq.(c, d.("0.013000000")))

# ── crash-1: cost_usd/2 must never RAISE on hostile/malformed upstream token counts ──
# (a non-integer prompt_tokens would make Decimal.new/1 raise → masked 502). It must
# coerce every shape to a Decimal: garbage → 0, numeric string/float → its value.
prices = %{prompt_per_mtok: "0.28", completion_per_mtok: "0.42"}
safe_cost = fn usage ->
  try do
    {:ok, Genswarms.LlmProxy.Plug.cost_usd(usage, prices)}
  rescue
    e -> {:raised, e}
  end
end

for {label, usage} <- [
      {"string 'abc'", %{"prompt_tokens" => "abc", "completion_tokens" => 500}},
      {"float", %{"prompt_tokens" => 100.5, "completion_tokens" => 7}},
      {"map garbage", %{"prompt_tokens" => %{}, "completion_tokens" => []}},
      {"nil", %{"prompt_tokens" => nil, "completion_tokens" => nil}},
      {"missing keys", %{}},
      {"negative", %{"prompt_tokens" => -9, "completion_tokens" => -1}}
    ] do
  check.("cost_usd does not raise on hostile usage (#{label}) → returns a Decimal",
    match?({:ok, %Decimal{}}, safe_cost.(usage)))
end

# normal integers still price correctly: 1000*0.28/1e6 + 500*0.42/1e6 = 0.00049
{:ok, normal} = safe_cost.(%{"prompt_tokens" => 1000, "completion_tokens" => 500})
check.("cost_usd prices normal integer counts (0.00049)", eq.(normal, d.("0.00049")))
# a numeric STRING count is preserved, not zeroed (only true garbage → 0)
{:ok, str} = safe_cost.(%{"prompt_tokens" => "1000", "completion_tokens" => "500"})
check.("cost_usd treats a numeric-string count as its value (0.00049, not 0)", eq.(str, d.("0.00049")))

fails = Agent.get(failures, & &1)

if fails == [] do
  IO.puts("\nLLM_PROXY_MARGIN: ALL PASS")
else
  IO.puts("\nLLM_PROXY_MARGIN: #{length(fails)} FAILED")
  System.halt(1)
end
