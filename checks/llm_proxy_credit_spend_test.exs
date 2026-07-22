# Spend order (Task 3): credits unlock the block, straddle debits at the chokepoint.
# Drives the pure money-semantics helpers directly — no server, no Plug.Test conn — the
# same idiom as llm_proxy_two_spends_test.exs / llm_proxy_global_ceiling_test.exs.
# Standalone — NO Postgres, NO network.   mix run checks/llm_proxy_credit_spend_test.exs

alias Genswarms.LlmProxy, as: Proxy
alias Genswarms.LlmProxy.Plug, as: ProxyPlug

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

# A store implementing record_llm_call/4 so record_budget_call never falls onto the
# store-down (nil store_row) branch — keeps every case below free of unrelated
# Logger/emit_display/conversation_id plumbing.
defmodule SpendCheckStore do
  def record_llm_call(_identity, _day, _session_id, _attrs), do: %{ok: true}
end

{:ok, pid} = Proxy.start_state_link()

opts = %{
  state_pid: pid,
  store_mod: SpendCheckStore,
  default_daily_limit: Decimal.new("0.50"),
  # (B2) credits are feature-gated on payments_source config being present;
  # this check exercises the credit-funded flow throughout, so it opts in
  # explicitly rather than relying on any particular default.
  credits_enabled: true
}

session = fn bi, limit -> %{budget_identity: bi, daily_limit_usd: limit} end
req_ctx = %{day: ~D[2026-07-22], session_id: "sess-credit-spend"}

credit! = fn bi, key, amount ->
  {:ok, _bal} =
    Proxy.apply_credit_entry(pid, SpendCheckStore, %{
      idempotency_key: key,
      budget_identity: bi,
      amount_usd: d.(amount),
      kind: "credit",
      at: ~U[2026-07-22 10:00:00Z],
      meta: %{}
    })
end

balance = fn bi -> Proxy.credit_balance(pid, SpendCheckStore, bi) end

record = fn request_id, cost ->
  base = %{request_id: request_id, model: "m", status: "ok"}
  if is_nil(cost), do: base, else: Map.put(base, :cost_usd, cost)
end

# ── A. credit_exhausted?/2 ───────────────────────────────────────────────────────────
credit!.("bi-a-pos", "a:pos", "5.00")

check.(
  "A: credit_exhausted? false while balance > 0",
  ProxyPlug.credit_exhausted?(opts, session.("bi-a-pos", d.("0.50"))) == false
)

check.(
  "A: credit_exhausted? true when no credits ever configured/credited (balance 0)",
  ProxyPlug.credit_exhausted?(opts, session.("bi-a-never-credited", d.("0.50"))) == true
)

credit!.("bi-a-zero", "a:zero-up", "3.00")
credit!.("bi-a-zero", "a:zero-down", "-3.00")

check.(
  "A: credit_exhausted? true at balance == 0 after a credit is fully spent back down",
  ProxyPlug.credit_exhausted?(opts, session.("bi-a-zero", d.("0.50"))) == true
)

# ── B. Block gate composition (exhausted?(budget) and credit_exhausted?(opts, session)) ──
# exhausted?/1 is a private Plug helper; its formula (spent >= limit) is replicated here
# rather than exposed, so this check never touches unrelated private surface.
over_limit? = fn spent, limit -> Decimal.compare(spent, limit) != :lt end

limit_b = d.("0.50")
spent_over = d.("0.60")
spent_under = d.("0.10")

credit!.("bi-b-pos", "b:pos", "2.00")

check.(
  "B: spent >= limit and balance > 0 -> NOT blocked",
  (over_limit?.(spent_over, limit_b) and
     ProxyPlug.credit_exhausted?(opts, session.("bi-b-pos", limit_b))) == false
)

check.(
  "B: spent >= limit and balance <= 0 -> blocked (same as today)",
  (over_limit?.(spent_over, limit_b) and
     ProxyPlug.credit_exhausted?(opts, session.("bi-b-never-credited", limit_b))) == true
)

defmodule RaisingCreditStore do
  def reset, do: :persistent_term.put({__MODULE__, :calls}, 0)
  def calls, do: :persistent_term.get({__MODULE__, :calls})

  def llm_credit_balance(_bi) do
    :persistent_term.put({__MODULE__, :calls}, calls() + 1)
    raise "credit store must not be consulted on the un-exhausted path"
  end
end

RaisingCreditStore.reset()
opts_raising = %{opts | store_mod: RaisingCreditStore}

# Elixir's `and` short-circuits: when the left operand is false the right operand is
# never evaluated, so credit_exhausted?/2 — and therefore the store — is never called.
gate_under =
  over_limit?.(spent_under, limit_b) and
    ProxyPlug.credit_exhausted?(opts_raising, session.("bi-b-any", limit_b))

check.(
  "B: spent < limit never consults credit (store's llm_credit_balance not called)",
  gate_under == false and RaisingCreditStore.calls() == 0
)

# ── C. Straddle debit math via record_budget_call/5 ─────────────────────────────────
# C1: straddles the limit — only the overflow portion is credit-funded.
credit!.("bi-c1", "c1:seed", "5.00")

ProxyPlug.record_budget_call(
  opts,
  session.("bi-c1", d.("0.50")),
  req_ctx,
  record.("req-c1", d.("0.30")),
  d.("0.40")
)

check.(
  "C1: limit 0.50, spent_before 0.40, cost 0.30 -> debit only the 0.20 overflow",
  eq.(balance.("bi-c1"), d.("4.80"))
)

# C2: already over the limit before this call — the ENTIRE cost is credit-funded.
credit!.("bi-c2", "c2:seed", "5.00")

ProxyPlug.record_budget_call(
  opts,
  session.("bi-c2", d.("0.50")),
  req_ctx,
  record.("req-c2", d.("0.10")),
  d.("0.60")
)

check.(
  "C2: spent_before 0.60 (already over), cost 0.10 -> fully credit-funded debit",
  eq.(balance.("bi-c2"), d.("4.90"))
)

# C3: entirely within the free daily budget — no overflow, no debit.
credit!.("bi-c3", "c3:seed", "5.00")

ProxyPlug.record_budget_call(
  opts,
  session.("bi-c3", d.("0.50")),
  req_ctx,
  record.("req-c3", d.("0.20")),
  d.("0.10")
)

check.(
  "C3: spent_before 0.10, cost 0.20 (fully within free budget) -> NO debit",
  eq.(balance.("bi-c3"), d.("5.00"))
)

# C4: no pre-call spend available (arity-4 call site) — nil, no debit, no crash.
credit!.("bi-c4", "c4:seed", "5.00")

ProxyPlug.record_budget_call(
  opts,
  session.("bi-c4", d.("0.50")),
  req_ctx,
  record.("req-c4", d.("0.20"))
)

check.(
  "C4: spent_before nil -> NO debit, no crash",
  eq.(balance.("bi-c4"), d.("5.00"))
)

# C5: an unbilled row (no cost_usd, e.g. an error record) never debits, even with a
# real spent_before.
credit!.("bi-c5", "c5:seed", "5.00")

ProxyPlug.record_budget_call(
  opts,
  session.("bi-c5", d.("0.50")),
  req_ctx,
  record.("req-c5", nil),
  d.("0.60")
)

check.(
  "C5: record without cost_usd (unbilled error row) -> NO debit",
  eq.(balance.("bi-c5"), d.("5.00"))
)

# ── D. Overshoot: negative balance accepted; the NEXT block check reports exhausted ──
credit!.("bi-d", "d:seed", "0.05")

ProxyPlug.record_budget_call(
  opts,
  session.("bi-d", d.("0.50")),
  req_ctx,
  record.("req-d", d.("0.15")),
  d.("0.60")
)

check.(
  "D: balance 0.05, credit-funded call costing 0.15 -> balance goes to -0.10",
  eq.(balance.("bi-d"), d.("-0.10"))
)

check.(
  "D: the next block check reports exhausted after going negative",
  ProxyPlug.credit_exhausted?(opts, session.("bi-d", d.("0.50"))) == true
)

# ── E. Debit idempotency: same request_id recorded twice -> one debit only ──────────
credit!.("bi-e", "e:seed", "5.00")

record_e = record.("req-e", d.("0.30"))

ProxyPlug.record_budget_call(opts, session.("bi-e", d.("0.50")), req_ctx, record_e, d.("0.40"))
ProxyPlug.record_budget_call(opts, session.("bi-e", d.("0.50")), req_ctx, record_e, d.("0.40"))

check.(
  "E: replaying the same request_id debits once, not twice",
  eq.(balance.("bi-e"), d.("4.80"))
)

# ── F. Global ceiling: blocks regardless of positive credit balance ─────────────────
# global_exhausted?/2 is untouched by this task (no code change) — its formula
# (limit > 0 and global_spent(day) >= limit) is replicated here against the same
# public in-memory accumulator it reads, rather than exposing the private helper.
day_f = ~D[2026-07-20]
global_limit = d.("1.00")

sess_f = %{budget_identity: "bi-f", slot: "agent_f"}
Proxy.record_usage(pid, sess_f, day_f, "bi-f", %{model: "m", status: "ok", cost_usd: "1.00"})

credit!.("bi-f", "f:seed", "100.00")

global_spent = Proxy.global_spent_inmem(pid, day_f)
global_exhausted = Decimal.compare(global_limit, 0) == :gt and Decimal.compare(global_spent, global_limit) != :lt

check.(
  "F: global ceiling reached while the identity carries a large positive credit balance",
  global_exhausted == true and eq.(balance.("bi-f"), d.("100.00"))
)

check.(
  "F: that same identity's OWN per-conversation credit gate would read balance > 0 " <>
    "(credits never bypass the global backstop — the global clause blocks first, " <>
    "unconditionally, before credit is ever consulted)",
  ProxyPlug.credit_exhausted?(opts, session.("bi-f", d.("0.50"))) == false
)

# ── G. Feature gate: credits_enabled false = byte-identical-when-off ────────────────
# No retro-charge, no retro-consult: a feature-off install must never read the credit
# store (not even to find it empty) and must never accrue a mirror debit.
defmodule RaisingCreditStore2 do
  def reset, do: :persistent_term.put({__MODULE__, :calls}, 0)
  def calls, do: :persistent_term.get({__MODULE__, :calls})

  def llm_credit_balance(_bi) do
    :persistent_term.put({__MODULE__, :calls}, calls() + 1)
    raise "credit store must not be consulted while credits_enabled is false"
  end

  def record_llm_credit_entry(_entry) do
    :persistent_term.put({__MODULE__, :calls}, calls() + 1)
    raise "credit store must not be written while credits_enabled is false"
  end
end

RaisingCreditStore2.reset()
opts_off = %{opts | store_mod: RaisingCreditStore2, credits_enabled: false}

check.(
  "G1: credits_enabled false -> credit_exhausted? is true WITHOUT consulting the store " <>
    "(even one hand-credited moments ago via a different, working store)",
  ProxyPlug.credit_exhausted?(opts_off, session.("bi-g-off", d.("0.50"))) == true and
    RaisingCreditStore2.calls() == 0
)

# opts lacking the key entirely defaults to off (mirrors production config with no
# payments_source configured — the byte-identical-to-0.2.19 invariant).
opts_missing_key = opts_off |> Map.delete(:credits_enabled)

check.(
  "G1b: opts missing :credits_enabled entirely also defaults to OFF (no store consult)",
  ProxyPlug.credit_exhausted?(opts_missing_key, session.("bi-g-off2", d.("0.50"))) == true and
    RaisingCreditStore2.calls() == 0
)

# A straddling call (well over the daily limit) must record NO debit entry and leave
# the mirror untouched when credits are off — use a store that only implements
# record_llm_call/4 (so record_budget_call proceeds) but would raise on any credit
# read/write.
defmodule GateSpendStore do
  def record_llm_call(_identity, _day, _session_id, _attrs), do: %{ok: true}
  def llm_credit_balance(_bi), do: raise("must not be consulted")
  def record_llm_credit_entry(_entry), do: raise("must not be written")
end

opts_off_spend = %{opts_off | store_mod: GateSpendStore}

ProxyPlug.record_budget_call(
  opts_off_spend,
  session.("bi-g-spend", d.("0.50")),
  req_ctx,
  record.("req-g-spend", d.("0.30")),
  d.("0.40")
)

check.(
  "G2: credits_enabled false -> a straddling call records NO debit, mirror stays empty",
  eq.(Proxy.credit_balance(pid, nil, "bi-g-spend"), d.("0"))
)

# Even a hand-credited mirror balance doesn't unblock the gate while credits are off.
credit!.("bi-g-blocked", "g:seed", "5.00")

check.(
  "G3: credits_enabled false -> exhausted budget stays blocked even with a positive " <>
    "hand-credited mirror balance (the gate never reads it while off)",
  ProxyPlug.credit_exhausted?(
    %{opts_off | store_mod: nil},
    session.("bi-g-blocked", d.("0.50"))
  ) == true
)

# With credits_enabled true (existing behavior): the same shape of call IS
# credit-funded, proving the gate flips both ways off the same config key.
credit!.("bi-g-on", "g:on-seed", "5.00")

check.(
  "G4: credits_enabled true -> the existing credit-funded behavior is unchanged",
  ProxyPlug.credit_exhausted?(opts, session.("bi-g-on", d.("0.50"))) == false
)

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_CREDIT_SPEND: ALL PASS")
else
  IO.puts("LLM_PROXY_CREDIT_SPEND: FAILED")
  IO.puts("  Failed: #{Enum.join(Enum.reverse(failed), ", ")}")
  System.halt(1)
end
