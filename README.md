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
  (router `x_router.tokens_cached` canonical, Anthropic/OpenAI shapes as fallback),
  optional cost margin (`margin_pct`).
- **Streaming gate** (`allow_streaming`) and **prompt-cache marking** (`prompt_cache`).
- Upstream via curl with the key in a private tempfile config — never argv.

## As a genswarms object

```elixir
%{
  name: :llm_proxy,
  handler: Genswarms.LlmProxy,
  config: %{
    upstream_endpoint: "https://router.example/v1/chat/completions",
    upstream_api_key: System.fetch_env!("LLM_PROXY_UPSTREAM_API_KEY"),
    provider: "openai-compatible",
    prices: %{"model-a" => %{prompt: "3.00", completion: "15.00"}},
    default_daily_limit: "0.50",
    global_daily_limit: "25.00",
    daily_request_limit: 200,
    store_mod: MyApp.LlmProxyStore,   # optional — see Durable accounting
    dm_module: MyApp.Cid,             # optional — exports dm?/1 for per-kind budgets
    metrics: :metrics,                # optional — counter-bump target object
    sender: :sender                   # notice delivery target
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

## Verification

Standalone contract checks (no Postgres, no network — injected seams):

```sh
mix deps.get
./checks/run.sh        # 11 checks, each `mix run checks/<file>.exs`
```

Host-side integration tests against a REAL store (Postgres) live in the host
apps — the package ships the seam, the host proves its adapter.

## Runtime dependencies

`bandit`/`plug`/`jason`/`decimal` (mix), `curl` on PATH, and — at runtime only —
the genswarms engine modules of the host BEAM.
