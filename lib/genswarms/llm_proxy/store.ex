defmodule Genswarms.LlmProxy.Store do
  @moduledoc """
  The OPTIONAL durable-accounting seam. The proxy always keeps an in-memory
  usage mirror; a host that wants budgets to survive restarts (and to be
  enforced fleet-wide) passes `store_mod:` — a module implementing any subset
  of these callbacks, subject to the coherent callback groups documented
  below. Every call site is guarded with `function_exported?`; missing groups
  fall back to the in-memory mirror. Usage-budget accounting remains fail-open
  (the global ceiling still holds via `max(durable, in-memory)`), but a
  configured credit-balance read failure blocks paid admission rather than
  trusting a stale positive mirror.

  All money values are `Decimal`; `day` is a `Date` (UTC).
  """

  @doc "Record one upstream call: (session_attrs, day, cost_usd, tokens, meta)."
  @callback record_llm_call(map(), Date.t(), Decimal.t(), map(), map()) :: :ok | {:error, term()}

  @doc "Record the budget identity a session was bound under (origin audit)."
  @callback record_llm_budget_origin(map()) :: :ok | {:error, term()}

  @doc """
  Read back the origin recorded by `record_llm_budget_origin/1`, or `nil` when
  this identity was never bound.

  The credit notice needs it. A credit arrives out of band — a deposit
  confirms minutes after the user asked for it, or after a restart — so by the
  time there is money to announce there is usually no live session left to
  answer into. This callback is the durable route: the conversation the
  identity was last bound to. Without it a credit is silently unannounced,
  which is the worst failure of the three (the money is in, the user cannot
  tell).

  The returned map carries at least `:conversation_id`. Optional: hosts that
  do not implement `record_llm_budget_origin/1` have nothing to read back.
  """
  @callback llm_budget_origin(String.t()) :: {:ok, map() | nil} | {:error, term()}

  @doc "Spend + request count for one budget identity on `day` (limit passed for context)."
  @callback llm_usage_for_budget(String.t(), Date.t(), Decimal.t()) ::
              {:ok, %{spent: Decimal.t(), requests: non_neg_integer()}} | {:error, term()}

  @doc "Global spend across ALL identities on `day` (the cost-DoS backstop reads this)."
  @callback llm_usage_today(Date.t()) :: {:ok, Decimal.t()} | {:error, term()}

  @doc "Per-budget usage rows for `day` (dashboard extension), capped at `limit` rows."
  @callback llm_usage_by_budget(Date.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Complete UTC-day dashboard aggregates across all budget identities, independent
  of detail-table limits. Money is summed as Decimal before presentation rounding.
  A missing callback or failed read renders complete totals unavailable; a bounded
  detail list is never a fallback for this summary. Budget identities are not
  verified unique people.
  """
  @callback llm_usage_summary(Date.t()) ::
              {:ok,
               %{
                 budgets: non_neg_integer(),
                 requests: non_neg_integer(),
                 prompt_tokens: non_neg_integer(),
                 total_tokens: non_neg_integer(),
                 cached_tokens: non_neg_integer(),
                 spent_usd: Decimal.t()
               }}
              | {:error, term()}

  @doc "All usage rows for `day` (operator/debug surface)."
  @callback list_llm_usage(Date.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Current prepaid credit balance for a budget identity (sum of all credit
  entries, signed). Credits are the post-daily-limit overflow pool. This
  callback and `record_llm_credit_entry/1` are one coherent optional group:
  missing either callback selects mirror-only mode; with both configured, a
  read error makes the balance unavailable and paid admission fails closed.
  """
  @callback llm_credit_balance(String.t()) :: {:ok, Decimal.t()} | {:error, term()}

  @doc """
  Append one credit-ledger entry: %{idempotency_key, budget_identity,
  amount_usd (signed Decimal: + top-up, − debit), kind ("credit"|"debit"),
  at (DateTime), meta (map)}. MUST enforce idempotency_key uniqueness
  GLOBALLY (across ALL budget identities, not just within one) and return
  {:error, :duplicate} on replay — that is the double-credit guard.

  The in-memory mirror's own dedup (a `seen` set per budget_identity) is only
  PER-IDENTITY, not global — it can't be, since it never sees other
  identities' entries. A source that (buggily or maliciously) reuses the same
  `idempotency_key` (e.g. the same `"<method>:<ref>"`) across two DIFFERENT
  beneficiaries is therefore invisible to the mirror: both would be accepted
  as "newly marked" there. The store's global-uniqueness constraint is the
  only thing that catches that case — it's the reason this callback's
  uniqueness scope is global, not per-identity.
  """
  @callback record_llm_credit_entry(map()) :: :ok | {:error, :duplicate} | {:error, term()}

  @doc """
  Read the durable outbox cursor for `consumer`.

  This callback and `put_llm_payments_cursor/2` are one coherent optional
  group: hosts should export both or neither. A missing pair uses the bounded
  in-memory poll mirror; an exported pair is authoritative.
  """
  @callback llm_payments_cursor(consumer :: String.t()) ::
              {:ok, non_neg_integer() | nil} | {:error, term()}

  @doc """
  Persist the durable outbox cursor for `consumer`.

  See `llm_payments_cursor/1`; the cursor pair is consumed together.
  """
  @callback put_llm_payments_cursor(
              consumer :: String.t(),
              seq :: non_neg_integer()
            ) ::
              :ok | {:error, term()}

  @doc """
  Append a permanently rejected settlement to the durable operator queue.

  The map is the full settlement row plus `reason` and `at`. This callback is
  optional independently of the cursor pair; the proxy also retains a bounded
  in-memory FIFO mirror for operator visibility and uses that mirror as its
  idempotency-key dedupe horizon. A trailing-window replay does not invoke this
  callback again while the key remains mirrored; after a process restart or
  mirror eviction, one repeated append per key is acceptable.
  """
  @callback record_llm_stuck_payment(payment :: map()) :: :ok | {:error, term()}

  @doc """
  UNRESOLVED permanently-rejected settlements — the read half of
  `record_llm_stuck_payment/1`, and the reason it exists.

  A settled row the proxy classifies `{:permanent, _}` is written to the stuck
  queue and the poll cursor ADVANCES PAST IT. From that moment the money is
  unreachable by every path at once: below the cursor, so no poll re-presents
  it; already `settled` at the hub, so the operator release answers
  `already_settled` and pushes nothing; and — until this callback — unreadable,
  so no surface anywhere could even show that it existed. That is the same
  one-way door the durable hold fixed, one lane over.

  `idempotency_key` is `nil` for the whole unresolved queue, or a key to scope
  to one row (what `retry_stuck` uses to fetch the row it re-applies).

  Rows carry `idempotency_key`, `reason`, `at`, and `row` — the FULL settlement
  map as it was rejected, because that map is what a retry re-applies. `row`
  keys may be strings or atoms; the proxy reads both.

  "Unresolved" is the store's judgement and MUST exclude money that has since
  been credited or explicitly cleared, exactly as `list_llm_held_payments/1`
  does: rows cleared through `clear_llm_stuck_payment/1`, and rows whose money
  is now in the credit ledger.

  THE CREDITED-KEY EXCLUSION SPANS TWO KEY DOMAINS, AND A STORE THAT MATCHES
  ONLY ONE OF THEM HAS NOT IMPLEMENTED IT. A stuck row is keyed on whatever the
  settlement carried — for the rows this proxy's poll produces that is the
  UPSTREAM key (e.g. `"84532:0xTX:0"`) — while the credit entry that resolves
  it is keyed `"method:ref"` (e.g. `"usdc_base-sepolia:0xTX:0"`). Those are two
  deliberate dedup domains and the strings never match, so a key-to-key join
  self-heals nothing for the dominant shape. The stored `row` carries `method`
  and `ref`, which is exactly what the credit key is built from: exclude a row
  when EITHER its own `idempotency_key` OR the `method:ref` join derived from
  its stored `row` is in the ledger. This matters on two ordinary paths — a
  crash between the credit and `clear_llm_stuck_payment/1`, and the ordinary
  poll re-crediting a previously-stuck row through its trailing window, which
  clears nothing at all. Without both legs the queue reports money as
  uncredited that is in the ledger, which is the one property the queue exists
  to provide.

  BOUNDED SERVER-SIDE. There is no limit parameter on purpose: an unbounded
  read on a table an outsider can grow is a DoS the caller cannot fix. The
  store caps the rows it returns and the operator surface says the view may be
  truncated. Optional and independent; without it the stuck queue is
  write-only, as it was before 0.4.0.
  """
  @callback list_llm_stuck_payments(idempotency_key :: String.t() | nil) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Mark a stuck payment RESOLVED, durably.

  Called after `retry_stuck` re-applied the row through the ordinary validating
  credit path and it credited (or was already credited). Without a DURABLE
  clear the row would reappear in the queue on the next read and an operator
  would retry money that is already in the ledger — harmless (the credit key
  dedupes) but indistinguishable from money that still needs attention, which
  is the property the queue exists to provide.

  A row that fails the validator again is NOT cleared: it stays visible, with
  its reason, so the queue keeps showing exactly the money that still needs an
  operator.

  Returns the number of rows it resolved (0 is legitimate). Optional and
  independent; without it a retry still credits — it just cannot durably tidy
  the queue, which the reply says plainly rather than claiming otherwise.
  """
  @callback clear_llm_stuck_payment(idempotency_key :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Append one HELD (hub-quarantined) settlement to the durable
  operator/user-facing record.

  The map is `%{budget_identity, beneficiary, idempotency_key, method (may be
  nil), ref, amount_usd (Decimal), reason, namespace, at (DateTime)}`. A held
  settlement is money that arrived and was deliberately NOT credited pending an
  operator release, so this is a NOTICE record, never a ledger entry — nothing
  in the credit path reads it back.

  Optional and independent of every other group. The proxy also keeps a
  bounded in-memory FIFO mirror (that mirror, not this callback, is what
  dedupes and what feeds the user-visible block-notice line and
  `quota_status`), so a failure here is logged and metered
  (`llm_payments_held_store_failed`) and never crashes the handler. After a
  restart or a mirror eviction one repeated append per key is acceptable.
  """
  @callback record_llm_held_payment(payment :: map()) :: :ok | {:error, term()}

  @doc """
  UNRESOLVED held payments for ONE budget identity, oldest first.

  The read half of `record_llm_held_payment/1`, and the reason it exists: the
  proxy's in-memory hold mirror is bounded and process-local, so every deploy
  erases it — and that mirror is the ONLY source of the user's "your payment is
  held" sentence. Without a durable read, a restart tells a user who has
  already paid that they have no hold and should pay again. With it, the
  sentence survives the restart.

  "Unresolved" is the store's judgement and it MUST exclude money that has
  since been credited or explicitly cleared. Two exclusions, both required:

    * rows cleared through `clear_llm_held_payment/3`;
    * rows whose `idempotency_key` now exists in the credit ledger — the
      release path credits under exactly the `"<method>:<ref>"` the hold was
      keyed by, so a credit IS a resolution even if the clear never ran (a
      crash between the two, or a credit applied by another instance).

  Rows carry the same shape `record_llm_held_payment/1` was given
  (`budget_identity`, `idempotency_key`, `ref`, `amount_usd` as a `Decimal`,
  `reason`, `at`). Optional and independent: without it the hold surfaces read
  the in-memory mirror exactly as they did before, i.e. memory-only.

  BOUNDED SERVER-SIDE, and this is a requirement, not a suggestion. There is no
  limit parameter on purpose — a limit the caller passes is a limit the caller
  can get wrong, and this read sits on a PER-REQUEST path (every blocked
  request builds the notice line from it, and `quota_status` reads it again).
  The mirror this replaced was capped at 200 with logged eviction; the durable
  table it reads is deliberately non-unique on `idempotency_key` and deposit
  addresses are permissionless, so a saturated issuance window (which
  quarantines everything) lets a third party grow one identity's row count at
  will. The store MUST cap the rows it returns — the proxy additionally
  truncates and logs, but a store that streams the whole table has already
  spent the cost. Truncation is acceptable and must be visible; unboundedness
  is not.
  """
  @callback list_llm_held_payments(budget_identity :: String.t()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Mark a held payment RESOLVED, durably.

  Called when a credit lands for the same money. Without it a released payment
  would resurrect its "held for review" notice on the next restart, which is
  the same defect as losing the notice, pointed the other way.

  Matches the mirror's predicate exactly: the given `budget_identity` AND
  (`idempotency_key` = `key` OR `ref` = `ref`) — the bare-`ref` arm serves a
  hold recorded by a hub too old to send `method`. `ref` may be nil.
  Scoping to the credited identity is not optional: money is per-identity, and
  one user's credit must never clear another user's hold.

  Returns the number of rows it resolved (0 is a legitimate answer — the hold
  may never have been recorded here). Optional and independent; when absent,
  clearing is mirror-only, exactly as before.
  """
  @callback clear_llm_held_payment(
              budget_identity :: String.t(),
              idempotency_key :: String.t(),
              ref :: String.t() | nil
            ) :: {:ok, non_neg_integer()} | {:error, term()}

  @optional_callbacks record_llm_call: 5,
                      record_llm_budget_origin: 1,
                      llm_budget_origin: 1,
                      llm_usage_for_budget: 3,
                      llm_usage_today: 1,
                      llm_usage_by_budget: 2,
                      llm_usage_summary: 1,
                      list_llm_usage: 1,
                      llm_credit_balance: 1,
                      record_llm_credit_entry: 1,
                      llm_payments_cursor: 1,
                      put_llm_payments_cursor: 2,
                      record_llm_stuck_payment: 1,
                      list_llm_stuck_payments: 1,
                      clear_llm_stuck_payment: 1,
                      record_llm_held_payment: 1,
                      list_llm_held_payments: 1,
                      clear_llm_held_payment: 3
end
