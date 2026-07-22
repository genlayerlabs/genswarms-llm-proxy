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

quota_status_state = %{
  state_pid: state_pid,
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
# Section 2: budget_notice/4 with topup_hint_fun
# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 2: budget_notice/4 topup_hint_fun]")

request_ctx = %{day: ~D[2026-07-01]}
session = %{budget_identity: "bid-xyz"}

base_text = "⏳ This chat reached its daily LLM limit. Try again tomorrow at 00:00 UTC (2026-07-02)."

check.(
  "topup_hint_fun absent from opts -> byte-identical to the 0.2.19 base text",
  ProxyPlug.budget_notice(request_ctx, nil, %{}, session) == base_text
)

check.(
  "topup_hint_fun: nil -> byte-identical to the 0.2.19 base text",
  ProxyPlug.budget_notice(request_ctx, nil, %{topup_hint_fun: nil}, session) == base_text
)

hint_fun = fn bi -> "Top up: send USDC to 0xABC (" <> bi <> ")" end

check.(
  "topup_hint_fun returning a string -> notice ends with the hint on its own line, base unchanged before it",
  ProxyPlug.budget_notice(request_ctx, nil, %{topup_hint_fun: hint_fun}, session) ==
    base_text <> "\n" <> "Top up: send USDC to 0xABC (bid-xyz)"
)

check.(
  "topup_hint_fun returning nil -> byte-identical to the 0.2.19 base text",
  ProxyPlug.budget_notice(request_ctx, nil, %{topup_hint_fun: fn _bi -> nil end}, session) == base_text
)

check.(
  "topup_hint_fun returning an empty string -> byte-identical to the 0.2.19 base text (not appended)",
  ProxyPlug.budget_notice(request_ctx, nil, %{topup_hint_fun: fn _bi -> "" end}, session) == base_text
)

check.(
  "topup_hint_fun RAISES -> falls back to the base text, never crashes the block path",
  ProxyPlug.budget_notice(request_ctx, nil, %{topup_hint_fun: fn _bi -> raise "boom" end}, session) ==
    base_text
)

check.(
  "topup_hint_fun returning a non-binary -> byte-identical to the 0.2.19 base text (defensive)",
  ProxyPlug.budget_notice(request_ctx, nil, %{topup_hint_fun: fn _bi -> 123 end}, session) == base_text
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
