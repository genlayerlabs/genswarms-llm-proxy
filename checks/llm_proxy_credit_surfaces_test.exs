# Credit surfaces (Task 4 of the USDC-topups plan): quota_status gains a
# `credit: %{balance_usd: "N.NN"}` block, and budget-block notices append an
# optional top-up hint. Standalone — NO Postgres, NO network.
#
#   mix run checks/llm_proxy_credit_surfaces_test.exs

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
# Section 1: quota_status credit block
# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 1: quota_status credit: %{balance_usd: ...}]")

{:ok, state_pid} = Proxy.start_state_link()

funded_cid = "tg:cs-funded:0"
funded_identity = Proxy.budget_identity(%{conversation_id: funded_cid, kind: "dm", workspace_key: "default"})

# Pre-credit via the mirror (store_mod: nil -> :no_store branch, mirror still applies).
{:ok, _bal} =
  Proxy.apply_credit_entry(state_pid, nil, %{
    idempotency_key: "surfaces:1",
    budget_identity: funded_identity,
    amount_usd: Decimal.new("4.00"),
    kind: "credit",
    at: DateTime.utc_now(),
    meta: %{}
  })

# (X5b) credits_enabled now gates the credit block below — this fixture opts in
# explicitly (the key was previously dead/unread here) so the "4.00"/"0.00"
# assertions in this section keep asserting the credit-path-ON behavior they
# always meant to.
quota_status_state = %{
  state_pid: state_pid,
  credits_enabled: true,
  quota: %{
    store_mod: nil,
    default_daily_limit: Decimal.new("0.50"),
    daily_request_limit: 30,
    global_daily_limit: Decimal.new("0.30"),
    clock: fn -> ~U[2026-07-01 10:00:00Z] end
  }
}

{:reply, funded_json, ^quota_status_state} =
  Proxy.handle_message(
    :commands,
    Jason.encode!(%{
      action: "quota_status",
      conversation_id: funded_cid,
      kind: "dm",
      workspace_key: "default"
    }),
    quota_status_state
  )

funded_body = Jason.decode!(funded_json)

check.(
  "quota_status reports the pre-credited balance as \"4.00\"",
  funded_body["ok"] == true and funded_body["credit"]["balance_usd"] == "4.00"
)

empty_cid = "tg:cs-empty:0"

{:reply, empty_json, ^quota_status_state} =
  Proxy.handle_message(
    :commands,
    Jason.encode!(%{
      action: "quota_status",
      conversation_id: empty_cid,
      kind: "dm",
      workspace_key: "default"
    }),
    quota_status_state
  )

empty_body = Jason.decode!(empty_json)

check.(
  "quota_status for an identity with no credits reports \"0.00\"",
  empty_body["ok"] == true and empty_body["credit"]["balance_usd"] == "0.00"
)

{:reply, fallback_json, ^quota_status_state} =
  Proxy.handle_message(
    :commands,
    Jason.encode!(%{action: "quota_status"}),
    quota_status_state
  )

fallback_body = Jason.decode!(fallback_json)

check.(
  "quota_status fallback (missing conversation_id) also carries a credit block",
  fallback_body["ok"] == false and fallback_body["credit"]["balance_usd"] == "0.00"
)

# ────────────────────────────────────────────────────────────────────────────
# Section 1b (X5b): credits_enabled gates quota_status's credit read entirely.
# A feature-off install must show "0.00" WITHOUT ever calling the store's
# llm_credit_balance/1 — probe P5 showed a feature-off install displaying a
# durable balance the block gate itself ignores (credit_exhausted?/2 already
# forces `true` off gate; quota_status must agree, not just cosmetically).
# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 1b: credits_enabled gates the quota_status credit read]")

defmodule CountingCreditStore do
  def reset, do: :persistent_term.put({__MODULE__, :calls}, 0)
  def calls, do: :persistent_term.get({__MODULE__, :calls}, 0)

  def llm_credit_balance(_bi) do
    :persistent_term.put({__MODULE__, :calls}, calls() + 1)
    {:ok, Decimal.new("9.99")}
  end

  def record_llm_credit_entry(_entry), do: :ok
end

CountingCreditStore.reset()
gated_cid = "tg:cs-gated:0"

state_credits_off = %{
  state_pid: state_pid,
  credits_enabled: false,
  quota: %{
    store_mod: CountingCreditStore,
    default_daily_limit: Decimal.new("0.50"),
    daily_request_limit: 30,
    global_daily_limit: Decimal.new("0.30"),
    clock: fn -> ~U[2026-07-01 10:00:00Z] end
  }
}

{:reply, gated_json, _} =
  Proxy.handle_message(
    :commands,
    Jason.encode!(%{
      action: "quota_status",
      conversation_id: gated_cid,
      kind: "dm",
      workspace_key: "default"
    }),
    state_credits_off
  )

gated_body = Jason.decode!(gated_json)

check.(
  "credits_enabled false -> quota_status credit block shows \"0.00\" even though the " <>
    "store holds a real (9.99) balance",
  gated_body["ok"] == true and gated_body["credit"]["balance_usd"] == "0.00"
)

check.(
  "credits_enabled false -> the store's llm_credit_balance/1 is NEVER called (no read at all)",
  CountingCreditStore.calls() == 0
)

state_credits_on = %{state_credits_off | credits_enabled: true}

{:reply, on_json, _} =
  Proxy.handle_message(
    :commands,
    Jason.encode!(%{
      action: "quota_status",
      conversation_id: gated_cid,
      kind: "dm",
      workspace_key: "default"
    }),
    state_credits_on
  )

on_body = Jason.decode!(on_json)

check.(
  "credits_enabled true -> the SAME identity/store now reads the real durable " <>
    "balance (9.99), proving the gate flips both ways",
  on_body["ok"] == true and on_body["credit"]["balance_usd"] == "9.99" and
    CountingCreditStore.calls() == 1
)

# ────────────────────────────────────────────────────────────────────────────
# Section 2: budget_notice/4 with topup_hint_fun
# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 2: budget_notice/4 topup_hint_fun]")

request_ctx = %{day: ~D[2026-07-01]}
session = %{budget_identity: "bid-xyz"}

base_text = "⏳ This chat reached its daily LLM limit. Try again tomorrow at 00:00 UTC (2026-07-02)."

# (R3-M2) The hint is gated on the same strict credits_enabled derivation as
# every other credit surface — the ON cases below opt in explicitly, and a
# dedicated OFF case pins that a configured fun renders NO hint while credits
# are off (a blocked user must not be pointed at a payment path this object
# would silently drop).
on = fn extra -> Map.put(extra, :credits_enabled, true) end

check.(
  "topup_hint_fun absent from opts -> byte-identical to the 0.2.19 base text",
  ProxyPlug.budget_notice(request_ctx, nil, on.(%{}), session) == base_text
)

check.(
  "topup_hint_fun: nil -> byte-identical to the 0.2.19 base text",
  ProxyPlug.budget_notice(request_ctx, nil, on.(%{topup_hint_fun: nil}), session) == base_text
)

hint_fun = fn bi -> "Top up: send USDC to 0xABC (" <> bi <> ")" end

check.(
  "credits on + topup_hint_fun returning a string -> notice ends with the hint on its own line, base unchanged before it",
  ProxyPlug.budget_notice(request_ctx, nil, on.(%{topup_hint_fun: hint_fun}), session) ==
    base_text <> "\n" <> "Top up: send USDC to 0xABC (bid-xyz)"
)

check.(
  "(R3-M2) credits OFF + topup_hint_fun configured -> NO hint, byte-identical base text " <>
    "(the hint would point at a payment path that drops every payment_confirmed)",
  ProxyPlug.budget_notice(
    request_ctx,
    nil,
    %{credits_enabled: false, topup_hint_fun: hint_fun},
    session
  ) == base_text
)

{:ok, hint_calls} = Agent.start_link(fn -> 0 end)
counting_hint_fun = fn bi ->
  Agent.update(hint_calls, &(&1 + 1))
  hint_fun.(bi)
end

check.(
  "(R3-M2) opts missing :credits_enabled entirely (feature-off install) -> NO hint, " <>
    "and the fun is never even called",
  ProxyPlug.budget_notice(request_ctx, nil, %{topup_hint_fun: counting_hint_fun}, session) ==
    base_text and Agent.get(hint_calls, & &1) == 0
)

check.(
  "topup_hint_fun returning nil -> byte-identical to the 0.2.19 base text",
  ProxyPlug.budget_notice(request_ctx, nil, on.(%{topup_hint_fun: fn _bi -> nil end}), session) == base_text
)

check.(
  "topup_hint_fun returning an empty string -> byte-identical to the 0.2.19 base text (not appended)",
  ProxyPlug.budget_notice(request_ctx, nil, on.(%{topup_hint_fun: fn _bi -> "" end}), session) == base_text
)

check.(
  "topup_hint_fun RAISES -> falls back to the base text, never crashes the block path",
  ProxyPlug.budget_notice(request_ctx, nil, on.(%{topup_hint_fun: fn _bi -> raise "boom" end}), session) ==
    base_text
)

check.(
  "topup_hint_fun returning a non-binary -> byte-identical to the 0.2.19 base text (defensive)",
  ProxyPlug.budget_notice(request_ctx, nil, on.(%{topup_hint_fun: fn _bi -> 123 end}), session) == base_text
)

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_CREDIT_SURFACES: ALL PASS")
else
  IO.puts("LLM_PROXY_CREDIT_SURFACES: FAILED")
  for f <- Enum.reverse(failed), do: IO.puts("  FAIL #{f}")
  System.halt(1)
end
