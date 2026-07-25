# The hold notice must SURVIVE A RESTART.
#
#   mix run checks/llm_proxy_held_durable_test.exs
#
# (C1) A quarantined payment is money the user watched leave their wallet and
# did not get credited. Until this check's feature existed, the only record of
# that on the consumer side was a bounded in-process mirror: one routine deploy
# and the user was blocked, had already paid, was being told to pay again, and
# `quota_status` asserted to them AND to the operator that there was no hold.
#
# Pinned here, each half a way the same defect comes back pointed the other way:
#
#   1. HOLD → RESTART → the notice and the quota_status block still surface,
#      read through the durable store (an EMPTY durable answer is authoritative,
#      not a reason to fall back);
#   2. RELEASE → RESTART → the notice does NOT come back: the credit clears the
#      hold DURABLY, not only in the mirror of whichever instance credited it;
#   3. the durable clear runs even when this instance's mirror never had the
#      hold (the crediting instance is usually not the one that recorded it);
#   4. a store without the new callbacks behaves EXACTLY as before (memory-only),
#      and a store that fails falls back to the mirror rather than losing the
#      sentence.
#
# Standalone — NO Postgres, NO network.

ExUnit.start(autorun: false)
Application.ensure_all_started(:plug)

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

# ────────────────────────────────────────────────────────────────────────────
# A durable store that behaves like the host's: held rows are appended, the
# read excludes cleared rows AND rows whose key is already credited, and the
# clear is scoped to (identity, key|ref).
# ────────────────────────────────────────────────────────────────────────────
defmodule DurableHeldStore do
  def reset(opts \\ []) do
    :persistent_term.put(
      {__MODULE__, :state},
      %{
        held: [],
        entries: [],
        balances: %{},
        metrics: [],
        read_result: Keyword.get(opts, :read_result, :normal)
      }
    )
  end

  def state, do: :persistent_term.get({__MODULE__, :state})
  defp update(fun), do: :persistent_term.put({__MODULE__, :state}, fun.(state()))

  def llm_credit_balance(bi), do: {:ok, Map.get(state().balances, bi, Decimal.new("0"))}

  def record_llm_credit_entry(entry) do
    update(fn s ->
      %{
        s
        | entries: s.entries ++ [entry],
          balances:
            Map.update(
              s.balances,
              entry.budget_identity,
              entry.amount_usd,
              &Decimal.add(&1, entry.amount_usd)
            )
      }
    end)

    :ok
  end

  def record_llm_held_payment(row) do
    update(&%{&1 | held: &1.held ++ [Map.put(row, :cleared, false)]})
    :ok
  end

  def list_llm_held_payments(budget_identity) do
    case state().read_result do
      :normal ->
        credited = MapSet.new(state().entries, & &1.idempotency_key)

        {:ok,
         state().held
         |> Enum.filter(fn row ->
           row.budget_identity == budget_identity and row.cleared == false and
             not MapSet.member?(credited, row.idempotency_key)
         end)}

      other ->
        other
    end
  end

  def clear_llm_held_payment(budget_identity, key, ref) do
    {matched, kept} =
      Enum.split_with(state().held, fn row ->
        row.budget_identity == budget_identity and row.cleared == false and
          (row.idempotency_key == key or (is_binary(ref) and ref != "" and row.ref == ref))
      end)

    update(&%{&1 | held: kept ++ Enum.map(matched, fn row -> %{row | cleared: true} end)})
    {:ok, length(matched)}
  end

  def bump_metric(event, meta, value) do
    update(&%{&1 | metrics: &1.metrics ++ [{event, meta, value}]})
    :ok
  end

  def metrics(event), do: Enum.filter(state().metrics, fn {e, _, _} -> e == event end)
end

# Same store minus the two new callbacks: the 0.3.0 behaviour must be intact.
defmodule MemoryOnlyHeldStore do
  def llm_credit_balance(bi), do: DurableHeldStore.llm_credit_balance(bi)
  def record_llm_credit_entry(entry), do: DurableHeldStore.record_llm_credit_entry(entry)
  def record_llm_held_payment(row), do: DurableHeldStore.record_llm_held_payment(row)
  def bump_metric(e, m, v), do: DurableHeldStore.bump_metric(e, m, v)
end

build_state = fn state_pid, store_mod ->
  %{
    state_pid: state_pid,
    endpoint: "http://127.0.0.1:4318/v1/chat/completions",
    provider: "unit",
    quota: %{
      store_mod: store_mod,
      default_daily_limit: Decimal.new("0.50"),
      daily_request_limit: 0,
      global_daily_limit: Decimal.new("0"),
      clock: fn -> ~U[2026-07-25 12:00:00Z] end
    },
    store_mod: store_mod,
    payments_source: "payments",
    credit_namespace: "llm_quota",
    credit_per_usd: Decimal.new("1.0"),
    credits_enabled: true,
    payments_consumer: "llm_proxy",
    settlements_fn: fn _after, _limit ->
      {:ok, %{settlements: [], max_seq: 0, next_seq: 0, complete: true}}
    end,
    poll_lag: 100,
    poll_limit: 100,
    poll_sources: ["cron"]
  }
end

attrs = %{conversation_id: "tg:7:0", kind: "dm", workspace_key: "default"}
identity = Proxy.budget_identity(attrs)

held_msg =
  Jason.encode!(%{
    "action" => "payment_held",
    "beneficiary" => identity,
    "amount_usd" => "120.00",
    "method" => "usdc_base-sepolia",
    "ref" => "0xabc:0",
    "namespace" => "llm_quota",
    "at" => "2026-07-25T09:00:00Z",
    "reason" => "max_payment"
  })

# The release re-emits the SAME method/ref the hold was keyed under — that is
# what makes the credit resolve this exact hold.
confirmed_msg =
  Jason.encode!(%{
    "action" => "payment_confirmed",
    "beneficiary" => identity,
    "amount_usd" => "120.00",
    "method" => "usdc_base-sepolia",
    "ref" => "0xabc:0",
    "namespace" => "llm_quota",
    "at" => "2026-07-25T09:00:00Z"
  })

notice_line =
  "Payment received but held for review: $120.00 — not credited yet. An operator has to release it."

quota_msg =
  Jason.encode!(%{
    action: "quota_status",
    conversation_id: "tg:7:0",
    kind: "dm",
    workspace_key: "default",
    day: "2026-07-25"
  })

held_block = fn state ->
  {:reply, json, _} = Proxy.handle_message("operator", quota_msg, state)
  Jason.decode!(json)["payments_poll"]
end

# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 1: hold → restart → the notice still surfaces]")
# ────────────────────────────────────────────────────────────────────────────

DurableHeldStore.reset()
{:ok, p1} = Proxy.start_state_link()
s1 = build_state.(p1, DurableHeldStore)

{:reply, _, ^s1} = Proxy.handle_message("payments", held_msg, s1)

check.(
  "the hold is recorded durably, not only in the mirror",
  match?([%{ref: "0xabc:0"}], DurableHeldStore.state().held) and
    length(Agent.get(p1, &Map.get(&1, :held_payments, []))) == 1
)

check.(
  "before the restart the sentence is there",
  Proxy.held_notice_line(p1, DurableHeldStore, identity) == notice_line
)

# THE RESTART: a brand-new state Agent is exactly what a deploy leaves behind —
# the durable store is untouched, the mirror is empty.
{:ok, p2} = Proxy.start_state_link()
s2 = build_state.(p2, DurableHeldStore)

check.(
  "sanity: the restarted mirror really is empty",
  Agent.get(p2, &Map.get(&1, :held_payments, [])) == []
)

check.(
  "AFTER A RESTART the hold notice STILL surfaces (durable read-through)",
  Proxy.held_notice_line(p2, DurableHeldStore, identity) == notice_line
)

check.(
  "the mirror-only arity, on the same empty mirror, would have LOST it — this is the defect being fixed",
  Proxy.held_notice_line(p2, identity) == nil
)

block2 = held_block.(s2)

check.(
  "quota_status after the restart still reports the hold to user and operator",
  block2["held_count"] == 1 and hd(block2["held"])["ref"] == "0xabc:0" and
    hd(block2["held"])["amount_usd"] == "120.00"
)

check.(
  "the block notice built from the restarted process carries the sentence",
  ProxyPlug.budget_notice(
    %{day: ~D[2026-07-25]},
    nil,
    %{state_pid: p2, store_mod: DurableHeldStore, credits_enabled: true},
    %{budget_identity: identity}
  ) =~ notice_line
)

# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 2: release → restart → the notice does NOT come back]")
# ────────────────────────────────────────────────────────────────────────────

{:reply, credit_json, _} = Proxy.handle_message("payments", confirmed_msg, s2)

check.(
  "the released payment credits through the ordinary validating path",
  Jason.decode!(credit_json)["ok"] == true and
    Decimal.equal?(
      Proxy.credit_balance(p2, DurableHeldStore, identity),
      Decimal.new("120.00")
    )
)

check.(
  "the credit cleared the hold DURABLY, not only in the mirror",
  Enum.all?(DurableHeldStore.state().held, & &1.cleared) and
    Proxy.held_notice_line(p2, DurableHeldStore, identity) == nil
)

check.(
  "the clear is metered with both counts",
  match?(
    [{"llm_payments_held_cleared", %{entries: _, durable: 1}, 1}],
    DurableHeldStore.metrics("llm_payments_held_cleared")
  )
)

# Restart again: the released hold must NOT resurrect.
{:ok, p3} = Proxy.start_state_link()
s3 = build_state.(p3, DurableHeldStore)

check.(
  "AFTER THE RELEASE AND A RESTART the notice does NOT come back",
  Proxy.held_notice_line(p3, DurableHeldStore, identity) == nil
)

check.(
  "…and quota_status shows no hold either",
  held_block.(s3)["held_count"] == 0
)

# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 3: the crediting instance is usually NOT the recording one]")
# ────────────────────────────────────────────────────────────────────────────

DurableHeldStore.reset()
{:ok, p4} = Proxy.start_state_link()
s4 = build_state.(p4, DurableHeldStore)

{:reply, _, _} = Proxy.handle_message("payments", held_msg, s4)

# A different instance credits it: fresh mirror, nothing to match on there.
{:ok, p5} = Proxy.start_state_link()
s5 = build_state.(p5, DurableHeldStore)

{:reply, _, _} = Proxy.handle_message("payments", confirmed_msg, s5)

check.(
  "a credit applied by an instance whose mirror never saw the hold STILL clears it durably",
  Enum.all?(DurableHeldStore.state().held, & &1.cleared) and
    Proxy.held_notice_line(p5, DurableHeldStore, identity) == nil
)

check.(
  "and the instance that DID record it stops showing the notice too (the durable read is authoritative)",
  Proxy.held_notice_line(p4, DurableHeldStore, identity) == nil
)

# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 4: a store without the callbacks is byte-identical to before]")
# ────────────────────────────────────────────────────────────────────────────

DurableHeldStore.reset()
{:ok, p6} = Proxy.start_state_link()
s6 = build_state.(p6, MemoryOnlyHeldStore)

{:reply, _, _} = Proxy.handle_message("payments", held_msg, s6)

check.(
  "with no durable read callback the mirror still serves the notice",
  Proxy.held_notice_line(p6, MemoryOnlyHeldStore, identity) == notice_line
)

{:ok, p7} = Proxy.start_state_link()

check.(
  "…and it is memory-only: a restart loses it, exactly as before this change",
  Proxy.held_notice_line(p7, MemoryOnlyHeldStore, identity) == nil
)

{:reply, _, _} = Proxy.handle_message("payments", confirmed_msg, s6)

check.(
  "clearing without the durable callback still clears the mirror and never raises",
  Proxy.held_notice_line(p6, MemoryOnlyHeldStore, identity) == nil
)

# A durable read that FAILS must not lose the sentence: fall back to the mirror.
DurableHeldStore.reset(read_result: {:error, :db_down})
{:ok, p8} = Proxy.start_state_link()
s8 = build_state.(p8, DurableHeldStore)

{:reply, _, _} = Proxy.handle_message("payments", held_msg, s8)

check.(
  "a FAILING durable read falls back to the mirror rather than dropping the user's notice",
  Proxy.held_notice_line(p8, DurableHeldStore, identity) == notice_line
)

{:ok, p9} = Proxy.start_state_link()

check.(
  "a raising durable read is caught, never crashing the notice path",
  Proxy.held_notice_line(p9, DurableHeldStore, identity) == nil
)

failed = Agent.get(failures, & &1)

if failed != [] do
  IO.puts("\nFAILED: #{length(failed)}")
  System.halt(1)
else
  IO.puts("\nALL CHECKS PASSED")
end
