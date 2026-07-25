# The stuck queue's operator surface: READ it, and RETRY it.
# Standalone — no Postgres, no network.
#
# A settled row this proxy classifies {:permanent, _} is recorded as stuck and
# the poll cursor ADVANCES PAST IT. Before these two actions that money was
# unreachable by every path at once — below the cursor for the poll,
# already-settled for the hub's release, unreadable, unrendered. Pinned here:
#
#   1. AUTHORIZATION. Both actions ride a SEPARATE allowlist that defaults to
#      empty, gated exactly like poll_payments: exact source match, explicit
#      refusal, never a silent drop. A source that may drive the poll does NOT
#      thereby get the operator verbs.
#   2. RETRY GOES THROUGH THE VALIDATING PATH. It re-applies the stored row via
#      the same apply_payment/3 the push and the poll use. There is no
#      credit-minting shortcut here.
#   3. IT IS IDEMPOTENT IN BOTH DIRECTIONS. A row stuck by a since-fixed cause
#      credits exactly ONCE (the ledger key dedupes the second attempt); a row
#      that is genuinely invalid fails again, with its reason, and STAYS in the
#      queue rather than being silently dropped or silently re-stuck.
#   4. THE CLEAR IS DURABLE. A retried row leaves the durable queue, or the
#      reply says it did not.
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

defmodule StuckOpStore do
  def reset do
    :persistent_term.put(
      {__MODULE__, :state},
      %{stuck: [], cleared: [], entries: [], metrics: [], clear_ok: true}
    )
  end

  def state, do: :persistent_term.get({__MODULE__, :state})
  defp update(fun), do: :persistent_term.put({__MODULE__, :state}, fun.(state()))

  def put_stuck(rows), do: update(&%{&1 | stuck: rows})
  def break_clear, do: update(&%{&1 | clear_ok: false})

  # ── credit ledger (globally key-unique, the double-credit guard) ───────────
  def record_llm_credit_entry(entry) do
    if Enum.any?(state().entries, &(&1.idempotency_key == entry.idempotency_key)) do
      {:error, :duplicate}
    else
      update(&%{&1 | entries: &1.entries ++ [entry]})
      :ok
    end
  end

  def llm_credit_balance(budget_identity) do
    {:ok,
     state().entries
     |> Enum.filter(&(&1.budget_identity == budget_identity))
     |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1.amount_usd))}
  end

  # ── the stuck queue ───────────────────────────────────────────────────────
  def record_llm_stuck_payment(row) do
    update(&%{&1 | stuck: &1.stuck ++ [row]})
    :ok
  end

  def list_llm_stuck_payments(nil), do: {:ok, unresolved()}

  def list_llm_stuck_payments(key) when is_binary(key),
    do: {:ok, Enum.filter(unresolved(), &(&1.idempotency_key == key))}

  defp unresolved do
    Enum.reject(state().stuck, &(&1.idempotency_key in state().cleared))
  end

  def clear_llm_stuck_payment(key) do
    if state().clear_ok do
      hit = Enum.count(unresolved(), &(&1.idempotency_key == key))
      update(&%{&1 | cleared: &1.cleared ++ [key]})
      {:ok, hit}
    else
      {:error, :db_down}
    end
  end

  def bump_metric(event, meta, value) do
    update(&%{&1 | metrics: &1.metrics ++ [{event, meta, value}]})
    :ok
  end
end

StuckOpStore.reset()
{:ok, pid} = Proxy.start_state_link()

# Two stuck rows: one rejected for a since-fixed cause (a namespace typo that
# has been corrected in config), one genuinely unusable (no method ⇒ no key).
# STRING keys and a plain decimal STRING amount — the exact shape a JSONB
# `row` column hands back, which is what the host store persists (its
# Decimal→string normalization is why the amount is not a JSON number, a shape
# the credit path refuses by contract).
fixable = %{
  idempotency_key: "8453:0xfix:0",
  reason: "namespace_mismatch",
  at: ~U[2026-07-25 10:00:00Z],
  row: %{
    "beneficiary" => "llmb_alice",
    "amount_usd" => "5.00",
    "method" => "8453",
    "ref" => "0xfix:0",
    "namespace" => "llm_quota",
    "idempotency_key" => "8453:0xfix:0",
    "outbox_seq" => 7
  }
}

broken = %{
  idempotency_key: "8453:0xbroken:0",
  reason: "bad_payment_confirmed",
  at: ~U[2026-07-25 10:05:00Z],
  row: %{
    beneficiary: "llmb_bob",
    amount_usd: "9.00",
    method: nil,
    ref: "0xbroken:0",
    namespace: "llm_quota",
    idempotency_key: "8453:0xbroken:0",
    outbox_seq: 8
  }
}

StuckOpStore.put_stuck([fixable, broken])

state = %{
  state_pid: pid,
  endpoint: "http://127.0.0.1:4318/v1/chat/completions",
  provider: "openai-compatible",
  quota: %{
    store_mod: StuckOpStore,
    default_daily_limit: Decimal.new("0.50"),
    daily_request_limit: 0,
    global_daily_limit: Decimal.new("0"),
    clock: fn -> ~U[2026-07-25 12:00:00Z] end
  },
  store_mod: StuckOpStore,
  payments_source: "payments",
  credit_namespace: "llm_quota",
  credit_per_usd: Decimal.new("1.0"),
  credits_enabled: true,
  payments_consumer: "llm_proxy",
  poll_lag: 100,
  poll_limit: 100,
  poll_sources: ["cron"],
  operator_sources: ["commands"]
}

ask = fn state, from, msg ->
  {:reply, json, state} = Proxy.handle_message(from, Jason.encode!(msg), state)
  {Jason.decode!(json), state}
end

# ── 1. authorization ───────────────────────────────────────────────────────
{denied_read, state} = ask.(state, "agent", %{action: "stuck_payments"})

check.(
  "an unlisted source cannot even LOOK at the stuck queue, and is refused explicitly",
  denied_read["ok"] == false and denied_read["error"] == "untrusted_operator_source"
)

{denied_retry, state} =
  ask.(state, "cron", %{action: "retry_stuck", idempotency_key: "8453:0xfix:0"})

check.(
  "the source that may drive the credit POLL is NOT thereby an operator on the stuck queue",
  denied_retry["ok"] == false and denied_retry["error"] == "untrusted_operator_source" and
    denied_retry["idempotency_key"] == "8453:0xfix:0"
)

{no_allowlist, _} =
  ask.(Map.delete(state, :operator_sources), "commands", %{action: "stuck_payments"})

check.(
  "with no operator_sources configured the surface belongs to nobody (default-closed)",
  no_allowlist["ok"] == false and no_allowlist["error"] == "untrusted_operator_source"
)

{credits_off, _} =
  ask.(%{state | credits_enabled: false}, "commands", %{action: "stuck_payments"})

check.(
  "with credits off the surface is off too, byte-identically to a feature-off install",
  credits_off["ok"] == false and credits_off["error"] == "credits_disabled"
)

# ── 2. the read ────────────────────────────────────────────────────────────
{queue, state} = ask.(state, "commands", %{action: "stuck_payments"})

check.(
  "the queue reports the money an operator could not previously SEE at all",
  queue["ok"] == true and queue["count"] == 2 and queue["total_usd"] == "14.00" and
    queue["complete"] == true
)

check.(
  "each row carries what the operator needs to act: key, beneficiary, amount and the REASON",
  Enum.map(queue["rows"], & &1["idempotency_key"]) == ["8453:0xfix:0", "8453:0xbroken:0"] and
    hd(queue["rows"])["beneficiary"] == "llmb_alice" and
    hd(queue["rows"])["amount_usd"] == "5.00" and
    hd(queue["rows"])["reason"] == "namespace_mismatch"
)

{scoped, state} =
  ask.(state, "commands", %{action: "stuck_payments", idempotency_key: "8453:0xbroken:0"})

check.(
  "the read can be scoped to one key, and echoes it so an async caller correlates exactly",
  scoped["count"] == 1 and hd(scoped["rows"])["idempotency_key"] == "8453:0xbroken:0" and
    scoped["idempotency_key"] == "8453:0xbroken:0"
)

# ── 3. retry: the fixed row credits exactly ONCE ───────────────────────────
{retried, state} =
  ask.(state, "commands", %{action: "retry_stuck", idempotency_key: "8453:0xfix:0"})

check.(
  "a row stuck by a since-fixed cause credits through the ordinary validating path",
  retried["ok"] == true and retried["credited_usd"] == "5.00" and
    retried["duplicate"] == false and retried["cleared"] == true
)

check.(
  "the credit is a normal ledger entry under the row's own method:ref key",
  Enum.map(StuckOpStore.state().entries, & &1.idempotency_key) == ["8453:0xfix:0"]
)

check.(
  "the cleared row leaves the queue DURABLY (the clear is not mirror-only)",
  "8453:0xfix:0" in StuckOpStore.state().cleared
)

{queue_after, state} = ask.(state, "commands", %{action: "stuck_payments"})

check.(
  "and the queue now shows only the money that still needs an operator",
  queue_after["count"] == 1 and hd(queue_after["rows"])["idempotency_key"] == "8453:0xbroken:0"
)

{retry_again, state} =
  ask.(state, "commands", %{action: "retry_stuck", idempotency_key: "8453:0xfix:0"})

check.(
  "retrying it again is NOT a second credit — it is simply no longer stuck",
  retry_again["ok"] == false and retry_again["error"] == "not_stuck" and
    length(StuckOpStore.state().entries) == 1
)

# ── 4. an invalid row fails the SAME way, and stays visible ────────────────
{still_bad, state} =
  ask.(state, "commands", %{action: "retry_stuck", idempotency_key: "8453:0xbroken:0"})

check.(
  "a genuinely invalid row fails again with its reason, never a fabricated success",
  still_bad["ok"] == false and still_bad["error"] == "still_invalid" and
    still_bad["reason"] == "bad_payment_confirmed"
)

check.(
  "the failed retry is RECORDED durably (a metric an operator can alarm on)",
  Enum.any?(StuckOpStore.state().metrics, fn {event, meta, _v} ->
    event == "llm_payments_stuck_retry_failed" and meta.idempotency_key == "8453:0xbroken:0"
  end)
)

{queue_still, state} = ask.(state, "commands", %{action: "stuck_payments"})

check.(
  "and it STAYS in the queue — not cleared, not silently re-stuck as a second row",
  queue_still["count"] == 1 and
    hd(queue_still["rows"])["idempotency_key"] == "8453:0xbroken:0" and
    "8453:0xbroken:0" not in StuckOpStore.state().cleared
)

{unknown, state} =
  ask.(state, "commands", %{action: "retry_stuck", idempotency_key: "never-existed"})

check.(
  "an unknown key is a distinct refusal, never a no-op success",
  unknown["ok"] == false and unknown["error"] == "not_stuck"
)

{bad_request, state} = ask.(state, "commands", %{action: "retry_stuck"})

check.(
  "a retry with no key is a bad_request, never a bulk retry of everything",
  bad_request["ok"] == false and bad_request["error"] == "bad_request"
)

# ── 5. a failed CLEAR is said out loud, and never undoes the credit ────────
StuckOpStore.put_stuck([
  %{
    fixable
    | idempotency_key: "8453:0xlate:0",
      row: %{fixable.row | "idempotency_key" => "8453:0xlate:0", "ref" => "0xlate:0"}
  }
])

StuckOpStore.break_clear()

{clear_failed, state} =
  ask.(state, "commands", %{action: "retry_stuck", idempotency_key: "8453:0xlate:0"})

check.(
  "a credit that lands while the queue clear FAILS is reported honestly (cleared:false)",
  clear_failed["ok"] == true and clear_failed["cleared"] == false and
    Enum.any?(StuckOpStore.state().entries, &(&1.idempotency_key == "8453:0xlate:0"))
)

# ── 6. a store with no stuck read refuses rather than showing an empty queue ─
defmodule NoStuckStore do
  def llm_credit_balance(_id), do: {:ok, Decimal.new("0")}
  def record_llm_credit_entry(_entry), do: :ok
end

{no_store, _} =
  ask.(
    %{state | store_mod: NoStuckStore, quota: %{state.quota | store_mod: NoStuckStore}},
    "commands",
    %{action: "stuck_payments"}
  )

check.(
  "a store that cannot answer refuses — never an empty queue it cannot see",
  no_store["ok"] == false and no_store["error"] == "no_stuck_store"
)

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_STUCK_OPERATOR: ALL PASS")
else
  IO.puts("LLM_PROXY_STUCK_OPERATOR: FAILED")
  Enum.each(Enum.reverse(failed), &IO.puts("  Failed: #{&1}"))
  System.halt(1)
end
