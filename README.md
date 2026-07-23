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
    notice_repeat_ms: 14_400_000,     # optional — min interval between repeated
                                      # block notices per conversation per cap type
                                      # (default 4h; 0/nil = once per UTC day)
    payments_source: :payments,       # optional — see Prepaid credit ledger
                                      # (nil default = credit feature off)
    credit_namespace: "default",      # optional
    credit_per_usd: "1.0",            # optional
    topup_hint_fun: &MyApp.topup_hint/1  # optional, plug opt only
  }
}
```

Object protocol: `{"action":"usage"}`, `{"action":"health"}`,
`{"action":"quota_status","conversation_id":"…"}`,
`{"action":"payment_confirmed",...}` (see Prepaid credit ledger below).

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

## Prepaid credit ledger (optional)

Once a budget identity's free daily budget is exhausted, further calls draw
down a per-identity prepaid credit balance instead of blocking outright —
config:

- `payments_source` — the trusted object name allowed to send
  `{"action":"payment_confirmed"}`. `nil`/`""`/`false` (default: `nil`) keeps
  the whole feature off; any other sender is logged and ignored.
  `credits_enabled` is derived from this one setting — on for a non-empty
  binary, or an atom that is neither `nil` nor `false` (an object-name atom
  source); off otherwise, including the explicit `false` case — and threaded
  everywhere the feature gate matters: the plug-side block gate
  (`credit_exhausted?/2`) and debit chokepoint (`maybe_debit_credit/4`), the
  object-side message handler, AND `quota_status`'s `credit.balance_usd`
  (which reads `"0.00"` without ever consulting the store when off). With it
  off, the credit path is a true no-op — the block gate never reads a
  balance (byte-identical to 0.2.19 blocking) and a straddling call never
  debits the mirror, so a feature enabled later never retro-charges overage
  accrued while it was off.
- `credit_namespace` (default `"default"`) — a confirmation for a different
  namespace is silently ignored (multiple consumers can share one settlement
  hub, each only owns its own namespace). Both sides of the compare are
  `to_string/1`-normalized (same as the source compare), so an atom config
  (`:default`, e.g. from keyword/IR config) matches the JSON-decoded string.
- `credit_per_usd` (default `"1.0"`) — conversion rate from `amount_usd` to
  credited balance. **Boot-validated**: a non-parseable, non-finite, or
  non-positive value refuses to boot with `ArgumentError` (same stance as
  the pricing-config validation) — a tolerant parse would silently zero
  every payment while still acking it `ok:true`.
- `topup_hint_fun` — optional 1-arity fun (`budget_identity -> String.t() |
  nil`), plug opt only (not top-level config). A non-empty, non-raising
  result is appended as an extra line on a `:budget` block notice; absent,
  raising, or non-binary → no hint, never crashes the block path. Rendered
  **only while `credits_enabled` is on** (same strict derivation as every
  other credit surface): with credits off this object silently drops every
  `payment_confirmed`, so the hint would point a blocked user at a payment
  path that cannot credit them — the fun is not even called.

`payment_confirmed` is trusted-source **and** namespace gated; the required
fields are `beneficiary`, `amount_usd`, `method`, and `ref`: `amount_usd` is
**STRINGS-ONLY by contract** — it must be a JSON *string* that parses as a
*finite* `Decimal` (`"NaN"`/`"Infinity"`/`"-Infinity"` are all refused, not
just non-numeric strings) and is `> 0`. A JSON *number* (e.g. `5.0`, unquoted)
is refused too, deliberately: `parse_money/1` only matches `is_binary/1`, so
`amount_usd` arriving as a number is `bad_payment_confirmed`, not a silent
float-precision hazard — the hub sends `Decimal.to_string/1`, never a raw
number, and this contract is enforced rather than assumed. **Plain decimal
strings only**: scientific/exponent notation (`"5e2"`, `"1E+2"`) is rejected
even though it parses as a finite `Decimal` — an exponent amount is far more
likely malformed than a legitimate top-up. `method`/`ref` are
both required non-empty strings — the idempotency key is `"<method>:<ref>"`,
so a re-delivered confirmation credits the balance once. `method` **may not
contain `":"`** (refused as `bad_payment_confirmed`): the key is the plain
join with global uniqueness on the joined string, so a colon inside `method`
would make it ambiguous — `("a", "b:c")` and `("a:b", "c")` would mint the
same key `"a:b:c"` and the second, legitimately distinct, payment would be
permanently swallowed as `duplicate:true`. `ref` may contain colons freely
(tx hashes do). `method` may also not be
the literal string `"debit"` (refused with
`{"ok":false,"error":"reserved_method"}`, non-retryable): `"debit:" <>
request_id` is the ledger's reserved internal keyspace for spend debits, and
a colliding top-up key would swallow a real debit as a duplicate. Replies
`{"ok":true}` (first credit), `{"ok":true,"duplicate":true}` (replay), or
`{"ok":false,"error":"store_unavailable","retryable":true}` (durable store
configured but the write failed — see Fail policy below); a malformed
message replies `{"ok":false,"error":"bad_payment_confirmed"}`.

Durable accounting for credits is two more OPTIONAL `Store` callbacks —
`llm_credit_balance/1` (current signed balance) and
`record_llm_credit_entry/1` (append one ledger entry: top-up positive,
debit negative). `record_llm_credit_entry/1` **must** enforce
`idempotency_key` uniqueness and return `{:error, :duplicate}` on replay —
that's the double-credit guard. The two are **both-callbacks-or-neither**:
missing EITHER one falls back to the mirror for BOTH read and write (a store
exporting only `llm_credit_balance/1`, for example, is treated as fully
absent for the credit path — otherwise a mirror top-up would be shadowed by
a durable read that never actually recorded anything, and the paying user
would be told `ok` while the block gate kept reading a stale durable 0).

**Spend order:** the free daily budget spends first; only once it's
exhausted (`spent >= limit`) does the credit balance start being drawn down,
and only the overflow portion of a straddling call is debited
(`debit = overflow(spent_before + cost) - overflow(spent_before)`, entries
keyed `"debit:" <> request_id`). Because the debit is computed after the
call completes, the final credit-funded call can drive the balance slightly
negative (post-hoc costs); the global daily ceiling still bounds all spend
regardless of credit balance.

Two concurrency bounds apply here, the same TOCTOU family as the daily
budget gate (both read a `spent_before`/balance snapshot, act, then write —
never a single atomic check-and-spend across a request's full duration): **N
simultaneous credit-funded calls sharing the same budget identity can
overdraft the balance by up to N × (the largest straddle among them)** — each
racer reads a balance that hasn't yet reflected the others' debits before it
commits its own. The mirror twin of this is an **under-debit favoring the
user by the same bound**: concurrent straddles that share a `spent_before`
baseline each compute `overflow(spent_before)` against the same
pre-any-of-them number, so the total debited across all of them can be less
than the true combined overflow. Neither bound is closed by this feature —
both are inherited from the same read-then-write shape as the existing daily
budget check.

**Fail policy:** credit balance *reads* fail open to the in-memory mirror (an
accounting outage must not block spend — the gate still sees whatever the
mirror last carried). Credit *writes* fail CLOSED per spec: when a durable
store is configured (`store_mod` exports both `llm_credit_balance/1` and
`record_llm_credit_entry/1`) and `record_llm_credit_entry/1`
errors/raises/exits — **or returns any shape outside the documented
contract** (`:ok` | `{:error, :duplicate}` | `{:error, reason}`; e.g. an
adapter forwarding `Repo.insert/1`'s `{:ok, struct}`) — the entry is **not**
applied to the mirror and its
idempotency key is **not** consumed — `apply_credit_entry/3` releases the
atomic seen-mark it took before the write attempt, logs `Logger.error`,
bumps `llm_proxy_budget_degraded`, and returns `{:error,
:store_unavailable}`; `payment_confirmed` replies
`{"ok":false,"error":"store_unavailable","retryable":true}`. A later
redelivery of the *same* `(method, ref)` — once the store heals — is a
genuine retry, not a swallowed duplicate, and credits normally. This is
self-converging even when a *nonconforming-return* write actually landed:
the retry reaches the store again and its own `idempotency_key` uniqueness
answers `{:error, :duplicate}`, settling the entry exactly once. This closes
a lose-payment gap: failing open here would have permanently consumed the
idempotency key in the mirror seen-set, so the payment hub's own
redelivery-after-recovery would have been silently swallowed as
`duplicate:true` forever, with no durable record ever created. Concurrent
callers sharing the same key during the failure window still see the
existing at-most-once guarantee: only the caller that wins the atomic mark
attempts the write; every other racer gets `:duplicate` without touching the
balance, and the mark is freed for a future attempt only after that one
write fails. Mirror-only installs (no durable store at all) are unaffected —
there is nothing durable to fail closed against, so a top-up applies to the
mirror exactly as before.

**Debits during a store outage** are the one asymmetric case: the request was
already served (budget-side accounting fails OPEN — an accounting outage
never blocks the LLM path) and, unlike a top-up, a debit has no redelivery
vehicle, so a failed durable write cannot be retried later. The proxy makes
the loss visible and conservative rather than silent: it logs a warning,
bumps `llm_proxy_budget_degraded`, and applies the debit to the in-memory
mirror anyway, so the fail-open balance the gate reads during the outage is
the lower (already-debited) figure. Balance reads are durable-first, so once
the store heals its un-debited ledger shadows the mirror — the mirror debit
is never double-counted. **Accepted rider:** the durable ledger permanently
under-charges by the debits lost during the outage window (bounded by the
global daily ceiling); the log/metric trail is the reconciliation signal.

Deliverers should send confirmations serially per ref (or treat any
`ok:false` as retry-needed): a concurrent duplicate delivered during a
failing store write can be acked `duplicate:true` while the write fails —
the key is released afterward, so a serial retry always lands.

`quota_status` gains a `credit.balance_usd` field (2dp string, like the other
credit-related dollar amounts in this feature — `money2`, not the 6dp `money`
used elsewhere in `quota_status`).

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
