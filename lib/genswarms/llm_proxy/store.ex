defmodule Genswarms.LlmProxy.Store do
  @moduledoc """
  The OPTIONAL durable-accounting seam. The proxy always keeps an in-memory
  usage mirror; a host that wants budgets to survive restarts (and to be
  enforced fleet-wide) passes `store_mod:` — a module implementing any subset
  of these callbacks, subject to the coherent callback groups documented
  below. Every call site is guarded with `function_exported?`; missing groups
  fall back to the in-memory mirror (fail-open by design — an accounting
  outage must not take the swarm's LLM path down; the global ceiling still
  holds via `max(durable, in-memory)`).

  All money values are `Decimal`; `day` is a `Date` (UTC).
  """

  @doc "Record one upstream call: (session_attrs, day, cost_usd, tokens, meta)."
  @callback record_llm_call(map(), Date.t(), Decimal.t(), map(), map()) :: :ok | {:error, term()}

  @doc "Record the budget identity a session was bound under (origin audit)."
  @callback record_llm_budget_origin(map()) :: :ok | {:error, term()}

  @doc "Spend + request count for one budget identity on `day` (limit passed for context)."
  @callback llm_usage_for_budget(String.t(), Date.t(), Decimal.t()) ::
              {:ok, %{spent: Decimal.t(), requests: non_neg_integer()}} | {:error, term()}

  @doc "Global spend across ALL identities on `day` (the cost-DoS backstop reads this)."
  @callback llm_usage_today(Date.t()) :: {:ok, Decimal.t()} | {:error, term()}

  @doc "Per-budget usage rows for `day` (dashboard extension), capped at `limit` rows."
  @callback llm_usage_by_budget(Date.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}

  @doc "All usage rows for `day` (operator/debug surface)."
  @callback list_llm_usage(Date.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Current prepaid credit balance for a budget identity (sum of all credit
  entries, signed). Credits are the post-daily-limit overflow pool.
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
                      llm_usage_for_budget: 3,
                      llm_usage_today: 1,
                      llm_usage_by_budget: 2,
                      list_llm_usage: 1,
                      llm_credit_balance: 1,
                      record_llm_credit_entry: 1,
                      llm_payments_cursor: 1,
                      put_llm_payments_cursor: 2,
                      record_llm_stuck_payment: 1,
                      record_llm_held_payment: 1,
                      list_llm_held_payments: 1,
                      clear_llm_held_payment: 3
end
