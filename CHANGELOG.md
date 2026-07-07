# Changelog

## 0.2.6 - 2026-07-07

- Added `"llm_proxy_budget"` machine block (v1) to `dashboard_extension/1`: numeric
  `ceiling_usd`/`spent_usd`/`default_daily_limit_usd` twins of the existing
  string-formatted `"llm_proxy"`/`"proxy_router"` fields, plus two shipped
  `health_rules` (`budget_guard_75` info, `budget_guard_90` warn) for the observer's
  generic rule evaluator. Additive only — no existing key changed or removed. A
  dead proxy with only a durable store publishes `ceiling_usd: 0.0` (no live quota
  to read); the shipped rules' own `where` guard (`ceiling_usd > 0`) keeps them
  inert in that case instead of false-alarming.
