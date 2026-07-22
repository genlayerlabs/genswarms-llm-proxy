defmodule Genswarms.LlmProxy.Store do
  @moduledoc """
  The OPTIONAL durable-accounting seam. The proxy always keeps an in-memory
  usage mirror; a host that wants budgets to survive restarts (and to be
  enforced fleet-wide) passes `store_mod:` — a module implementing any subset
  of these callbacks. Every call site is guarded with `function_exported?`,
  so a partial implementation is fine: missing callbacks fall back to the
  in-memory mirror (fail-open by design — an accounting outage must not take
  the swarm's LLM path down; the global ceiling still holds via
  `max(durable, in-memory)`).

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
  at (DateTime), meta (map)}. MUST enforce idempotency_key uniqueness and
  return {:error, :duplicate} on replay — that is the double-credit guard.
  """
  @callback record_llm_credit_entry(map()) :: :ok | {:error, :duplicate} | {:error, term()}

  @optional_callbacks record_llm_call: 5,
                      record_llm_budget_origin: 1,
                      llm_usage_for_budget: 3,
                      llm_usage_today: 1,
                      llm_usage_by_budget: 2,
                      list_llm_usage: 1,
                      llm_credit_balance: 1,
                      record_llm_credit_entry: 1
end
