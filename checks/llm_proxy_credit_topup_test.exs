# payment_confirmed entry point (Task 2): trusted source + namespace gate,
# idempotent top-up via the Task 1 credit-ledger primitives.
# Standalone — NO Postgres, NO network.   mix run checks/llm_proxy_credit_topup_test.exs
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

{:ok, pid} = Proxy.start_state_link()
bi = "w:default|k:dm|c:tg:9:0"

msg = fn over ->
  Jason.encode!(
    Map.merge(
      %{
        "action" => "payment_confirmed",
        "beneficiary" => bi,
        "amount_usd" => "5.00",
        "method" => "usdc_base",
        "ref" => "0xT:0",
        "namespace" => "llm_quota",
        "at" => "2026-07-22T12:00:00Z"
      },
      over
    )
  )
end

# Object state under test: mirror the shape handle_message/3 actually receives
# (see init/1 around the Bandit/state_pid assembly, and quota_status/2's
# tolerant `Map.get(state, :store_mod)` fallback) plus the three new credit
# config keys.
state = %{
  state_pid: pid,
  bandit: nil,
  port: 4318,
  endpoint: "http://127.0.0.1:4318/v1/chat/completions",
  provider: "openai-compatible",
  quota: %{store_mod: nil},
  store_mod: nil,
  payments_source: "payments",
  credit_namespace: "llm_quota",
  credit_per_usd: Decimal.new("1.0")
}

# 1. trusted source + right namespace credits
{:reply, json, _} = Proxy.handle_message("payments", msg.(%{}), state)
reply = Jason.decode!(json)
check.("credited ok", reply["ok"] == true and reply["credited_usd"] == "5.00")

check.(
  "balance visible",
  Decimal.equal?(Proxy.credit_balance(pid, nil, bi), Decimal.new("5.00"))
)

# 2. duplicate ref → acknowledged, NOT double-credited
{:reply, json2, _} = Proxy.handle_message("payments", msg.(%{}), state)

check.(
  "duplicate acked without double credit",
  Jason.decode!(json2)["duplicate"] == true and
    Decimal.equal?(Proxy.credit_balance(pid, nil, bi), Decimal.new("5.00"))
)

# 3. untrusted source → silently ignored (noreply), no credit
check.(
  "untrusted source ignored",
  match?({:noreply, _}, Proxy.handle_message("randomobject", msg.(%{"ref" => "0xT:1"}), state)) and
    Decimal.equal?(Proxy.credit_balance(pid, nil, bi), Decimal.new("5.00"))
)

# 4. foreign namespace → ignored per spec (noreply), no credit
check.(
  "foreign namespace ignored",
  match?(
    {:noreply, _},
    Proxy.handle_message(
      "payments",
      msg.(%{"ref" => "0xT:2", "namespace" => "micromarkets"}),
      state
    )
  ) and
    Decimal.equal?(Proxy.credit_balance(pid, nil, bi), Decimal.new("5.00"))
)

# 5. feature off (payments_source nil) → ignored even from any source
state_off = %{state | payments_source: nil}

check.(
  "feature-off ignores payment_confirmed",
  match?({:noreply, _}, Proxy.handle_message("payments", msg.(%{"ref" => "0xT:3"}), state_off))
)

# 6. conversion: credit_per_usd 2.0 doubles
state2x = %{state | credit_per_usd: Decimal.new("2.0")}

{:reply, json3, _} =
  Proxy.handle_message(
    "payments",
    msg.(%{"ref" => "0xT:4", "beneficiary" => "w:x|k:dm|c:z"}),
    state2x
  )

check.("credit_per_usd conversion", Jason.decode!(json3)["credited_usd"] == "10.00")

# 7. malformed amount → error reply, nothing credited
{:reply, json4, _} =
  Proxy.handle_message("payments", msg.(%{"ref" => "0xT:5", "amount_usd" => "abc"}), state)

check.("malformed amount refused", Jason.decode!(json4)["ok"] == false)

# 8. negative amount → refused (a "credit" action must never silently debit),
# balance unchanged
{:reply, json5, _} =
  Proxy.handle_message(
    "payments",
    msg.(%{"ref" => "0xT:6", "amount_usd" => "-5.00"}),
    state
  )

check.(
  "negative amount rejected, balance unchanged",
  Jason.decode!(json5)["ok"] == false and
    Decimal.equal?(Proxy.credit_balance(pid, nil, bi), Decimal.new("5.00"))
)

# 9. zero amount → not a payment, refused
{:reply, json6, _} =
  Proxy.handle_message(
    "payments",
    msg.(%{"ref" => "0xT:7", "amount_usd" => "0"}),
    state
  )

check.("zero amount rejected", Jason.decode!(json6)["ok"] == false)

# 10. missing ref → refused (must not collapse onto a shared "method:" key)
{:reply, json7, _} =
  Proxy.handle_message("payments", msg.(%{"ref" => nil}), state)

check.("missing ref rejected", Jason.decode!(json7)["ok"] == false)

# 11. explicit-null method → refused
{:reply, json8, _} =
  Proxy.handle_message("payments", msg.(%{"ref" => "0xT:8", "method" => nil}), state)

check.("explicit-null method rejected", Jason.decode!(json8)["ok"] == false)

# 12. CRITICAL: two DISTINCT malformed no-ref confirmations must NOT collapse
# onto a shared idempotency key and swallow the second as duplicate:true —
# each is independently refused.
{:reply, json9a, _} =
  Proxy.handle_message(
    "payments",
    msg.(%{"ref" => nil, "beneficiary" => "w:a|k:dm|c:1"}),
    state
  )

{:reply, json9b, _} =
  Proxy.handle_message(
    "payments",
    msg.(%{"ref" => nil, "beneficiary" => "w:b|k:dm|c:2"}),
    state
  )

check.(
  "two distinct malformed no-ref confirmations both refused, neither swallowed as duplicate",
  Jason.decode!(json9a)["ok"] == false and Jason.decode!(json9b)["ok"] == false and
    Jason.decode!(json9a)["duplicate"] != true and Jason.decode!(json9b)["duplicate"] != true
)

# 13. CRITICAL (A1): non-finite amounts must be refused, not raise and not mint
# an infinite balance. Decimal.parse/1 happily parses "NaN"/"Infinity"/
# "-Infinity" — parse_money/1 must reject all three BEFORE the >0 guard
# (which would otherwise raise on NaN via Decimal.compare/2).
for {label, ref, bad_amount} <- [
      {"NaN", "0xT:nan", "NaN"},
      {"Infinity", "0xT:inf", "Infinity"},
      {"-Infinity", "0xT:neginf", "-Infinity"}
    ] do
  {result, json} =
    try do
      {:reply, json, _} =
        Proxy.handle_message(
          "payments",
          msg.(%{"ref" => ref, "amount_usd" => bad_amount}),
          state
        )

      {:ok, json}
    rescue
      e -> {:raised, Exception.message(e)}
    end

  check.(
    "non-finite amount #{label} does not raise",
    result == :ok
  )

  check.(
    "non-finite amount #{label} refused (ok: false), no crash",
    result == :ok and Jason.decode!(json)["ok"] == false
  )
end

check.(
  "non-finite amounts never touched the balance",
  Decimal.equal?(Proxy.credit_balance(pid, nil, bi), Decimal.new("5.00"))
)

# 14. (X4) degraded-path check THROUGH handle_message: the approved spec's
# "credit writes fail CLOSED" governs — a store whose record_llm_credit_entry/1
# errors (e.g. db_down) but whose llm_credit_balance/1 works (the store exports
# BOTH callbacks — half-pair would otherwise be treated as absent per B1's
# both-callbacks-or-neither rule) must reply ok:false, error:"store_unavailable",
# retryable:true, and must NOT apply the mirror — the prior fail-open (ok:true,
# degraded:true, mirror credited) permanently consumed the idempotency key in
# the mirror seen-set, so the hub's redelivery after store recovery was
# swallowed as a duplicate forever (a lost payment). A later redelivery of the
# SAME method:ref must succeed once the store heals.
defmodule DegradedTopupStore do
  def reset, do: :persistent_term.put({__MODULE__, :down}, true)
  def down?, do: :persistent_term.get({__MODULE__, :down}, true)
  def heal, do: :persistent_term.put({__MODULE__, :down}, false)
  def llm_credit_balance(_bi), do: {:ok, Decimal.new("0")}

  def record_llm_credit_entry(_entry) do
    if down?(), do: {:error, :db_down}, else: :ok
  end
end

DegradedTopupStore.reset()
state_degraded = %{state | store_mod: DegradedTopupStore, quota: %{store_mod: DegradedTopupStore}}
bi_degraded = "w:degraded|k:dm|c:tg:1:0"

{:reply, json_degraded, _} =
  Proxy.handle_message(
    "payments",
    msg.(%{"ref" => "0xT:degraded", "beneficiary" => bi_degraded}),
    state_degraded
  )

reply_degraded = Jason.decode!(json_degraded)

check.(
  "degraded top-up: fails CLOSED — ok:false, error store_unavailable, retryable:true",
  reply_degraded["ok"] == false and reply_degraded["error"] == "store_unavailable" and
    reply_degraded["retryable"] == true
)

check.(
  "degraded top-up: mirror NOT credited while the store is down (fail-closed, " <>
    "not fail-open)",
  Decimal.equal?(Proxy.credit_balance(pid, nil, bi_degraded), Decimal.new("0"))
)

DegradedTopupStore.heal()

{:reply, json_recovered, _} =
  Proxy.handle_message(
    "payments",
    msg.(%{"ref" => "0xT:degraded", "beneficiary" => bi_degraded}),
    state_degraded
  )

reply_recovered = Jason.decode!(json_recovered)

check.(
  "degraded top-up: redelivery of the SAME method:ref succeeds once the store " <>
    "heals — the failed write did not permanently consume the idempotency key",
  reply_recovered["ok"] == true and reply_recovered["credited_usd"] == "5.00"
)

check.(
  "degraded top-up: mirror now credited after the healed redelivery",
  Decimal.equal?(Proxy.credit_balance(pid, nil, bi_degraded), Decimal.new("5.00"))
)

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_CREDIT_TOPUP: ALL PASS")
else
  IO.puts("LLM_PROXY_CREDIT_TOPUP: FAILED")
  IO.puts("  Failed: #{Enum.join(Enum.reverse(failed), ", ")}")
  System.halt(1)
end
