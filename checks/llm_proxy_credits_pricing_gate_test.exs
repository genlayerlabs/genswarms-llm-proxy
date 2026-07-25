# D9 — CREDITS IMPLY PRICING. Standalone — NO Postgres, NO network.
#
#   mix run checks/llm_proxy_credits_pricing_gate_test.exs
#
# A user who pays USDC into a proxy that charges $0.00 per call has bought
# nothing: the credit is never consumed, the balance never moves, and the books
# carry the liability forever. That is an accounting fiction, and it is silent.
# So with credits ON (payments_source configured) the operator rate card must be
# able to VALUE a call, in EVERY pricing mode — a complete non-negative card
# with at least one positive per-Mtok price. init/1 refuses to boot otherwise.
#
# The negative direction matters just as much (prime invariant): with credits
# OFF the gate never fires, so a 0/0 card — a genuine free tier — still boots.

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

port = 24_419

base = %{
  upstream_endpoint: "https://llm.example/v1/chat/completions",
  upstream_api_key: "sk-d9-gate-key"
}

boot = fn config ->
  try do
    case Proxy.init(config) do
      {:ok, state} ->
        Proxy.terminate(:shutdown, state)
        :booted
    end
  rescue
    e in ArgumentError -> {:raised, Exception.message(e)}
  end
end

good_card = %{prompt_per_mtok: "0.28", completion_per_mtok: "0.42"}

# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 1: credits OFF — the gate never fires (prime invariant)]")
# ────────────────────────────────────────────────────────────────────────────

off_cases = [
  {"no prices key at all", %{}},
  {"empty price map", %{prices: %{}}},
  {"a 0/0 free-tier card", %{prices: %{prompt_per_mtok: "0", completion_per_mtok: "0"}}},
  {"an incomplete card (prompt only)", %{prices: %{prompt_per_mtok: "0.28"}}},
  {"payments_source: nil", %{prices: %{}, payments_source: nil}},
  {"payments_source: false", %{prices: %{}, payments_source: false}},
  {"payments_source: \"\"", %{prices: %{}, payments_source: ""}}
]

for {label, overrides} <- Enum.with_index(off_cases) |> Enum.map(fn {{l, o}, i} -> {l, Map.put(o, :port, port + i)} end) do
  # :rate_card_first so validate_pricing_config!/3 (the pre-existing cost_plus
  # gate) cannot be what accepts or rejects these — this isolates D9.
  result = boot.(Map.merge(base, Map.put(overrides, :pricing_mode, :rate_card_first)))

  check.(
    "credits OFF + #{label} still boots (0.3.0 behavior, untouched)",
    result == :booted
  )
end

# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 2: credits ON — an unpriceable call REFUSES to boot]")
# ────────────────────────────────────────────────────────────────────────────

refuse_cases = [
  {"no prices key at all", %{}},
  {"empty price map", %{prices: %{}}},
  {"a 0/0 card (every call would cost $0.00)", %{prices: %{prompt_per_mtok: "0", completion_per_mtok: "0"}}},
  {"prompt-only card (incomplete)", %{prices: %{prompt_per_mtok: "0.28"}}},
  {"completion-only card (incomplete)", %{prices: %{completion_per_mtok: "0.42"}}},
  {"unparseable price", %{prices: %{prompt_per_mtok: "0,28", completion_per_mtok: "0.42"}}},
  {"negative price", %{prices: %{prompt_per_mtok: "-0.28", completion_per_mtok: "0.42"}}},
  {"non-finite price", %{prices: %{prompt_per_mtok: "Infinity", completion_per_mtok: "0.42"}}},
  {"non-map prices", %{prices: "0.28/0.42"}}
]

for {label, overrides} <-
      refuse_cases
      |> Enum.with_index()
      |> Enum.map(fn {{l, o}, i} -> {l, Map.put(o, :port, port + 100 + i)} end) do
  result =
    boot.(
      Map.merge(base, Map.merge(overrides, %{pricing_mode: :rate_card_first, payments_source: "payments"}))
    )

  check.(
    "credits ON + #{label} refuses to boot with a clear ArgumentError",
    match?({:raised, _}, result) and
      String.contains?(elem(result, 1), "credits are enabled") and
      String.contains?(elem(result, 1), "cannot value a call")
  )
end

# The same refusal holds in :cost_plus — the card there is the FALLBACK used
# whenever provider cost is zero/missing, so a 0/0 card is the same fiction.
cost_plus_zero =
  boot.(
    Map.merge(base, %{
      port: port + 200,
      pricing_mode: :cost_plus,
      prices: %{prompt_per_mtok: "0", completion_per_mtok: "0"},
      payments_source: "payments"
    })
  )

check.(
  "credits ON + :cost_plus with a 0/0 fallback card also refuses (mode-independent)",
  match?({:raised, _}, cost_plus_zero) and
    String.contains?(elem(cost_plus_zero, 1), "cannot value a call")
)

# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 3: credits ON with a card that CAN value a call — boots]")
# ────────────────────────────────────────────────────────────────────────────

allow_cases = [
  {"a normal 0.28/0.42 card", good_card},
  {"float prices", %{prompt_per_mtok: 0.25, completion_per_mtok: 0.75}},
  {"string keys", %{"prompt_per_mtok" => "0.28", "completion_per_mtok" => "0.42"}},
  {"one price legitimately zero (completion free)", %{prompt_per_mtok: "0.28", completion_per_mtok: "0"}},
  {"one price legitimately zero (prompt free)", %{prompt_per_mtok: "0", completion_per_mtok: "0.42"}}
]

for {{label, prices}, i} <- Enum.with_index(allow_cases) do
  result =
    boot.(
      Map.merge(base, %{
        port: port + 300 + i,
        pricing_mode: :rate_card_first,
        prices: prices,
        payments_source: "payments"
      })
    )

  check.("credits ON + #{label} boots", result == :booted)
end

check.(
  "credits ON via an ATOM payments_source is gated identically (same credits_enabled? derivation)",
  match?(
    {:raised, _},
    boot.(
      Map.merge(base, %{
        port: port + 400,
        pricing_mode: :rate_card_first,
        prices: %{},
        payments_source: :payments
      })
    )
  )
)

# ── the gate is a public, directly-callable predicate too ────────────────────
check.(
  "validate_credits_pricing!/3 is public and returns :ok when credits are off",
  Proxy.validate_credits_pricing!(%{}, :rate_card_first, %{}) == :ok
)

check.(
  "validate_credits_pricing!/3 raises for a credits-on install with an unpriceable card",
  match?(
    {:raised, _},
    try do
      Proxy.validate_credits_pricing!(%{payments_source: "payments"}, :rate_card_first, %{})
    rescue
      e in ArgumentError -> {:raised, Exception.message(e)}
    end
  )
)

# ─────────────────────────────────────────────────────────────────────────────
failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_CREDITS_PRICING_GATE: ALL PASS")
else
  IO.puts("LLM_PROXY_CREDITS_PRICING_GATE: FAILED (#{length(failed)} check(s))")
  failed |> Enum.reverse() |> Enum.each(&IO.puts("  FAIL #{&1}"))
  System.halt(1)
end
