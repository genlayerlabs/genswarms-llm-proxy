# Changelog

## Unreleased

## 0.2.18 - 2026-07-15

- Price `/v1/compact` seals through the same cost chokepoint as chat calls.
  A new router may additively attach OpenAI-shape `usage` and the chat-shaped
  `x_router` to `/v1/compact` responses (including `{"compacted": false}`
  partial failures that followed a billable upstream call); when present, the
  seal's ledger row now carries the two-spends accounting (`cost_usd`,
  `provider_cost_usd`, `provider_cost_state`, `charge_basis`, token counts,
  cache split, provider) instead of a fixed $0 row, so seals advance the
  per-conversation daily budget and the operator-wide global ceiling.
- Legacy compatibility preserved: a router that attaches neither key keeps
  producing the same $0 `model: "compact"` row as before — never a crash,
  never an invented cost. Status semantics are unchanged (`ok` burns the
  request quota, `compact_error` stays quota-free) and the response body still
  passes through verbatim to the agent.
- Bump a dedicated `llm_proxy_compact_error` metric when the upstream seal
  call fails (distinct from `llm_proxy_compact_block`), and record any cost
  the router billed for the failed seal on the `compact_error` row.

## 0.2.17 - 2026-07-14

- Separate Today and all-time usage from cost accounting so monetary values
  have an explicit scope instead of sharing a telemetry card.
- Present legacy lifetime values as non-comparable historical evidence, while
  authoritative same-scope user charges, router cost, cost-plus margin, and
  request/token coverage live in their own reconciliation card.
- Carry router snapshot freshness into the Today cost explanation when the host
  provides `fetched_at`, and opt accounting sections into readable responsive
  columns and wrapping notes.

## 0.2.16 - 2026-07-14

- Give the four-column Costs section the full dashboard width so its labels and
  reconciliation notes do not truncate while half of the row sits unused.
- Shorten the half-width Today router label and legacy status copy to `Router
  cost` and `legacy · not comparable`, preserving the same accounting meaning
  without ellipses.

## 0.2.15 - 2026-07-14

- Keep same-scope user-charge and router-cost totals visible for diagnosis when
  request/token coverage disagrees, but mark the Costs block `UNRECONCILED`
  and withhold the numeric cost-plus margin until coverage matches.
  A mismatched population can no longer present a profit figure as meaningful.
- Present costs with explicit operator-facing labels (`Charged users` and
  `Router charged us`). Hosts may provide lifetime historical evidence while
  marking it non-authoritative; both totals remain visible, but comparability
  and margin stay withheld until the post-cutover scope reconciles.
- Compact large headline token counts (`156.8M`) so half-width metric cards do
  not overlap adjacent cache percentages. Machine payloads and detailed tables
  retain exact integer counts.

## 0.2.14 - 2026-07-14

- Fail closed at object boot when `pricing_mode: :cost_plus` has no complete,
  finite, non-negative prompt/completion fallback rate card or has a malformed
  margin. Provider zero, missing, or invalid cost can no longer silently lose
  its configured fallback because pricing configuration was omitted or bad.
- Publish explicit `user_charge_usd`, `provider_cost_usd`,
  `provider_cost_state`, and `charge_basis` fields in the returned `x_router`
  envelope while retaining `cost_usd` as the compatibility user-charge field.
  The same state/basis metadata is passed to durable store callbacks.
- Make provider-cost telemetry disjoint: missing cost bumps `unknown`; malformed
  cost bumps `invalid` plus the legacy invalid counter, but no longer also bumps
  `unknown`.
- Format dashboard detail money adaptively: cents normally and four decimals
  only for non-zero sub-cent values. Durable/API accounting precision remains
  nine/six decimals as before.
- Support an optional same-scope `llm_financials_alltime/0` host contract that
  separates authoritative charges/router cost/gross margin and reconciliation
  coverage from non-comparable historical usage.

## 0.2.13 - 2026-07-14

- Make the default provider-first policy explicit as `pricing_mode: :cost_plus`
  (`:provider_first` remains a compatibility alias). A valid direct per-call
  provider cost is charged with `margin_pct`; provider zero, missing, malformed,
  negative, non-finite, or out-of-range cost falls back to the complete rate card
  with the same margin.
- Stop deriving per-call cost from cumulative `x_router.session_acc.cost_usd`.
  That path subtracted already-marked-up user spend from raw provider cost, mixing
  units and allowing real calls to be recorded as free. Session-acc-only responses
  now use the rate-card fallback.
- Add `llm_proxy_provider_cost_unknown` and
  `llm_proxy_provider_cost_invalid` telemetry. The legacy
  `llm_proxy_cost_invalid` metric also fires for invalid provider data.
- Proxy-router Today and All-time headline spend tiles now render currency to
  cents. Per-user, per-model, and per-day tables retain six-decimal precision
  so small charges remain visible.

## 0.2.12 - 2026-07-10

- Proxy-router page polish (operator feedback): the Today and All-time
  summary blocks declare `span: "half"` (frontend 0.3.6 grammar) so they sit
  side by side; the period selector renders in the dashboard's standard
  range-selector style (frontend 0.3.6).

## 0.2.11 - 2026-07-10

- Proxy-router page: the Users table becomes a period selector (Today / 7
  days / 30 days / All-time) when the host store exposes the new probed
  contract `store_mod.llm_usage_by_budget_since/2` (days | :all, limit) —
  per-budget aggregates over the window, rendered through the dashboard
  frontend's new `tabs` section type (frontend 0.3.5+). Today keeps the
  live-day limit/status columns (the quota view); period tabs drop them
  (a multi-day window has no daily limit) and sort client-side like every
  extension table. Absent contract or raising store falls back to the
  classic flat Users table — old frontends render the fallback flat table
  only when the host lacks the contract; hosts adopting the contract must
  run frontend >= 0.3.5.

## 0.2.10 - 2026-07-10

- Rate card requires BOTH per-Mtok prices (micromarkets#450 review):
  `prices_set?` moves from `or` to `and`. Under `pricing_mode
  :rate_card_first` a half-configured card (one price env silently dropped
  by a host's parser) counted as configured, billing the missing leg at $0
  while ignoring the real router cost — a systematic undercharge, ≈$0 on
  completion-heavy calls. A half card now falls through to the
  router-reported cost, which never underbills. `provider_first` semantics
  unchanged (the card was already only a $0-basis fallback there). Hosts
  should also reject half/malformed cards at boot (wingston#132 does).

## 0.2.9 - 2026-07-10

- Proxy-router page: new "All-time" metrics block (user spend, router cost,
  requests, tokens, cache rate) via the probed host contracts
  `store_mod.llm_usage_alltime/0` (%{since, days, budgets, requests,
  prompt_tokens, total_tokens, cached_tokens, spent_usd} | nil) and the
  optional `store_mod.llm_router_cost_alltime/0` (%{cost_usd, estimated_any}
  | nil). Same fail-open discipline as the History/By-model sections: absent
  contract, nil, or raising store contributes nothing. The Today block stays
  day-scoped on purpose — it is the budget-enforcement view and quotas reset
  at 00:00 UTC; All-time is its durable twin.
- History table window widened: last 14 -> last 30 days.

## 0.2.8 - 2026-07-09

- TWO spends, deliberately distinct. New `pricing_mode:` config —
  `:rate_card_first` bills the USER at the operator-set price (`prices:`)
  regardless of the router's own cost (a free subscription-served call still
  charges the set price); default `:provider_first` keeps the legacy cost-plus
  behavior byte-identical. The router's own per-call number is now recorded
  verbatim as `provider_cost_usd` alongside the charge in every budget record.
- Proxy-router page: "Spend" tile renamed "User spend"; new "Router cost" tile
  via the probed host contract `store_mod.llm_router_cost_today/0`
  (`%{cost_usd, estimated}` — the host syncs its router's usage-API day
  estimate). History table: "user spent" label + an optional "router" column
  when day rows carry `:router_cost_usd` (em-dash for days without an
  estimate, never a fake $0).
- Users table rows carry `"_cid"` metadata (live session's conversation id,
  else the persisted budget origin's) — underscore-prefixed row keys are the
  page grammar's metadata channel: never rendered as a column, usable by the
  dashboard to open its conversation inspector.

## 0.2.7 - 2026-07-09

- `register_static_session/2` + `static_sessions:` object config: sessions under
  a CALLER-SUPPLIED token, for boot-config agents whose definition is data
  evaluated before the proxy exists (they cannot mint a token at lease time the
  way pooled spawns do). The host generates the token and hands it to both the
  proxy config and the agent's `config[:api_key]`. Tokens under 24 bytes are
  rejected; malformed `static_sessions` entries are logged and skipped, never a
  boot crash.
- Proxy-router page gains a durable "History · last N days" table via a new
  probed store contract, `store_mod.llm_usage_days/1` (day aggregates across all
  budgets: `%{day, budgets, requests, prompt_tokens, total_tokens,
  cached_tokens, spent_usd}`, newest first). Same fail-open discipline as the
  By-model section: absent function or raising store contributes nothing.

## 0.2.6 - 2026-07-07

- Added `"llm_proxy_budget"` machine block (v1) to `dashboard_extension/1`: numeric
  `ceiling_usd`/`spent_usd`/`default_daily_limit_usd` twins of the existing
  string-formatted `"llm_proxy"`/`"proxy_router"` fields, plus two shipped
  `health_rules` (`budget_guard_75` info, `budget_guard_90` warn) for the observer's
  generic rule evaluator. Additive only — no existing key changed or removed. A
  dead proxy with only a durable store publishes `ceiling_usd: 0.0` (no live quota
  to read); the shipped rules' own `where` guard (`ceiling_usd > 0`) keeps them
  inert in that case instead of false-alarming.
