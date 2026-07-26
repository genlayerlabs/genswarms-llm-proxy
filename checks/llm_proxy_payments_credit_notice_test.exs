# Payment-received user notice (0.4.0). Standalone — NO Postgres, NO network.
#
#   mix run checks/llm_proxy_payments_credit_notice_test.exs
#
# Today, applying a prepaid credit is silent: nothing reaches the user until
# they run /quota. This proves the notice that closes that gap, mirroring the
# block notice's own delivery seam (deliver_fn -> :sender via `slot_reply`):
#
#   1. a GENUINELY NEW credit (push) sends exactly one notice, to the SAME
#      conversation that owns the credited budget, carrying the credited
#      amount AND the balance AFTER the credit;
#   2. a re-delivered push of the SAME (method, ref) sends NO second notice
#      (apply_credit_entry/3's own idempotency is what "genuinely new" rides
#      on — this proves the notice inherits it);
#   3. a re-polled settlement (poll_payments, same page twice) also sends NO
#      second notice — the one-notice-per-payment guarantee holds across
#      BOTH trusted entry points;
#   4. a notice-delivery failure (deliver_fn raises) does not affect the
#      credit: the ledger entry and mirror balance stand, a durable counter
#      is bumped, and the handler does not crash;
#   5. an untrusted sender never reaches the credit path at all, so it can
#      never trigger a notice;
#   6. the `credit_notice_enabled: false` toggle suppresses the notice while
#      the credit still lands;
#   7. no bound session for the credited identity degrades to no notice
#      (best-effort — there is nothing to route to), and the credit is
#      unaffected.

ExUnit.start(autorun: false)

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

defmodule CreditNoticeStore do
  def reset(_opts \\ []) do
    :persistent_term.put(
      {__MODULE__, :state},
      %{entries: [], metrics: []}
    )
  end

  def state, do: :persistent_term.get({__MODULE__, :state})
  defp update(fun), do: :persistent_term.put({__MODULE__, :state}, fun.(state()))

  def llm_credit_balance(budget_identity) do
    balance =
      state().entries
      |> Enum.filter(&(&1.budget_identity == budget_identity))
      |> Enum.reduce(Decimal.new("0"), &Decimal.add(&1.amount_usd, &2))

    {:ok, balance}
  end

  def record_llm_credit_entry(%{idempotency_key: key} = entry) do
    if Enum.any?(state().entries, &(&1.idempotency_key == key)) do
      {:error, :duplicate}
    else
      update(fn s -> %{s | entries: s.entries ++ [entry]} end)
      :ok
    end
  end

  def bump_metric(event, meta, value) do
    update(fn s -> %{s | metrics: s.metrics ++ [{event, meta, value}]} end)
    :ok
  end
end

# ── Shared delivery capture: tag by `to`, same convention as
# checks/llm_proxy_notice_dedup_test.exs ──────────────────────────────────────

{:ok, captured} = Agent.start_link(fn -> [] end)

build_deliver_fn = fn ->
  fn _swarm, to, _from, content ->
    decoded = Jason.decode!(content)
    Agent.update(captured, &[{to, decoded} | &1])
    :ok
  end
end

slot_replies = fn ->
  Agent.get(captured, fn msgs ->
    msgs
    |> Enum.filter(fn {to, msg} -> to == :sender and msg["action"] == "slot_reply" end)
    |> Enum.map(fn {_to, msg} -> msg end)
    |> Enum.reverse()
  end)
end

reset_captured = fn -> Agent.update(captured, fn _ -> [] end) end

# ── Base state + a real bound session so the notice has somewhere to go ──────

{:ok, state_pid} = Proxy.start_state_link()

conversation_id = "tg:9:0"
kind = "dm"
workspace_key = "default"

beneficiary =
  Proxy.budget_identity(%{
    conversation_id: conversation_id,
    kind: kind,
    workspace_key: workspace_key
  })

{:ok, _token} =
  Proxy.register_session(state_pid, %{
    conversation_id: conversation_id,
    slot: "slot-1",
    kind: kind,
    workspace_key: workspace_key
  })

CreditNoticeStore.reset()

base_state = %{
  state_pid: state_pid,
  quota: %{store_mod: CreditNoticeStore},
  store_mod: CreditNoticeStore,
  payments_source: "payments",
  credit_namespace: "llm_quota",
  credit_per_usd: Decimal.new("1.0"),
  credits_enabled: true,
  settlements_fn: nil,
  payments_consumer: "llm_proxy",
  poll_lag: 100,
  poll_limit: 100,
  poll_sources: ["cron"],
  swarm_name: "wingston",
  sender: :sender,
  deliver_fn: build_deliver_fn.(),
  credit_notice_enabled: true
}

push_msg = fn ref, amount ->
  Jason.encode!(%{
    action: "payment_confirmed",
    beneficiary: beneficiary,
    amount_usd: amount,
    method: "usdc_base",
    ref: ref,
    namespace: "llm_quota"
  })
end

# ────────────────────────────────────────────────────────────────────────────
# 1. A genuinely new credit sends exactly one notice, to the right
#    conversation, with the credited amount AND the post-credit balance.
# ────────────────────────────────────────────────────────────────────────────
reset_captured.()

{:reply, first_json, _} = Proxy.handle_message("payments", push_msg.("0xA:0", "1.00"), base_state)

check.(
  "first payment credits ok",
  Jason.decode!(first_json) == %{"ok" => true, "credited_usd" => "1.00", "balance_usd" => "1.00"}
)

first_replies = slot_replies.()

check.(
  "exactly one notice sent, on the right slot",
  length(first_replies) == 1 and hd(first_replies)["slot"] == "slot-1"
)

check.(
  "notice text carries the credited amount and the post-credit balance",
  hd(first_replies)["content"] == "💳 Payment received — $1.00 credited. Prepaid balance: $1.00."
)

# A second, DIFFERENT payment: balance compounds, and the message matches the
# spec's own worked example verbatim.
reset_captured.()
{:reply, second_json, _} = Proxy.handle_message("payments", push_msg.("0xB:0", "1.00"), base_state)

check.(
  "second (distinct) payment compounds the balance",
  Jason.decode!(second_json)["balance_usd"] == "2.00"
)

check.(
  "notice text matches the spec worked example exactly",
  hd(slot_replies.())["content"] ==
    "💳 Payment received — $1.00 credited. Prepaid balance: $2.00."
)

# ────────────────────────────────────────────────────────────────────────────
# 2. Re-delivered push of the SAME (method, ref) -> NO second notice.
# ────────────────────────────────────────────────────────────────────────────
reset_captured.()
{:reply, redelivered_json, _} = Proxy.handle_message("payments", push_msg.("0xA:0", "1.00"), base_state)

check.(
  "re-delivered push is answered as a duplicate",
  Jason.decode!(redelivered_json) == %{"ok" => true, "duplicate" => true}
)

check.(
  "re-delivered push sends NO second notice",
  slot_replies.() == []
)

# ────────────────────────────────────────────────────────────────────────────
# 3. Re-polled settlement (poll_payments, same page twice) -> NO second notice.
# ────────────────────────────────────────────────────────────────────────────
CreditNoticeStore.reset()
reset_captured.()

poll_conversation_id = "tg:22:0"

poll_beneficiary =
  Proxy.budget_identity(%{
    conversation_id: poll_conversation_id,
    kind: kind,
    workspace_key: workspace_key
  })

{:ok, _poll_token} =
  Proxy.register_session(state_pid, %{
    conversation_id: poll_conversation_id,
    slot: "slot-poll",
    kind: kind,
    workspace_key: workspace_key
  })

poll_row = %{
  beneficiary: poll_beneficiary,
  amount_usd: Decimal.new("3.00"),
  method: "usdc_base",
  ref: "0xPOLL:0",
  idempotency_key: "usdc_base:0xPOLL:0",
  namespace: "llm_quota",
  at: ~U[2026-07-25 10:00:00Z],
  outbox_seq: 1,
  meta: %{}
}

poll_state = %{
  base_state
  | settlements_fn: fn 0, 200 ->
      {:ok, %{settlements: [poll_row], max_seq: 1, next_seq: 1, complete: true}}
    end
}

{:reply, poll_first_json, _} =
  Proxy.handle_message("cron", Jason.encode!(%{action: "poll_payments"}), poll_state)

check.(
  "poll applies the settlement once",
  Jason.decode!(poll_first_json)["applied"] == 1
)

poll_first_replies = slot_replies.()

check.(
  "poll of a genuinely new settlement sends exactly one notice to its own conversation",
  length(poll_first_replies) == 1 and hd(poll_first_replies)["slot"] == "slot-poll" and
    hd(poll_first_replies)["content"] ==
      "💳 Payment received — $3.00 credited. Prepaid balance: $3.00."
)

reset_captured.()

{:reply, poll_second_json, _} =
  Proxy.handle_message("cron", Jason.encode!(%{action: "poll_payments"}), poll_state)

check.(
  "re-polling the SAME page resolves as a duplicate, not a new credit",
  Jason.decode!(poll_second_json)["applied"] == 0 and
    Jason.decode!(poll_second_json)["duplicates"] == 1
)

check.(
  "re-polled settlement sends NO second notice",
  slot_replies.() == []
)

# ────────────────────────────────────────────────────────────────────────────
# 4. Notice-delivery failure does not touch the credit: the ledger stands, a
#    durable counter is bumped, and the handler does not crash.
# ────────────────────────────────────────────────────────────────────────────
CreditNoticeStore.reset()
reset_captured.()

fail_conversation_id = "tg:99:0"

fail_beneficiary =
  Proxy.budget_identity(%{
    conversation_id: fail_conversation_id,
    kind: kind,
    workspace_key: workspace_key
  })

{:ok, _fail_token} =
  Proxy.register_session(state_pid, %{
    conversation_id: fail_conversation_id,
    slot: "slot-fail",
    kind: kind,
    workspace_key: workspace_key
  })

fail_push_msg =
  Jason.encode!(%{
    action: "payment_confirmed",
    beneficiary: fail_beneficiary,
    amount_usd: "1.00",
    method: "usdc_base",
    ref: "0xFAIL:0",
    namespace: "llm_quota"
  })

raising_state = %{base_state | deliver_fn: fn _s, _to, _from, _msg -> raise "sender is down" end}

{:reply, failed_notice_json, _} = Proxy.handle_message("payments", fail_push_msg, raising_state)

check.(
  "credit still applies even though notice delivery raises",
  Jason.decode!(failed_notice_json) ==
    %{"ok" => true, "credited_usd" => "1.00", "balance_usd" => "1.00"}
)

check.(
  "no notice observed on the capture channel (delivery raised before returning)",
  slot_replies.() == []
)

check.(
  "a lost credit notice bumps a durable counter",
  Enum.any?(CreditNoticeStore.state().metrics, fn
    {"llm_payments_credit_notice_failed", %{budget_identity: ^fail_beneficiary}, 1} -> true
    _ -> false
  end)
)

# ────────────────────────────────────────────────────────────────────────────
# 5. Untrusted sender never reaches the credit path -> no notice (and no
#    credit either — this is the existing trust gate, unchanged).
# ────────────────────────────────────────────────────────────────────────────
CreditNoticeStore.reset()
reset_captured.()

{:noreply, _state} =
  Proxy.handle_message("some-untrusted-object", push_msg.("0xUNTRUSTED:0", "1.00"), base_state)

check.(
  "untrusted sender is refused before any credit is applied",
  CreditNoticeStore.state().entries == []
)

check.(
  "untrusted sender never triggers a notice",
  slot_replies.() == []
)

# ────────────────────────────────────────────────────────────────────────────
# 6. credit_notice_enabled: false suppresses the notice; the credit still
#    lands.
# ────────────────────────────────────────────────────────────────────────────
CreditNoticeStore.reset()
reset_captured.()

toggle_off_state = %{base_state | credit_notice_enabled: false}

{:reply, toggle_off_json, _} =
  Proxy.handle_message("payments", push_msg.("0xTOGGLE:0", "1.00"), toggle_off_state)

check.(
  "credit_notice_enabled: false still credits normally",
  Jason.decode!(toggle_off_json)["ok"] == true
)

check.(
  "credit_notice_enabled: false sends no notice",
  slot_replies.() == []
)

# ────────────────────────────────────────────────────────────────────────────
# 7. No bound session for the credited identity -> best-effort no-op (no
#    crash, no notice); the credit is unaffected.
# ────────────────────────────────────────────────────────────────────────────
CreditNoticeStore.reset()
reset_captured.()

unbound_beneficiary =
  Proxy.budget_identity(%{conversation_id: "tg:no-session:0", kind: kind, workspace_key: workspace_key})

unbound_msg =
  Jason.encode!(%{
    action: "payment_confirmed",
    beneficiary: unbound_beneficiary,
    amount_usd: "1.00",
    method: "usdc_base",
    ref: "0xNOSESSION:0",
    namespace: "llm_quota"
  })

{:reply, unbound_json, _} = Proxy.handle_message("payments", unbound_msg, base_state)

check.(
  "a credit with no bound session still applies",
  Jason.decode!(unbound_json)["ok"] == true
)

check.(
  "a credit with no bound session sends no notice (nothing to route to)",
  slot_replies.() == []
)

# ────────────────────────────────────────────────────────────────────────────
# 8. No live session, but the host DOES keep a durable origin for the credited
#    identity: the notice routes there with `send` (there is no slot to reply
#    into). This is the normal case for a top-up — the credit lands minutes
#    after the command, often after a restart, and a command opens no session.
#    The store above deliberately does NOT export llm_budget_origin/1, which
#    is why scenario 7 stays silent; this one does.
# ────────────────────────────────────────────────────────────────────────────
defmodule OriginStore do
  # Same credit ledger as CreditNoticeStore, plus the origin read-back.
  defdelegate reset(), to: CreditNoticeStore
  defdelegate llm_credit_balance(budget_identity), to: CreditNoticeStore
  defdelegate record_llm_credit_entry(entry), to: CreditNoticeStore
  defdelegate bump_metric(event, meta, value), to: CreditNoticeStore

  def route_to(cid), do: :persistent_term.put({__MODULE__, :route}, cid)

  def llm_budget_origin(_budget_identity) do
    case :persistent_term.get({__MODULE__, :route}, :none) do
      :none -> {:ok, nil}
      :error -> {:error, :store_unavailable}
      cid -> {:ok, %{conversation_id: cid, kind: "dm", workspace_key: "default"}}
    end
  end
end

sends = fn ->
  Agent.get(captured, fn msgs ->
    msgs
    |> Enum.filter(fn {to, msg} -> to == :sender and msg["action"] == "send" end)
    |> Enum.map(fn {_to, msg} -> msg end)
    |> Enum.reverse()
  end)
end

origin_state = %{base_state | quota: %{store_mod: OriginStore}, store_mod: OriginStore}

origin_cid = "tg:origin-only:0"

origin_beneficiary =
  Proxy.budget_identity(%{
    conversation_id: origin_cid,
    kind: kind,
    workspace_key: workspace_key
  })

origin_msg = fn ref ->
  Jason.encode!(%{
    action: "payment_confirmed",
    beneficiary: origin_beneficiary,
    amount_usd: "2.50",
    method: "usdc_authorization",
    ref: ref,
    namespace: "llm_quota"
  })
end

CreditNoticeStore.reset()
reset_captured.()
OriginStore.route_to(origin_cid)

{:reply, origin_json, _} = Proxy.handle_message("payments", origin_msg.("0xORIGIN:0"), origin_state)

check.(
  "a credit with no session but a durable origin still applies",
  Jason.decode!(origin_json)["ok"] == true
)

origin_sends = sends.()
# `|| %{}` so a regression that sends nothing REPORTS the remaining checks
# instead of aborting the file on hd([]) and hiding scenarios 9 and 10.
first_origin_send = List.first(origin_sends) || %{}

check.(
  "…and sends exactly one notice, addressed to the recorded conversation",
  length(origin_sends) == 1 and first_origin_send["conversation_id"] == origin_cid
)

check.(
  "…carrying the credited amount and the post-credit balance",
  String.contains?(first_origin_send["content"] || "", "$2.50 credited") and
    String.contains?(first_origin_send["content"] || "", "Prepaid balance: $2.50")
)

check.(
  "…and never as a slot_reply (there is no slot to reply into)",
  slot_replies.() == []
)

# The one-notice-per-payment guarantee must hold on this route too.
reset_captured.()

{:reply, origin_dup_json, _} =
  Proxy.handle_message("payments", origin_msg.("0xORIGIN:0"), origin_state)

check.(
  "a re-delivered payment on the origin route is a duplicate",
  Jason.decode!(origin_dup_json)["ok"] == true and sends.() == []
)

# ────────────────────────────────────────────────────────────────────────────
# 9. A live session WINS over the durable origin: the notice stays in the
#    thread the user is actually in, and is never sent twice.
# ────────────────────────────────────────────────────────────────────────────
CreditNoticeStore.reset()
reset_captured.()
OriginStore.route_to("tg:should-not-be-used:0")

{:reply, _both_json, _} = Proxy.handle_message("payments", push_msg.("0xBOTH:0", "1.00"), origin_state)

check.(
  "with a live session the notice is a slot_reply on that session's slot",
  length(slot_replies.()) == 1 and hd(slot_replies.())["slot"] == "slot-1"
)

check.(
  "…and the durable origin route is NOT also used (no double notice)",
  sends.() == []
)

# ────────────────────────────────────────────────────────────────────────────
# 10. The origin read-back is best effort, exactly like every other seam here:
#     an unavailable store degrades to silence, never to a crash, and the
#     credit stands.
# ────────────────────────────────────────────────────────────────────────────
CreditNoticeStore.reset()
reset_captured.()
OriginStore.route_to(:error)

{:reply, broken_json, _} =
  Proxy.handle_message("payments", origin_msg.("0xORIGINFAIL:0"), origin_state)

check.(
  "an unavailable origin lookup still credits",
  Jason.decode!(broken_json)["ok"] == true
)

check.(
  "…and sends no notice rather than crashing",
  sends.() == [] and slot_replies.() == []
)

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_PAYMENTS_CREDIT_NOTICE: ALL PASS")
else
  IO.puts("LLM_PROXY_PAYMENTS_CREDIT_NOTICE: FAILED")
  Enum.each(Enum.reverse(failed), &IO.puts("  Failed: #{&1}"))
  System.halt(1)
end
