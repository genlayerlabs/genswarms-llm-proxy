# Changelog

## Unreleased

- Upstream decode failures now report the REAL HTTP status and a bounded,
  scrubbed snippet of the body instead of collapsing to a bare
  "upstream returned non-JSON response". That message was the only record of
  what the upstream said — `respond_upstream` stores just the error `code` as
  the row status and nothing logs the raw response — so an nginx `413` HTML
  page, a plain-text edge `error code: 502`, and a `200` with an empty body
  were indistinguishable to an operator. The snippet is scrubbed of the
  upstream key and passed through `sanitize_log/1` (strips CR/LF/C0, caps at
  220 bytes). The error `code` stays `upstream_invalid_json`, so stored row
  statuses and any query over them are unchanged.

## 0.4.1 — 2026-07-28

- Prepaid-credit balance reads now fail closed when a host has configured the
  coherent durable credit callback pair. If `llm_credit_balance/1` returns an
  error, raises, exits, or returns a nonconforming value after the free daily
  budget is exhausted, the proxy blocks the paid request before upstream
  instead of admitting it from a stale positive in-memory mirror. The normal
  block path tells the user the prepaid balance is temporarily unavailable,
  logs the failure, and records `reason: "store_unavailable"` in the structured
  quota metric; `quota_status` reports the balance as unavailable rather than
  publishing the stale amount. Hosts with a configured durable credit store
  will therefore see paid requests blocked during store outages. Hosts without
  the coherent callback pair remain in the supported in-memory mode, unchanged;
  failed reads never overwrite the mirror, and the next successful durable read
  resumes normal admission. The documented public `credit_balance/3` API
  remains always-`Decimal`: it returns conservative `Decimal.new("0")` on a
  configured read failure, while the new error-aware result path drives
  admission, notices, and `quota_status`.

## 0.4.0 — 2026-07-27

- A GENUINELY NEW prepaid credit now produces a user-facing "payment
  received" notice, closing the gap where a confirmed top-up was invisible
  until the user ran `/quota`. It rides the exact same delivery seam the
  budget-block notice already uses (`deliver_fn` -> the configured `:sender`
  via a `slot_reply` to the credited conversation's bound slot), fires from
  exactly one choke point (`apply_validated_payment/3`'s `{:ok, balance}`
  branch — reachable ONLY from the already trust-gated `payment_confirmed`
  push handler, the `poll_payments` consumer, and the operator `retry_stuck`
  action), and inherits `apply_credit_entry/3`'s own idempotency: a
  re-delivered push or a re-polled settlement resolves as a duplicate and
  never reaches the notice at all — one notice per payment, proven in
  `checks/llm_proxy_payments_credit_notice_test.exs`. Best-effort and
  money-first: the credit is applied and durable BEFORE the notice is even
  attempted, a delivery failure (raise/exit, or simply no session yet bound
  to that budget identity) is swallowed and bumps a durable
  `llm_payments_credit_notice_failed` counter, and nothing here can revert or
  delay the credit. New optional config `credit_notice_enabled` (default
  `true`) lets a host turn the notice off while keeping credits on; absent
  `sender`/`deliver_fn` degrades to a silent no-op, same as the block path.
  Message: `"💳 Payment received — $<credited> credited. Prepaid balance:
  $<balance>."` (the balance AFTER this credit).

- Operator `retry_stuck` credits SILENTLY (product decision 2026-07-27):
  the re-applied credit lands without a user-facing notice — the payment
  may be hours old and a surprise "payment received" reads as a new charge.
  Normal push/poll credits keep the notice.

- The proxy's dashboard page declares its own sidebar section (`group:
  "LLM"`) — producer-declared grouping, host stamps nothing.

- The STUCK queue is no longer a one-way door. A settled row this proxy
  classifies `{:permanent, _}` is recorded as stuck and the poll cursor advances
  past it, after which the money was unreachable by every path at once: below
  the cursor for the poll, `already_settled` for the hub's release, unreadable,
  and unrendered. Added two optional store callbacks —
  `list_llm_stuck_payments/1` (unresolved rows, or one key; excluding cleared
  rows and rows whose money is already in the credit ledger under EITHER key
  domain — the row's own upstream `idempotency_key` or the `method:ref` join
  derived from the stored row, which is the key a credit entry actually carries;
  bounded server-side) and
  `clear_llm_stuck_payment/1` — and two actions behind a NEW `operator_sources`
  allowlist that defaults to `[]` and is gated exactly like `poll_payments`
  (exact source match, explicit refusal, never a silent drop):
  `stuck_payments` (see it) and `retry_stuck` (re-apply ONE row through
  `apply_payment/3` — the same validating path the push and the poll use).
  The retry mints nothing and bypasses nothing: a row stuck by a since-fixed
  cause credits exactly once (the ledger's global key dedupe is what guarantees
  the "once"), a row that is genuinely invalid fails again with its reason
  recorded (`llm_payments_stuck_retry_failed`) and STAYS in the queue, and a
  credit whose durable clear fails is reported `cleared: false` rather than as a
  tidy success. `operator_sources` is deliberately a second list, not a reuse of
  `poll_sources`: driving the credit poll and reaching into the money the poll
  refused are different authorities. `stuck_payments` reports PAYMENTS, not
  rows: the durable queue has no key uniqueness by design (a repeat is operator
  evidence), so repeats of one key are collapsed before `count`, `total_usd`
  and `rows` — otherwise a single stuck settlement inflates the money total
  once per poll tick it spends inside the trailing window.
- `notice_variant/3` now reads holds DURABLE-FIRST, like the sentence it gates.
  Reading the mirror there while the sentence read the store meant the two
  disagreed on any instance that did not record the hold: the notice was built
  correctly but the dedup key was the plain 3-tuple, so an identity already
  notified that day was told nothing at all — while the agent was told the user
  had already been notified — for a whole `notice_repeat_ms` window.
- The durable hold read is now bounded on both sides. The contract states that
  the store MUST cap it server-side (it sits on a per-request path over a table
  a third party can grow, since deposit addresses are permissionless and a
  saturated issuance window quarantines everything), and the proxy truncates at
  50 rows with a warning rather than trusting that.

- The hold notice now SURVIVES A RESTART. Added two optional store callbacks —
  `list_llm_held_payments/1` (unresolved holds for one budget identity,
  excluding cleared rows and rows already present in the credit ledger) and
  `clear_llm_held_payment/3` (mark resolved; scoped to the credited identity,
  matching key **or** bare ref) — plus `held_payments/3` and
  `held_notice_line/3`, the durable-first arities the block notice and
  `quota_status` now use. Before this, the only consumer-side record of a hold
  was the bounded in-process mirror, so one deploy left a user blocked, already
  paid, being told to pay again, with `quota_status` asserting there was no
  hold. A durable answer is authoritative even when empty; a missing callback
  keeps the previous memory-only behaviour byte-for-byte, and a failing read
  falls back to the mirror. The durable clear runs on every credit that
  resolves a hold, not only when this instance's mirror matched, so a released
  payment cannot resurrect its notice on the next restart
  (`llm_payments_held_clear_failed` covers the failure).

- Added the `payment_held` action: the consumer side of the settlement hub's
  issuance caps. It **never credits** — behind the same trust gate a forged
  `payment_confirmed` faces, it records the hold in a 200-entry FIFO mirror
  (evictions logged), calls the new optional `record_llm_held_payment/1` store
  callback (failure logged, metered, never fatal), and emits
  `llm_payments_held` / `llm_payments_held_refused` /
  `llm_payments_held_cleared`. The hub sends `method`, `namespace` and `at`
  (genswarms-payments ≥ `01ab1dd`); all three stay optional so redeliveries
  from an older hub still work, but a *present* namespace must match
  `credit_namespace`, and a present-but-unusable `method` (empty, non-string,
  or containing `":"`) is refused as `bad_payment_held` exactly as the credit
  path refuses it.
- Both held-mirror predicates — the dedup and the clearing — are scoped on
  `(budget_identity, key)`, never the key alone. Money is per-identity and the
  key shapes share a keyspace (the hub's `ref` legitimately contains a colon),
  so a global predicate would let one beneficiary's settlement clear another
  beneficiary's hold, or swallow a second identity's hold as a "duplicate"
  while acking the hub `ok:true`.
- A user whose money is held is no longer told nothing: while a hold is
  unresolved, the identity's budget-block notice gains one sentence
  ("Payment received but held for review: $X — not credited yet. An operator
  has to release it."), summed across holds and appended once. It rides the
  existing notice delivery, `{identity, cap, day}` dedup and
  `notice_repeat_ms` rate limit — no second notification channel — except that
  a *newly appeared* hold changes the dedup key, so the first notice after a
  quarantine is always due instead of waiting out the repeat window. While the
  sentence is showing, the `topup_hint_fun` line is **suppressed**: the cap
  that produced the hold is likely still saturated, so telling a blocked user
  to send more USDC would just freeze more of their money. The hint returns
  once the hold clears. A later credit for the same beneficiary and `ref` (the
  operator release) clears the hold.
  *Known limitation:* a credit is the only thing that clears a hold, so a
  voided/refunded hold, or a manual credit under a synthetic ref, leaves the
  sentence standing for the life of the process — to be closed with a
  `payment_voided` action or a bounded TTL before the operator release
  affordances land.
- `quota_status.payments_poll` gained `held` (the most recent 10 unresolved
  holds for the asked identity, newest first) and `held_count`. Both are
  identity-scoped; the whole block remains absent without `settlements_fn`.
  Note that `quota_status` remains unauthenticated (as it already was for
  balances and spend), so any object that can name a `conversation_id` can now
  also read that conversation's hold refs and amounts — a conscious
  carry-forward of the existing authorization model, not a new class.
- `Genswarms.LlmProxy.notice_due?/5` gained an optional `:variant` term folded
  into the dedup key. Default `nil` = the pre-0.4.0 3-tuple key, unchanged.
- **D9 boot gate — credits imply pricing.** With `payments_source` configured,
  `init/1` now refuses to boot unless `prices` is a complete non-negative
  rate card with at least one positive per-Mtok price, in every pricing mode.
  A proxy that takes a user's money and charges $0.00 per call never consumes
  the credit — the liability stays open forever. A `0/0` card is still legal
  with credits off (free tier); the gate cannot fire on an install with no
  payments source.
- **C4 — `budget_identity/1` documented as a pinned host-facing contract** and
  guarded by a golden vector (`checks/llm_proxy_budget_identity_golden_test.exs`),
  asserted identically host-side: hosts derive deposit beneficiaries from it,
  so a shape change silently re-keys every user's deposit address.
- Added the default-off `poll_payments` durable outbox consumer with a
  trailing-window read, per-consumer cursor, unfiltered-page `next_seq`
  advancement, per-row applied/duplicate/transient/stuck disposition, and
  cursor-ahead protection.
- Added optional coherent cursor callbacks and a durable stuck-payment
  operator-queue callback to `Genswarms.LlmProxy.Store`; the in-memory stuck
  mirror is FIFO-bounded to 200 entries.
- Added `llm_payments_lag`, stuck, cursor anomaly, and cursor read/write
  telemetry through the existing `bump_metric/3` store seam. Configured
  polling is visible in `quota_status.payments_poll`; cursor-store errors now
  report `{cursor: null, unavailable: true}` instead of fabricated zeros.
- Fixed dense-sequence poll liveness by requesting
  `poll_lag + poll_limit` rows, giving the trailing replay window separate
  progress capacity. Init now boot-validates the poll types and requires the
  combined request to fit the settlements hub's 500-row cap.
- Poll cursors are advance-only, unchanged cursor writes are skipped, and
  trailing-window rereads dedupe stuck appends/alarms against the 200-entry
  in-memory mirror. The mirror is the dedupe horizon; one re-append per key
  after restart or eviction is acceptable.
- Payment-created credit entries now stamp the conversion rate in force,
  source (`push` or `poll`), and outbox sequence when present without dropping
  existing map metadata. Non-map hub metadata is dropped with a warning. The
  push action remains the latency path and retains its existing replies and
  trust behavior.

## 0.3.0 — 2026-07-23

- Fixed (review R3-I1): a NONCONFORMING `record_llm_credit_entry/1` return
  VALUE (e.g. an adapter forwarding `Repo.insert/1`'s `{:ok, struct}`) no
  longer raises `CaseClauseError` out of `apply_credit_entry/3` — it is now
  treated exactly like a failed write (warning naming the shape, seen-mark
  released, `{:error, :store_unavailable}`). Pre-fix consequences: the top-up
  path leaked the idempotency seen-mark forever (redelivery acked
  `duplicate:true` while the balance was never applied — a success-shaped
  lost payment) and the debit path 502'd an already-billed chat call / let
  the raise escape uncaught on the compact route. Self-converging when the
  nonconforming write actually landed: the hub's retry hits the store's own
  uniqueness and settles as `{:error, :duplicate}` exactly once.
- Fixed (review R3-M2): `topup_hint_fun` is now gated on the same strict
  `credits_enabled` derivation as every other credit surface — with credits
  off the object silently drops every `payment_confirmed`, so the hint would
  have pointed a blocked user at a payment path that cannot credit them. Off
  → no hint (fun not even called), byte-identical 0.2.19 notice.
- Fixed (review R3-M1): `method` containing `":"` is refused
  (`bad_payment_confirmed`) — the idempotency key is the plain
  `"<method>:<ref>"` join with global uniqueness, so a colon in `method` made
  it ambiguous: `("a", "b:c")` and `("a:b", "c")` minted the same key and the
  second, legitimately distinct, payment was permanently swallowed as
  `duplicate:true`. `ref` keeps colons freely (tx hashes).
- Docs (review R3-M4): known limitation — the credit mirror starts cold on
  restart, so a durable READ outage immediately after a restart blocks a
  paying user (gate sees 0) until the store read heals; free daily-budget
  calls are unaffected.

- Fixed (review I1): a credit DEBIT whose durable write fails during a store
  outage is no longer lost silently — the request stays served (budget-side
  accounting fails open by design), but the proxy now logs a warning, bumps
  `llm_proxy_budget_degraded`, and applies the debit to the in-memory mirror
  so the fail-open balance stays the conservative lower figure until the
  store heals (balance reads are durable-first, so the healed ledger shadows
  the mirror — no double-count; the durable-side outage under-charge is a
  documented rider in the README fail policy).
- Fixed (review I2): a nonconforming store budget row with `limit_usd: nil`
  no longer makes the gate and the debit disagree — `normalize_debit_budget/1`
  now falls back to the exact same module default the gate (`exhausted?/1`)
  uses, instead of the session/opts chain (which could under- or
  double-charge the straddle band).
- Hardening: `payment_confirmed` is now gated on the same strict
  `credits_enabled` derivation as the plug side (`payments_source: false` +
  a sender literally named `"false"` can no longer mint a mirror balance);
  the namespace compare is `to_string/1`-normalized on both sides (an atom
  `credit_namespace` config no longer silently drops every payment);
  `method: "debit"` is refused as `reserved_method` (non-retryable — it would
  collide with the ledger's internal `"debit:<request_id>"` keyspace);
  exponent-notation `amount_usd` (`"5e2"`) is rejected — plain decimal
  strings only; and a non-parseable/non-finite/non-positive `credit_per_usd`
  now refuses to boot with `ArgumentError` instead of silently zeroing every
  payment.

- Prepaid credit ledger: free daily budget spends first; once exhausted, calls
  draw down a per-budget-identity credit balance (durable via two new OPTIONAL
  Store callbacks `llm_credit_balance/1` + `record_llm_credit_entry/1`;
  in-memory mirror otherwise). The two are both-callbacks-or-neither: a store
  exporting only one of them is treated as fully absent for the credit path
  and falls back to the mirror for both read and write (a paying user must
  never be told `ok` while the gate keeps reading a stale durable 0). Only
  the overflow portion of a straddling call is debited; the final
  credit-funded call may drive the balance slightly negative (post-hoc
  costs). The global daily ceiling still bounds ALL spend.
- The whole credit path is feature-gated on `credits_enabled` (derived from
  `payments_source` being configured and non-empty; default off): with it
  off, the block gate never consults a credit balance and a straddling call
  never debits the mirror — a feature-off install cannot accrue a negative
  mirror balance that a later payments rollout would retro-charge.
- `payment_confirmed` top-ups: trusted-source + namespace gated
  (`payments_source`, `credit_namespace`, `credit_per_usd` config), rejects
  non-positive AND non-finite `amount_usd` (`"NaN"`/`"Infinity"`/`"-Infinity"`
  — `Decimal.parse/1` accepts all three; unrejected, `"NaN"` would raise past
  the `> 0` guard and `"Infinity"` would mint an unbounded balance) and
  confirmations missing `method`/`ref`, and is idempotent on `method:ref` — a
  re-delivered confirmation credits once (replies `ok` or `duplicate`; a
  durable-store write failure fails CLOSED — `ok:false,
  error:"store_unavailable", retryable:true`, credit NOT applied, idempotency
  key NOT consumed, so a later redelivery of the same `method:ref` succeeds
  once the store heals). Payment-agnostic: any settlement hub or operator
  tool can be the source.
- Fixed: `maybe_debit_credit`'s overflow limit now matches whatever
  `budget.limit_usd` the block gate itself consulted (a store-row-pinned
  limit differing from `session.daily_limit_usd`/`default_daily_limit`
  previously let the gate and the debit disagree — double-charging or
  under-charging the straddle band); an integer `spent_usd` from a legacy
  store no longer crashes the debit path (coerced via `decimal/1`).
- `quota_status` gains `credit.balance_usd`; budget block notices append the
  host-injected `topup_hint_fun` line when configured. Request-path behavior
  is identical to 0.2.19 (`quota_status` additionally carries an additive
  credit block) when none of the new config is set.
- Fixed: `credits_enabled?/1` (the boot-time derivation of `credits_enabled`
  from `payments_source`) now treats `payments_source: false` as OFF — it
  previously fell to a wildcard `true` (neither `nil` nor `""`), the opposite
  of what setting it to `false` means. ON only for a non-empty binary or an
  atom that is neither `nil` nor `false`.
- Fixed: `quota_status`'s `credit.balance_usd` now honors `credits_enabled`
  too, not just the block gate — a feature-off install shows `"0.00"`
  WITHOUT ever calling the store's `llm_credit_balance/1` (previously it
  always read through, potentially displaying a durable balance the block
  gate ignores entirely).
- Fixed: `credit_payment/2` and `quota_status/2` now resolve `store_mod` via
  one shared function (previously opposite precedence between a top-level
  and a `:quota`-nested `store_mod` — a split-brain risk if a host state ever
  carried two different values in the two places).
- Docs: `interface/0`'s `payment_confirmed` example now uses the actual
  `credit_namespace` default (`"default"`, was the arbitrary `"llm_quota"`)
  and documents that `namespace` must match the host's configured value.
  README documents `amount_usd` is STRINGS-ONLY by contract (a JSON number is
  refused, not accepted with float-precision risk — the hub always sends
  `Decimal.to_string/1`), pinned by a new check.

## 0.2.19 — 2026-07-18

- **Truthful block content**: the synthetic 200 completion returned on a
  blocked request now describes what THIS request did. It only claims "a
  deterministic Telegram notice was sent" when one actually went out; when the
  notice was rate-limit-suppressed it says the user was already notified
  earlier today. Applies to buffered JSON and SSE bodies for all three cap
  types. (Previously the second and later blocks of the day falsely claimed a
  notice was sent, so agents stayed silent while users heard nothing.) The
  global-ceiling streaming block now carries the service-wide framing instead
  of the per-conversation budget text.
- **Rate-limited repeat notices**: block notices are keyed by
  `{budget_identity, cap type, UTC day}` with a last-notified timestamp and
  repeat after `notice_repeat_ms` (new config/plug opt, default 4 hours;
  explicit `0`/`nil` = legacy once per UTC day). Replaces the once-per-day
  boolean set; still day-pruned, per process lifetime, atomic under
  concurrency. `notice_once?/3` remains as a deprecated shim over the new
  `notice_due?/5`.
- **Independent notices per cap type**: a per-conversation dollar block no
  longer silences a later request-quota or global-ceiling notice for the same
  conversation (and vice versa) — the cap type is part of the dedup key.
- **`notify: false` sessions**: `register_session`/`register_static_session`
  accept `notify: false` for background sessions (e.g. a summarizer slot
  sharing the conversation's budget identity). When blocked they neither
  deliver a Telegram notice nor consume/advance the notice timestamp, and
  their synthetic content states that no user notice was sent by this path.
  Default `true` preserves existing delivery semantics.

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
  the router billed for the failed seal on the `compact_error` row. Hosts
  running a closed-allowlist metrics object must allowlist the new key
  alongside `llm_proxy_compact` / `llm_proxy_compact_block`, or the bumps are
  silently dropped.
- Legacy seals do NOT move `llm_proxy_provider_cost_unknown`: the absence of
  both additive keys is the contract's expected compat arm, not a missing
  cost signal, so the counter keeps meaning "billable call whose router
  omitted a cost". A new router that attaches `usage`/`x_router` but omits
  `cost_usd` still trips it.
- Chat error-path ledger rows now record billed router cost too: when a
  non-2xx upstream body proves a billed partial call (OpenAI-shape `usage`,
  or a known `x_router.cost_usd`), the error row carries the same two-spends
  accounting as `compact_error` rows and the error `x_router` surfaces the
  charge — `SUM(cost_usd)` never undercounts. Plain error bodies keep the
  minimal $0 row with no counter noise.

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
