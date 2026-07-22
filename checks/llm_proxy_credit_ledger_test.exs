# Credit ledger primitives (Task 1): mirror, durable seam, idempotency, fail-open.
# Standalone — NO Postgres, NO network.   mix run checks/llm_proxy_credit_ledger_test.exs
alias Genswarms.LlmProxy, as: Proxy

{:ok, failures} = Agent.start_link(fn -> [] end)

check = fn label, ok ->
  if ok do
    IO.puts("  ok   #{label}")
  else
    IO.puts("  FAIL #{label}")
    Agent.update(failures, &[label | &1])
  end
end

defmodule CreditStore do
  def reset do
    :persistent_term.put({__MODULE__, :d}, %{balances: %{}, keys: MapSet.new(), down: false})
  end

  defp d, do: :persistent_term.get({__MODULE__, :d})
  defp put(m), do: :persistent_term.put({__MODULE__, :d}, m)
  def down!(flag), do: put(%{d() | down: flag})
  def entries_balance(bi), do: Map.get(d().balances, bi, Decimal.new("0"))

  def llm_credit_balance(bi) do
    if d().down, do: {:error, :db_down}, else: {:ok, entries_balance(bi)}
  end

  def record_llm_credit_entry(%{idempotency_key: key, budget_identity: bi, amount_usd: amt}) do
    cond do
      d().down -> {:error, :db_down}
      MapSet.member?(d().keys, key) -> {:error, :duplicate}
      true ->
        put(%{
          d()
          | keys: MapSet.put(d().keys, key),
            balances: Map.update(d().balances, bi, amt, &Decimal.add(&1, amt))
        })
        :ok
    end
  end
end

CreditStore.reset()
{:ok, pid} = Proxy.start_state_link()
bi = "w:default|k:dm|c:tg:1:0"

entry = fn key, amt ->
  %{idempotency_key: key, budget_identity: bi, amount_usd: Decimal.new(amt),
    kind: "credit", at: ~U[2026-07-22 12:00:00Z], meta: %{}}
end

# 1. no store: mirror-only crediting works and dedups
{:ok, b1} = Proxy.apply_credit_entry(pid, nil, entry.("m:1", "5.00"))
check.("mirror credit applies (nil store)", Decimal.equal?(b1, Decimal.new("5.00")))
check.("mirror dedup (nil store)", Proxy.apply_credit_entry(pid, nil, entry.("m:1", "5.00")) == :duplicate)
check.("mirror balance readable", Decimal.equal?(Proxy.credit_balance(pid, nil, bi), Decimal.new("5.00")))
check.("unknown identity balance is 0", Decimal.equal?(Proxy.credit_balance(pid, nil, "w:x|k:dm|c:y"), Decimal.new("0")))

# 2. durable store: entry recorded durably AND mirrored
{:ok, pid2} = Proxy.start_state_link()
{:ok, b2} = Proxy.apply_credit_entry(pid2, CreditStore, entry.("d:1", "3.00"))
check.("durable credit lands in store", Decimal.equal?(CreditStore.entries_balance(bi), Decimal.new("3.00")))
check.("durable credit mirrored", Decimal.equal?(b2, Decimal.new("3.00")))
check.("durable dedup via store :duplicate",
  Proxy.apply_credit_entry(pid2, CreditStore, entry.("d:1", "3.00")) == :duplicate)
check.("balance read prefers durable",
  Decimal.equal?(Proxy.credit_balance(pid2, CreditStore, bi), Decimal.new("3.00")))

# 3. store down: WRITE fails open to mirror (loudly), READ fails open to mirror
CreditStore.down!(true)
{:degraded, b3} = Proxy.apply_credit_entry(pid2, CreditStore, entry.("d:2", "2.00"))
check.("store-down credit still applies to mirror", Decimal.equal?(b3, Decimal.new("5.00")))
check.("store-down balance read falls back to mirror",
  Decimal.equal?(Proxy.credit_balance(pid2, CreditStore, bi), Decimal.new("5.00")))
CreditStore.down!(false)
check.("store recovers: durable value (3.00) served again — mirror kept the rest",
  Decimal.equal?(Proxy.credit_balance(pid2, CreditStore, bi), Decimal.new("3.00")))

# 4. debits are negative entries through the same primitive
{:ok, b4} = Proxy.apply_credit_entry(pid2, CreditStore,
  %{entry.("d:3", "-1.25") | kind: "debit"})
check.("debit entry reduces durable balance", Decimal.equal?(CreditStore.entries_balance(bi), Decimal.new("1.75")))
# Mirror carries the store-down credit (2.00) that never landed durably, so the
# mirror stays 2.00 ahead of the durable ledger: 5.00 (mirror after step 3) - 1.25 = 3.75.
check.("debit returns updated mirror balance", Decimal.equal?(b4, Decimal.new("3.75")))

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_CREDIT_LEDGER: ALL PASS")
else
  IO.puts("LLM_PROXY_CREDIT_LEDGER: FAILED")
  IO.puts("  Failed: #{Enum.join(Enum.reverse(failed), ", ")}")
  System.halt(1)
end
