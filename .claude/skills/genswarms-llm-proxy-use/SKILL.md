---
name: genswarms-llm-proxy-use
description: >-
  Wire the genswarms-llm-proxy object into a swarm: loopback OpenAI-compatible
  endpoint + opaque per-conversation tokens, daily budgets (per-conversation,
  per-kind, global ceiling), request quotas, cost/token/cache accounting, and
  the durable store seam. Use when adding LLM cost governance to a swarm, or
  debugging "agent calls blocked by budget", "spend not persisted across
  restarts", or "global ceiling triggered". Importer's guide — for internals
  read the README and checks/.
---

# genswarms-llm-proxy — using the package

Metering/budget proxy between sandboxed agents and your LLM upstream (an
unhardcoded router or any OpenAI-compatible endpoint). Agents get ONLY
`http://127.0.0.1:<port>/v1/chat/completions` + an opaque bearer token; the
proxy maps token → host identity and forwards with host-held credentials.

## Wiring

Declare the object (see README for the full config block):

- `upstream_endpoint` + `upstream_api_key` — required; enables the proxy.
- `default_daily_limit` — per-conversation USD/day. **Warns and blocks all
  calls if ≤ 0** — that is the fail-closed default, not a bug: set a real limit.
- `global_daily_limit` — the Sybil/cost-DoS backstop across ALL conversations
  (0 = disabled). Enforced as max(durable, in-memory) — holds through a store
  outage.
- `daily_request_limit` — per-identity op quota, blocks before upstream.
- `prices` — per-model %{prompt:, completion:} USD per Mtok, for
  compute-from-usage costing when the upstream doesn't report cost.
- `allow_streaming` / `prompt_cache` / `margin_pct` / timeouts — see README.

Sessions bind via the object protocol (the conversation runtime sends the bind
message with `conversation_id`, `kind`, `workspace_key`); the reply carries the
token the agent will use. `{"action":"quota_status",...}` is the read-only
inspection op.

### Prepaid credit ledger (optional)

Once a budget identity's free daily budget is exhausted, calls draw down a
credit balance instead of blocking — 4 config keys, all optional:

- `payments_source` — the object name trusted to send
  `{"action":"payment_confirmed"}`. `nil` (default) = feature off.
- `credit_namespace` (default `"default"`) — confirmations for a foreign
  namespace are silently ignored (shared settlement hub, per-consumer scope).
- `credit_per_usd` (default `"1.0"`) — `amount_usd` → credited balance rate.
- `topup_hint_fun` — plug opt, 1-arity fun (`budget_identity -> hint |
  nil`) appended as an extra line on a budget block notice.

The payments object (whatever settles usdc/fiat/whatever — this package is
payment-agnostic) must be allowlisted as the trusted sender in your swarm
topology, same as any other cross-object message. See README's "Prepaid
credit ledger" section for the spend order, idempotency, and fail-policy
details.

## Durable accounting

Without `store_mod` everything is in-memory: budgets reset on restart (fine in
dev). For production pass `store_mod: MyApp.LlmProxyStore` implementing any
subset of `Genswarms.LlmProxy.Store` (eight optional callbacks: record_llm_call,
record_llm_budget_origin, llm_usage_for_budget, llm_usage_today,
llm_usage_by_budget, list_llm_usage, llm_credit_balance,
record_llm_credit_entry). Missing callbacks fall back to memory — fail-open by
design. The host owns the schema/migrations.

## Dashboard

The proxy exposes usage rows for the genswarms-dashboard extension surface
(usage tiles + per-model breakdown) — your `DataSource.snapshot/1` includes
them as an extension block, same pattern wingston/micromarkets use.

## Gotchas

- **"All agent LLM calls blocked"** → `default_daily_limit ≤ 0` (the boot log
  warns exactly this) or the global ceiling tripped (log: "GLOBAL daily budget
  ceiling reached — blocking all conversations until 00:00 UTC").
- **Spend resets on restart** → no `store_mod` (memory-only is the documented
  dev mode).
- **Budget survives Postgres outage reads as lower** → per-conversation budget
  fails OPEN on store errors; only the global ceiling keeps a floor via the
  in-memory mirror. That asymmetry is deliberate (availability over precision
  per-conversation; a hard backstop globally).
- The API key rides a private tempfile curl config, never argv; the Secret
  wrapper scrubs it from inspect/crash reports. Don't "fix" logging around it.
- `kind` per-budget defaults need either `kind` in the bind/quota messages or
  a `dm_module` (exports `dm?/1`) to classify cids; absent both, everything is
  "group".
- **"User paid but still blocked"** → check `credit_namespace` /
  `payments_source` match what the payments object actually sends — a
  mismatch on either is silently ignored (namespace) or logged as untrusted
  and ignored (source); confirm via the warning log before assuming the
  balance is genuinely spent.
- **"Credit lost after restart"** → `store_mod` doesn't implement
  `llm_credit_balance/1` + `record_llm_credit_entry/1` (memory-only mode for
  credits specifically — the rest of the store can be fully wired).

## Verification

`./checks/run.sh` — 25 standalone checks (no PG, no network; injected seams:
fake store, injected upstream fun, captured deliveries). Host adapters are
proven host-side (wingston keeps PG-backed degraded/stress checks against its
real store).
