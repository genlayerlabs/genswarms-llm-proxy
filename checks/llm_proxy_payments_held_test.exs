# payment_held — the consumer side of the hub's issuance caps (C1).
#
#   mix run checks/llm_proxy_payments_held_test.exs
#
# A quarantined settlement is money that ARRIVED and was deliberately NOT
# credited. This check pins the four properties that make that safe and honest:
#
#   1. it records + meters and NEVER credits, behind the same trust gate a
#      forged payment_confirmed faces (untrusted source, credits-off, and a
#      foreign namespace are all refused);
#   2. the in-memory mirror is bounded (200, FIFO) with every eviction logged,
#      and the optional durable callback's failure is non-fatal;
#   3. the USER SEES IT: one honest sentence rides the EXISTING budget-block
#      notice — same delivery, same notice_repeat_ms dedup, no second channel;
#   4. a later credit for the same ref (the phase-4 operator release) clears
#      the hold, and quota_status exposes the identity-scoped held block.
#
# Standalone — NO Postgres, NO network.

ExUnit.start(autorun: false)

Application.ensure_all_started(:plug)

alias Genswarms.LlmProxy, as: Proxy
alias Genswarms.LlmProxy.Plug, as: ProxyPlug

import Plug.Test
import Plug.Conn, only: [put_req_header: 3]

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
# Harness: a store exporting the coherent credit pair, the optional held
# callback, and bump_metric so every refusal/record is observable.
# ────────────────────────────────────────────────────────────────────────────
defmodule HeldStore do
  def reset(opts \\ []) do
    :persistent_term.put(
      {__MODULE__, :state},
      %{
        held: [],
        metrics: [],
        entries: [],
        balances: %{},
        held_result: Keyword.get(opts, :held_result, :ok)
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
    case state().held_result do
      :ok ->
        update(&%{&1 | held: &1.held ++ [row]})
        :ok

      other ->
        other
    end
  end

  def bump_metric(event, meta, value) do
    update(&%{&1 | metrics: &1.metrics ++ [{event, meta, value}]})
    :ok
  end

  def metrics(event), do: Enum.filter(state().metrics, fn {e, _, _} -> e == event end)
end

held_msg = fn overrides ->
  Jason.encode!(
    Map.merge(
      %{
        # Verified against the shipped hub emit site (genswarms-payments
        # finish_recorded_settlement/6, "quarantined" arm, 2026-07-25): action,
        # beneficiary, amount_usd, ref, reason — NO method, NO namespace, NO at.
        "action" => "payment_held",
        "beneficiary" => "llmb_alice",
        "amount_usd" => "5.00",
        "ref" => "0xdeadbeef:0",
        "reason" => "max_payment"
      },
      overrides
    )
  )
end

build_state = fn state_pid, overrides ->
  Map.merge(
    %{
      state_pid: state_pid,
      endpoint: "http://127.0.0.1:4318/v1/chat/completions",
      provider: "unit",
      quota: %{
        store_mod: HeldStore,
        default_daily_limit: Decimal.new("0.50"),
        daily_request_limit: 0,
        global_daily_limit: Decimal.new("0"),
        clock: fn -> ~U[2026-07-25 12:00:00Z] end
      },
      store_mod: HeldStore,
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
    },
    overrides
  )
end

# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 1: trusted payment_held records + meters, NEVER credits]")
# ────────────────────────────────────────────────────────────────────────────

HeldStore.reset()
{:ok, p1} = Proxy.start_state_link()
s1 = build_state.(p1, %{})

{:reply, r1, ^s1} = Proxy.handle_message("payments", held_msg.(%{}), s1)

mirror1 = Agent.get(p1, &Map.get(&1, :held_payments, []))

check.(
  "trusted payment_held acks and records exactly one mirror entry",
  Jason.decode!(r1) == %{"ok" => true, "held" => true, "duplicate" => false} and
    length(mirror1) == 1
)

[row1] = mirror1

check.(
  "the mirror entry carries identity, ref, amount, reason and a timestamp",
  row1.budget_identity == "llmb_alice" and row1.ref == "0xdeadbeef:0" and
    Decimal.equal?(row1.amount_usd, Decimal.new("5.00")) and row1.reason == "max_payment" and
    match?(%DateTime{}, row1.at)
)

check.(
  "the shipped hub payload has no \"method\" -> the key falls back to the bare ref",
  row1.method == nil and row1.idempotency_key == "0xdeadbeef:0"
)

check.(
  "NOTHING was credited: no ledger entry, balance still 0",
  HeldStore.state().entries == [] and
    Decimal.equal?(Proxy.credit_balance(p1, HeldStore, "llmb_alice"), Decimal.new("0"))
)

check.(
  "llm_payments_held metered once with the method:ref-ish key and the reason",
  HeldStore.metrics("llm_payments_held") == [
    {"llm_payments_held", %{idempotency_key: "0xdeadbeef:0", reason: "max_payment"}, 1}
  ]
)

check.(
  "the optional durable callback recorded the same row",
  match?([%{ref: "0xdeadbeef:0", reason: "max_payment"}], HeldStore.state().held)
)

# re-delivery (the hub cast is one-shot, but a restart/manual redeliver must not double-record)
{:reply, r1b, _} = Proxy.handle_message("payments", held_msg.(%{}), s1)

check.(
  "a re-delivered payment_held is a deduped no-op (one mirror row, one metric)",
  Jason.decode!(r1b)["duplicate"] == true and
    length(Agent.get(p1, &Map.get(&1, :held_payments, []))) == 1 and
    length(HeldStore.metrics("llm_payments_held")) == 1 and
    length(HeldStore.state().held) == 1
)

# a hub that DOES send method keys on the full "<method>:<ref>" join
{:reply, _, _} =
  Proxy.handle_message(
    "payments",
    held_msg.(%{"method" => "8453", "ref" => "0xfeed:1", "beneficiary" => "llmb_bob"}),
    s1
  )

check.(
  "a payload WITH \"method\" keys the hold on \"<method>:<ref>\" (credit-path shape)",
  Enum.any?(
    Agent.get(p1, &Map.get(&1, :held_payments, [])),
    &(&1.idempotency_key == "8453:0xfeed:1" and &1.method == "8453")
  )
)

# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 2: refusals — untrusted source, credits off, namespace, payload]")
# ────────────────────────────────────────────────────────────────────────────

HeldStore.reset()
{:ok, p2} = Proxy.start_state_link()
s2 = build_state.(p2, %{})

{:noreply, _} = Proxy.handle_message("attacker", held_msg.(%{}), s2)

check.(
  "payment_held from an UNTRUSTED source is refused exactly like a forged " <>
    "payment_confirmed (no mirror, no durable row, no metric)",
  Agent.get(p2, &Map.get(&1, :held_payments, [])) == [] and
    HeldStore.state().held == [] and HeldStore.state().metrics == []
)

s2_off = build_state.(p2, %{credits_enabled: false})
{:noreply, _} = Proxy.handle_message("payments", held_msg.(%{}), s2_off)

check.(
  "credits OFF refuses payment_held even from the named source (feature gate)",
  Agent.get(p2, &Map.get(&1, :held_payments, [])) == [] and HeldStore.state().metrics == []
)

s2_nosource = build_state.(p2, %{payments_source: ""})
{:noreply, _} = Proxy.handle_message("payments", held_msg.(%{}), s2_nosource)

check.(
  "an empty payments_source refuses payment_held",
  Agent.get(p2, &Map.get(&1, :held_payments, [])) == []
)

# a PRESENT-but-foreign namespace: silent (no reply), but metered
{:noreply, _} =
  Proxy.handle_message("payments", held_msg.(%{"namespace" => "someone_else"}), s2)

check.(
  "a foreign namespace is a SILENT but METERED refusal (no mirror row)",
  Agent.get(p2, &Map.get(&1, :held_payments, [])) == [] and
    HeldStore.metrics("llm_payments_held_refused") == [
      {"llm_payments_held_refused",
       %{reason: "namespace_mismatch", idempotency_key: "0xdeadbeef:0"}, 1}
    ]
)

# the MATCHING namespace is accepted (forward compatibility with a hub that grows the field)
{:reply, _, _} = Proxy.handle_message("payments", held_msg.(%{"namespace" => "llm_quota"}), s2)

check.(
  "a matching namespace is accepted; an ABSENT one is accepted too (shipped hub shape)",
  length(Agent.get(p2, &Map.get(&1, :held_payments, []))) == 1
)

HeldStore.reset()
{:ok, p2b} = Proxy.start_state_link()
s2b = build_state.(p2b, %{})

bad_payloads = [
  {"missing beneficiary", %{"beneficiary" => nil}},
  {"empty ref", %{"ref" => ""}},
  {"JSON-number amount (wire contract is a STRING)", %{"amount_usd" => 5.0}},
  {"exponent amount", %{"amount_usd" => "5e2"}},
  {"zero amount", %{"amount_usd" => "0.00"}},
  {"negative amount", %{"amount_usd" => "-5.00"}},
  {"non-finite amount", %{"amount_usd" => "Infinity"}}
]

for {label, overrides} <- bad_payloads do
  {:reply, reply, _} = Proxy.handle_message("payments", held_msg.(overrides), s2b)

  check.(
    "malformed payment_held (#{label}) is refused, metered, and records nothing",
    Jason.decode!(reply) == %{"ok" => false, "error" => "bad_payment_held"} and
      Agent.get(p2b, &Map.get(&1, :held_payments, [])) == []
  )
end

check.(
  "every malformed payload bumped llm_payments_held_refused with reason bad_payment_held",
  length(HeldStore.metrics("llm_payments_held_refused")) == length(bad_payloads) and
    Enum.all?(HeldStore.metrics("llm_payments_held_refused"), fn {_e, meta, _v} ->
      meta.reason == "bad_payment_held"
    end)
)

# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 3: bounded mirror, logged eviction, non-fatal durable failure]")
# ────────────────────────────────────────────────────────────────────────────

HeldStore.reset()
{:ok, p3} = Proxy.start_state_link()
s3 = build_state.(p3, %{})

eviction_log =
  ExUnit.CaptureLog.capture_log(fn ->
    for n <- 1..205 do
      {:reply, _, _} =
        Proxy.handle_message(
          "payments",
          held_msg.(%{"ref" => "hold-#{n}", "beneficiary" => "llmb_flood"}),
          s3
        )
    end
  end)

mirror3 = Agent.get(p3, &Map.get(&1, :held_payments, []))

check.(
  "the in-memory held mirror is FIFO-bounded to 200 entries (oldest dropped)",
  length(mirror3) == 200 and hd(mirror3).ref == "hold-6" and List.last(mirror3).ref == "hold-205"
)

check.(
  "every eviction is LOGGED (a silently truncated hold queue hides a user's money)",
  String.contains?(eviction_log, "evicting oldest in-memory HELD payment mirror entry") and
    String.contains?(eviction_log, "hold-1")
)

# durable callback failure: logged + metered, never fatal, mirror still holds the notice
HeldStore.reset(held_result: {:error, :db_down})
{:ok, p3b} = Proxy.start_state_link()
s3b = build_state.(p3b, %{})

fail_log =
  ExUnit.CaptureLog.capture_log(fn ->
    {:reply, reply, _} = Proxy.handle_message("payments", held_msg.(%{}), s3b)
    send(self(), {:reply, reply})
  end)

receive do
  {:reply, reply} ->
    check.(
      "a FAILING record_llm_held_payment is non-fatal: the handler still acks",
      Jason.decode!(reply)["held"] == true
    )
end

check.(
  "the durable failure is logged and metered (llm_payments_held_store_failed), " <>
    "and the user-visible mirror row survives",
  String.contains?(fail_log, "durable held-payment record failed") and
    length(HeldStore.metrics("llm_payments_held_store_failed")) == 1 and
    length(Agent.get(p3b, &Map.get(&1, :held_payments, []))) == 1
)

# a store WITHOUT the optional callback must be a plain no-op
defmodule NoHeldCallbackStore do
  def llm_credit_balance(_bi), do: {:ok, Decimal.new("0")}
  def record_llm_credit_entry(_entry), do: :ok
end

{:ok, p3c} = Proxy.start_state_link()
s3c = build_state.(p3c, %{store_mod: NoHeldCallbackStore, quota: %{store_mod: NoHeldCallbackStore}})

{:reply, reply3c, _} = Proxy.handle_message("payments", held_msg.(%{}), s3c)

check.(
  "a store that does NOT export record_llm_held_payment still records the mirror notice",
  Jason.decode!(reply3c)["held"] == true and
    length(Agent.get(p3c, &Map.get(&1, :held_payments, []))) == 1
)

# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 4: the hold is cleared by a later credit for the same ref]")
# ────────────────────────────────────────────────────────────────────────────

HeldStore.reset()
{:ok, p4} = Proxy.start_state_link()
s4 = build_state.(p4, %{})

{:reply, _, _} = Proxy.handle_message("payments", held_msg.(%{}), s4)

check.(
  "precondition: the hold is visible for the identity",
  length(Proxy.held_payments(p4, "llmb_alice")) == 1
)

# The phase-4 operator release re-emits payment_confirmed for the SAME ref.
release =
  Jason.encode!(%{
    "action" => "payment_confirmed",
    "beneficiary" => "llmb_alice",
    "amount_usd" => "5.00",
    "method" => "8453",
    "ref" => "0xdeadbeef:0",
    "namespace" => "llm_quota"
  })

{:reply, release_reply, _} = Proxy.handle_message("payments", release, s4)

check.(
  "the release CREDITS (this is the only path that ever credits held money)",
  Jason.decode!(release_reply) == %{
    "ok" => true,
    "credited_usd" => "5.00",
    "balance_usd" => "5.00"
  }
)

check.(
  "and it CLEARS the hold — matched on the ref, since the hub's hold carried no method",
  Proxy.held_payments(p4, "llmb_alice") == [] and
    length(HeldStore.metrics("llm_payments_held_cleared")) == 1
)

check.(
  "an unrelated identity's hold is untouched by another's release",
  Proxy.held_payments(p4, "llmb_bob") == []
)

# a hold for a DIFFERENT ref survives a release
{:reply, _, _} =
  Proxy.handle_message("payments", held_msg.(%{"ref" => "0xother:9"}), s4)

{:reply, _, _} =
  Proxy.handle_message(
    "payments",
    Jason.encode!(%{
      "action" => "payment_confirmed",
      "beneficiary" => "llmb_alice",
      "amount_usd" => "1.00",
      "method" => "8453",
      "ref" => "0xunrelated:3",
      "namespace" => "llm_quota"
    }),
    s4
  )

check.(
  "a credit for a DIFFERENT ref leaves the hold standing",
  match?([%{ref: "0xother:9"}], Proxy.held_payments(p4, "llmb_alice"))
)

# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 5: quota_status held block — shape, scope, and absence]")
# ────────────────────────────────────────────────────────────────────────────

HeldStore.reset()
{:ok, p5} = Proxy.start_state_link()
s5 = build_state.(p5, %{})

qs_attrs = %{conversation_id: "tg:5:0", kind: "dm", workspace_key: "default"}
qs_identity = Proxy.budget_identity(qs_attrs)

for n <- 1..12 do
  {:reply, _, _} =
    Proxy.handle_message(
      "payments",
      held_msg.(%{
        "beneficiary" => qs_identity,
        "ref" => "qs-#{n}",
        "amount_usd" => "#{n}.00",
        "reason" => "aggregate",
        "at" => "2026-07-25T10:0#{rem(n, 10)}:00Z"
      }),
      s5
    )
end

# one hold belonging to somebody else — must never appear in this reply
{:reply, _, _} =
  Proxy.handle_message("payments", held_msg.(%{"beneficiary" => "llmb_stranger"}), s5)

qs_msg =
  Jason.encode!(%{
    action: "quota_status",
    conversation_id: "tg:5:0",
    kind: "dm",
    workspace_key: "default",
    day: "2026-07-25"
  })

{:reply, qs_json, _} = Proxy.handle_message("operator", qs_msg, s5)
qs = Jason.decode!(qs_json)
block = qs["payments_poll"]

check.(
  "held_count counts ALL of the identity's holds; held is bounded to 10, newest first",
  block["held_count"] == 12 and length(block["held"]) == 10 and
    hd(block["held"])["ref"] == "qs-12" and List.last(block["held"])["ref"] == "qs-3"
)

check.(
  "each held entry is {ref, amount_usd, reason, at} — 2dp money string, ISO8601 stamp",
  hd(block["held"]) == %{
    "ref" => "qs-12",
    "amount_usd" => "12.00",
    "reason" => "aggregate",
    "at" => "2026-07-25T10:02:00Z"
  }
)

check.(
  "the held list is IDENTITY-SCOPED — another beneficiary's hold never leaks in",
  not Enum.any?(block["held"], &(&1["ref"] == "0xdeadbeef:0"))
)

{:reply, no_cid_json, _} =
  Proxy.handle_message("operator", Jason.encode!(%{action: "quota_status"}), s5)

check.(
  "a quota_status with no conversation_id has no identity -> empty held block",
  Jason.decode!(no_cid_json)["payments_poll"]["held"] == [] and
    Jason.decode!(no_cid_json)["payments_poll"]["held_count"] == 0
)

# PRIME INVARIANT: no poll config at all -> no payments_poll block, hence no held keys.
s5_legacy = Map.drop(s5, [:settlements_fn, :payments_consumer, :poll_lag, :poll_limit, :poll_sources])
{:reply, legacy_json, _} = Proxy.handle_message("operator", qs_msg, s5_legacy)

check.(
  "PRIME INVARIANT: settlements_fn nil -> the whole payments_poll block (held included) " <>
    "is ABSENT from quota_status",
  not Map.has_key?(Jason.decode!(legacy_json), "payments_poll")
)

# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 6: the user-visible held sentence on the budget-block notice]")
# ────────────────────────────────────────────────────────────────────────────

defmodule HeldNoticeStore do
  @name __MODULE__

  def start_link do
    case Agent.start_link(fn -> %{} end, name: @name) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      err -> err
    end
  end

  def seed(identity, day) do
    Agent.update(@name, fn state ->
      Map.put(state, {identity, day}, %{
        budget_identity: identity,
        day: day,
        session_id: "seed",
        spent_usd: Decimal.new("0.30"),
        limit_usd: Decimal.new("0.01"),
        requests: 1,
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0
      })
    end)
  end

  def llm_budget_status(identity, day, session_id, _default_limit) do
    Agent.get(@name, fn state ->
      case Map.get(state, {identity, day}) do
        nil -> nil
        row -> %{row | session_id: session_id}
      end
    end)
  end

  def record_llm_call(_identity, _day, _session_id, _attrs), do: %{}

  # Coherent credit pair with a ZERO balance: credits are ON (so the held line
  # is eligible) but the identity has nothing to spend, so the block still fires.
  def llm_credit_balance(_bi), do: {:ok, Decimal.new("0")}
  def record_llm_credit_entry(_entry), do: :ok
end

{:ok, _} = HeldNoticeStore.start_link()

{:ok, clock_state} = Agent.start_link(fn -> ~U[2026-07-01 08:00:00Z] end)
set_clock = fn %DateTime{} = dt -> Agent.update(clock_state, fn _ -> dt end) end
clock = fn -> Agent.get(clock_state, & &1) end

{:ok, captured} = Agent.start_link(fn -> [] end)

deliver_fn = fn _swarm, to, _from, content ->
  Agent.update(captured, &[{to, Jason.decode!(content)} | &1])
  :ok
end

notices = fn ->
  Agent.get(captured, fn msgs ->
    msgs
    |> Enum.filter(fn {to, msg} -> to == :sender and msg["action"] == "slot_reply" end)
    |> Enum.map(fn {_to, msg} -> msg["content"] end)
    |> Enum.reverse()
  end)
end

reset_captured = fn -> Agent.update(captured, fn _ -> [] end) end

{:ok, np} = Proxy.start_state_link()

notice_opts = %{
  state_pid: np,
  upstream_endpoint: "https://llm.example/v1/chat/completions",
  upstream_api_key: "test-key",
  provider: "unit",
  prices: %{},
  store_mod: HeldNoticeStore,
  clock: clock,
  swarm_name: "testswarm",
  sender: :sender,
  deliver_fn: deliver_fn,
  metrics: :metrics_held,
  credits_enabled: true
}

post = fn token, opts ->
  conn(:post, "/v1/chat/completions", Jason.encode!(%{"model" => "m", "messages" => []}))
  |> put_req_header("authorization", "Bearer #{token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(opts))
end

today = ~D[2026-07-01]
n_attrs = %{conversation_id: "tg:held:0", slot: :held_agent, kind: :dm, workspace_key: "default"}
n_identity = Proxy.budget_identity(n_attrs)
{:ok, n_token} = Proxy.register_session(np, n_attrs)
HeldNoticeStore.seed(n_identity, today)

base_line = "⏳ This chat reached its daily LLM limit. Try again tomorrow at 00:00 UTC (2026-07-02)."
held_line = "Payment received but held for review: $5.00 — not credited yet. An operator has to release it."

# no hold yet -> the notice is byte-identical to 0.3.0
set_clock.(~U[2026-07-01 08:00:00Z])
reset_captured.()
post.(n_token, notice_opts)

check.(
  "PRIME INVARIANT: with no hold the block notice is byte-identical (no held sentence)",
  notices.() == [base_line]
)

# now the hub quarantines this identity's payment
n_state = build_state.(np, %{})
{:reply, _, _} = Proxy.handle_message("payments", held_msg.(%{"beneficiary" => n_identity}), n_state)

set_clock.(~U[2026-07-01 12:00:00Z])
reset_captured.()
post.(n_token, notice_opts)

sent = notices.()

check.(
  "the block notice now carries the held sentence on its own line, after the base text",
  sent == [base_line <> "\n" <> held_line]
)

check.(
  "the held sentence appears EXACTLY ONCE in the notice",
  length(String.split(hd(sent), held_line)) - 1 == 1
)

# dedup: a second blocked request inside notice_repeat_ms delivers NOTHING new
reset_captured.()
set_clock.(~U[2026-07-01 12:05:00Z])
post.(n_token, notice_opts)

check.(
  "the held sentence rides the EXISTING dedup: a repeat block inside " <>
    "notice_repeat_ms sends no second notice (no separate hold channel)",
  notices.() == []
)

# ...and after the repeat interval the same (still unresolved) hold is repeated
reset_captured.()
set_clock.(~U[2026-07-01 16:05:00Z])
post.(n_token, notice_opts)

check.(
  "after notice_repeat_ms the notice repeats, still carrying the unresolved hold",
  notices.() == [base_line <> "\n" <> held_line]
)

# two holds for one identity collapse into ONE sentence with the summed amount
{:reply, _, _} =
  Proxy.handle_message(
    "payments",
    held_msg.(%{"beneficiary" => n_identity, "ref" => "0xsecond:1", "amount_usd" => "2.50"}),
    n_state
  )

reset_captured.()
set_clock.(~U[2026-07-01 20:10:00Z])
post.(n_token, notice_opts)

check.(
  "N holds collapse into ONE sentence carrying the summed amount",
  notices.() == [
    base_line <>
      "\n" <>
      "Payment received but held for review: $7.50 — not credited yet. An operator has to release it."
  ]
)

# the topup hint stays LAST — it is still the right action for a NEW payment
check.(
  "ordering: base, then the held sentence, then the top-up hint",
  ProxyPlug.budget_notice(
    %{day: today},
    nil,
    Map.put(notice_opts, :topup_hint_fun, fn _bi -> "Top up: send USDC to 0xABC" end),
    %{budget_identity: n_identity}
  ) ==
    base_line <>
      "\n" <>
      "Payment received but held for review: $7.50 — not credited yet. An operator has to release it." <>
      "\n" <> "Top up: send USDC to 0xABC"
)

check.(
  "credits OFF renders NO held sentence even with holds mirrored (feature gate, " <>
    "byte-identical to 0.3.0)",
  ProxyPlug.budget_notice(
    %{day: today},
    nil,
    Map.put(notice_opts, :credits_enabled, false),
    %{budget_identity: n_identity}
  ) == base_line
)

check.(
  "the held sentence is scoped to the identity — another conversation's notice is clean",
  ProxyPlug.budget_notice(%{day: today}, nil, notice_opts, %{budget_identity: "llmb_nobody"}) ==
    base_line
)

# clearing the holds removes the sentence
{:reply, _, _} =
  Proxy.handle_message(
    "payments",
    Jason.encode!(%{
      "action" => "payment_confirmed",
      "beneficiary" => n_identity,
      "amount_usd" => "5.00",
      "method" => "8453",
      "ref" => "0xdeadbeef:0",
      "namespace" => "llm_quota"
    }),
    n_state
  )

{:reply, _, _} =
  Proxy.handle_message(
    "payments",
    Jason.encode!(%{
      "action" => "payment_confirmed",
      "beneficiary" => n_identity,
      "amount_usd" => "2.50",
      "method" => "8453",
      "ref" => "0xsecond:1",
      "namespace" => "llm_quota"
    }),
    n_state
  )

check.(
  "once every hold is released+credited the sentence disappears (back to the base text)",
  Proxy.held_notice_line(np, n_identity) == nil and
    ProxyPlug.budget_notice(%{day: today}, nil, notice_opts, %{budget_identity: n_identity}) ==
      base_line
)

# ─────────────────────────────────────────────────────────────────────────────
failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_PAYMENTS_HELD: ALL PASS")
else
  IO.puts("LLM_PROXY_PAYMENTS_HELD: FAILED (#{length(failed)} check(s))")
  failed |> Enum.reverse() |> Enum.each(&IO.puts("  FAIL #{&1}"))
  System.halt(1)
end
