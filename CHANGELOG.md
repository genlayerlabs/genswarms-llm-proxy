# Changelog

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
