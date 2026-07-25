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
  in-memory FIFO mirror for operator visibility.
  """
  @callback record_llm_stuck_payment(payment :: map()) :: :ok | {:error, term()}

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
                      record_llm_stuck_payment: 1
end
