# genswarms-llm-proxy

LLM metering/budget proxy object for [genswarms](https://github.com/genlayerlabs/genswarms)
swarms. Sandboxed agents get a loopback OpenAI-compatible endpoint and an **opaque
bearer token**; the proxy maps token → trusted host identity and forwards with
host-held upstream credentials. The agent never sees the API key, the upstream,
or another conversation's identity.

Extracted from wingston-rally-bot's proxy (the superset of the two ~90%-overlapping
implementations it unifies — micro-markets carried the other).

## What it enforces

- **Per-conversation daily budget** (USD, `Decimal`) with per-kind defaults (dm/group).
- **Global daily ceiling** — the cost-DoS backstop across ALL conversations; enforced
  as `max(durable, in-memory)` so it holds even when the store is down.
- **Per-identity daily request quota** (blocks before upstream).
- **Cost tracking** per model: spend, prompt/completion tokens, cached tokens
  (router `x_router.tokens_cached` canonical, Anthropic/OpenAI shapes as fallback).
  Default `pricing_mode: :cost_plus` charges the direct per-call provider cost plus
  `margin_pct`; a zero, missing, or invalid provider cost falls back to the complete
  operator rate card plus margin. Cost-plus refuses to boot without both valid
  fallback prices and a finite non-negative margin.
- **Streaming gate** (`allow_streaming`) and **prompt-cache marking** (`prompt_cache`).
- Upstream via curl with the key in a private tempfile config — never argv.

## Block notices

Every blocked request returns a synthetic 200 completion to the agent and
(for user-facing sessions) delivers a deterministic Telegram notice via the
`sender` object. Notices are rate-limited per
`{budget_identity, cap type, UTC day}`: the first block of the day notifies,
repeats are suppressed until `notice_repeat_ms` has elapsed (default 4 hours;
`0`/`nil` = at most once per UTC day). Each cap type — per-conversation
dollar budget, request quota, global ceiling — notifies independently. The
notice state is in-memory (a proxy restart may re-notify) and pruned to the
current day.

The synthetic completion content is truthful about **this** request: it says a
notice *was sent* only when one actually went out; otherwise it says the user
was already notified earlier today. Sessions registered with `notify: false`
(background work, e.g. a memory summarizer sharing the conversation's budget
identity) never deliver a notice, never consume the notice timestamp, and get
content stating that no user notice was sent by this path.

## As a genswarms object

```elixir
%{
  name: :llm_proxy,
  handler: Genswarms.LlmProxy,
  config: %{
    upstream_endpoint: "https://router.example/v1/chat/completions",
    upstream_api_key: System.fetch_env!("LLM_PROXY_UPSTREAM_API_KEY"),
    provider: "openai-compatible",
    prices: %{prompt_per_mtok: "0.28", completion_per_mtok: "0.42"},
    margin_pct: "30",
    pricing_mode: :cost_plus,
    default_daily_limit: "0.50",
    global_daily_limit: "25.00",
    daily_request_limit: 200,
    store_mod: MyApp.LlmProxyStore,   # optional — see Durable accounting
    dm_module: MyApp.Cid,             # optional — exports dm?/1 for per-kind budgets
    metrics: :metrics,                # optional — counter-bump target object
    sender: :sender,                  # notice delivery target
    notice_repeat_ms: 14_400_000      # optional — min interval between repeated
                                      # block notices per conversation per cap type
                                      # (default 4h; 0/nil = once per UTC day)
  }
}
```

Object protocol: `{"action":"usage"}`, `{"action":"health"}`,
`{"action":"quota_status","conversation_id":"…"}`.

Module refs (`store_mod`, `dm_module`) may be atoms (Elixir defs) or strings
(JSON IR) — strings resolve via `to_existing_atom`, unknown → treated as absent.
Implements the `Genswarms.Objects.ObjectHandler` callbacks by convention (no
compile dep on the engine — genswarms is a peer/runtime dependency).

## Durable accounting (`store_mod`)

The proxy always runs an in-memory usage mirror (pruned on day rollover). For
budgets that survive restarts, pass `store_mod:` — any subset of the
`Genswarms.LlmProxy.Store` callbacks; missing ones fall back to memory
(fail-open: an accounting outage must not take the swarm's LLM path down).
See `lib/genswarms/llm_proxy/store.ex` for the exact contract.

## Dashboard integration

The proxy is the reference implementation of the swarm-dashboard contract —
the full three-channel guide is `INTEGRATING.md` in **genswarms-objects**.
What this package does:

- **Display wire:** `emit_display/1` publishes `llm_proxy_block` (reason:
  budget/request_quota/global) and `llm_proxy_degraded` on the topic from
  `Application.get_env(:genswarms_llm_proxy, :display_wire, [:genswarms, :display])`.
  Note the proxy reads its **own** app env — a host redirecting the wire must
  set this key *in addition to* `:genswarms_objects`' one.
- **Probed extension:** `dashboard_extension/1` (`store_mod:` + optional
  `day/state_pid/users_by_*` opts) returns usage/budget pages in the generic
  schema-1 page grammar; inert `%{}` without a store. Hosts may expose
  `llm_financials_alltime/0` to split same-scope charges, router cost, and gross
  margin from reconstructed or otherwise non-comparable historical usage.
- Live emit contract test: `checks/llm_proxy_display_events_test.exs`.

### `llm_proxy_budget` machine block

Alongside the human-facing `"llm_proxy"`/`"proxy_router"` page data, the
extension also returns `"llm_proxy_budget"` — a machine block (v1) for a
future observer, not the page renderer:

- `"ceiling_usd"` — the global daily ceiling as a float; `0.0` means the
  ceiling is disabled.
- `"spent_usd"` — numeric twin of the display string above (today's spend).
- `"default_daily_limit_usd"` — the per-conversation default.
- `"health_rules"` — two shipped `budget_guard` rules (`@health_rules` in
  `lib/genswarms/llm_proxy.ex`): `budget_guard_75` (info, spend ≥ 75% of
  ceiling) and `budget_guard_90` (warn, spend ≥ 90%). Both guard on
  `ceiling_usd > 0`, so a disabled ceiling (proxy dead or `global_daily_limit`
  unset → `0.0`) makes both rules a no-op rather than a false alarm.

These rules are pure data. Nothing in this repo, or anywhere yet, evaluates
`health_rules` — there is no generic observer-side rule evaluator. Until a
host wires one up, `llm_proxy_budget.health_rules` sits inert in the
dashboard extension like any other unread field.

## Verification

Standalone contract checks (no Postgres, no network — injected seams):

```sh
mix deps.get
./checks/run.sh        # every `checks/llm_proxy_*.exs` contract check
```

Host-side integration tests against a REAL store (Postgres) live in the host
apps — the package ships the seam, the host proves its adapter.

## Runtime dependencies

`bandit`/`plug`/`jason`/`decimal` (mix), `curl` on PATH, and — at runtime only —
the genswarms engine modules of the host BEAM.
