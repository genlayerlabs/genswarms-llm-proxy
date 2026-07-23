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
check.("repeat call dedups via the mirror seen-set (store's :duplicate branch not required)",
  Proxy.apply_credit_entry(pid2, CreditStore, entry.("d:1", "3.00")) == :duplicate)
check.("balance read prefers durable",
  Decimal.equal?(Proxy.credit_balance(pid2, CreditStore, bi), Decimal.new("3.00")))

# 3. (X4) store down: WRITE fails CLOSED — a durable-store-configured write
# error must NOT apply the mirror, and must release its seen-mark so a later
# redelivery of the SAME idempotency_key (once the store heals) is still a
# genuine retry, not a permanently-swallowed duplicate. This is the spec's
# "credit writes fail CLOSED" ruling, restored after a review flagged the
# prior fail-open-forever behavior as a lose-payment / double-mint risk (the
# hub's redelivery after store recovery would have been swallowed as
# duplicate:true forever, and cross-restart interleavings could double-mint).
CreditStore.down!(true)
result3 = Proxy.apply_credit_entry(pid2, CreditStore, entry.("d:2", "2.00"))
check.("store-down credit write fails CLOSED", result3 == {:error, :store_unavailable})

check.(
  "store-down: mirror NOT applied (stays at 3.00, unchanged — no fail-open credit)",
  Decimal.equal?(Proxy.credit_balance(pid2, CreditStore, bi), Decimal.new("3.00"))
)

CreditStore.down!(false)

check.(
  "store recovers: redelivery of the SAME key ('d:2') is retryable and now succeeds " <>
    "(the failed write did NOT permanently consume the idempotency key)",
  match?({:ok, _}, Proxy.apply_credit_entry(pid2, CreditStore, entry.("d:2", "2.00")))
)

check.(
  "post-recovery: durable balance reflects the retried credit (3.00 + 2.00)",
  Decimal.equal?(CreditStore.entries_balance(bi), Decimal.new("5.00"))
)

check.(
  "post-recovery: mirror matches durable (both credited exactly once)",
  Decimal.equal?(Proxy.credit_balance(pid2, CreditStore, bi), Decimal.new("5.00"))
)

check.(
  "further redelivery of the now-settled key is a TRUE duplicate (the successful " <>
    "write keeps its seen-mark — only the error path releases it)",
  Proxy.apply_credit_entry(pid2, CreditStore, entry.("d:2", "2.00")) == :duplicate
)

# 4. debits are negative entries through the same primitive
{:ok, b4} = Proxy.apply_credit_entry(pid2, CreditStore,
  %{entry.("d:3", "-1.25") | kind: "debit"})
check.("debit entry reduces durable balance", Decimal.equal?(CreditStore.entries_balance(bi), Decimal.new("3.75")))
# Durable and mirror stay in sync now that a store-down credit is never applied
# to only one side: 5.00 (both, post-recovery) - 1.25 = 3.75.
check.("debit returns updated mirror balance", Decimal.equal?(b4, Decimal.new("3.75")))

# 5. restart-replay: a FRESH mirror (nothing seen yet) replaying a key the
# DURABLE store already knows about (e.g. after a process restart) must
# still dedup — this is the scenario the mirror-seen shortcut in step 2
# above never actually exercises (that pid had already seen "d:1" itself).
# Also assert the store is called exactly once: the SECOND replay on the
# same fresh pid must short-circuit via the mirror's own seen-set (now
# marked from the first call) without ever calling the store again.
defmodule KnownKeyStore do
  def reset, do: :persistent_term.put({__MODULE__, :calls}, 0)
  def calls, do: :persistent_term.get({__MODULE__, :calls})

  def llm_credit_balance(_bi), do: {:ok, Decimal.new("0")}

  def record_llm_credit_entry(%{idempotency_key: _key}) do
    :persistent_term.put({__MODULE__, :calls}, calls() + 1)
    {:error, :duplicate}
  end
end

KnownKeyStore.reset()
{:ok, replay_pid} = Proxy.start_state_link()
replay_entry = entry.("already-known-key", "9.00")

replay_result1 = Proxy.apply_credit_entry(replay_pid, KnownKeyStore, replay_entry)
check.("restart-replay: fresh mirror + store already knows the key -> :duplicate",
  replay_result1 == :duplicate)
check.("restart-replay: mirror balance stays 0 (nothing applied)",
  Decimal.equal?(Proxy.credit_balance(replay_pid, KnownKeyStore, bi), Decimal.new("0")))
check.("restart-replay: the store WAS consulted on the first call",
  KnownKeyStore.calls() == 1)

replay_result2 = Proxy.apply_credit_entry(replay_pid, KnownKeyStore, replay_entry)
check.("restart-replay: second replay short-circuits via the now-marked mirror seen-set " <>
         "(no additional store call)",
  replay_result2 == :duplicate and KnownKeyStore.calls() == 1)

# 6. concurrency: N racers with the SAME idempotency_key must credit the
# mirror EXACTLY ONCE, even with no durable store at all (nil-store mode is
# where an unguarded read-then-write race would double-credit — the seen
# check-and-mark must be one atomic Agent message, not two).
{:ok, conc_pid} = Proxy.start_state_link()
conc_entry = entry.("concurrent:1", "7.00")
racers = 25

conc_results =
  1..racers
  |> Enum.map(fn _ -> Task.async(fn -> Proxy.apply_credit_entry(conc_pid, nil, conc_entry) end) end)
  |> Enum.map(&Task.await(&1, 5_000))

conc_oks = Enum.count(conc_results, &match?({:ok, _}, &1))
conc_dups = Enum.count(conc_results, &(&1 == :duplicate))

check.("concurrency: exactly one of #{racers} same-key racers applies", conc_oks == 1)
check.("concurrency: every other racer dedups", conc_dups == racers - 1)
check.("concurrency: mirror credited exactly once — no double-credit",
  Decimal.equal?(Proxy.credit_balance(conc_pid, nil, bi), Decimal.new("7.00")))

# 7. credit_balance/3 falls open to the mirror when the store's read RAISES
# (not just when it returns {:error, _}) — never raises to the caller.
defmodule RaisingBalanceStore do
  def llm_credit_balance(_bi), do: raise("boom")
end

{:ok, raising_pid} = Proxy.start_state_link()
{:ok, _} = Proxy.apply_credit_entry(raising_pid, nil, entry.("raise:1", "4.00"))

check.("credit_balance/3 falls open to the mirror when the store raises (no crash)",
  Decimal.equal?(Proxy.credit_balance(raising_pid, RaisingBalanceStore, bi), Decimal.new("4.00")))

# 8. (B1, I1) durable credits are both-callbacks-or-neither: a store exporting
# only ONE of the two callbacks must be treated as fully absent for the
# credit path — README promises "missing EITHER callback falls back to the
# mirror for both". A store exporting only llm_credit_balance/1 must NOT be
# read from durably (a paying user's mirror top-up must stay visible to the
# gate, not be shadowed by a durable-read-only store reporting 0).
defmodule BalanceOnlyStore do
  def llm_credit_balance(_bi), do: {:ok, Decimal.new("0")}
end

{:ok, balance_only_pid} = Proxy.start_state_link()
balance_only_entry = entry.("balance-only:1", "6.00")

balance_only_result =
  Proxy.apply_credit_entry(balance_only_pid, BalanceOnlyStore, balance_only_entry)

check.(
  "half-pair (balance-only store): apply_credit_entry still succeeds (mirror mode)",
  match?({:ok, _}, balance_only_result)
)

check.(
  "half-pair (balance-only store): credit_balance serves the MIRROR value, " <>
    "not the durable store's 0 — the top-up must be visible to the gate",
  Decimal.equal?(
    Proxy.credit_balance(balance_only_pid, BalanceOnlyStore, bi),
    Decimal.new("6.00")
  )
)

# A store exporting only record_llm_credit_entry/1 must likewise be treated
# as absent — mirror-mode read AND write.
defmodule RecordOnlyStore do
  def record_llm_credit_entry(_entry), do: :ok
end

{:ok, record_only_pid} = Proxy.start_state_link()
record_only_entry = entry.("record-only:1", "8.00")

record_only_result =
  Proxy.apply_credit_entry(record_only_pid, RecordOnlyStore, record_only_entry)

check.(
  "half-pair (record-only store): apply_credit_entry succeeds (mirror mode, " <>
    "durable write NOT attempted despite the store exporting the callback)",
  match?({:ok, _}, record_only_result)
)

check.(
  "half-pair (record-only store): credit_balance serves the mirror value",
  Decimal.equal?(
    Proxy.credit_balance(record_only_pid, RecordOnlyStore, bi),
    Decimal.new("8.00")
  )
)

# 9. (R3-I1) A NONCONFORMING record_llm_credit_entry/1 return VALUE (the
# single most likely host-adapter slip: forwarding Repo.insert/1's
# `{:ok, struct}` — a write that actually SUCCEEDED) must NOT raise
# CaseClauseError out of apply_credit_entry/3. Pre-fix it did, permanently
# leaking the seen-mark (redelivery acked :duplicate while the mirror balance
# was never applied — a success-shaped lost payment). Now it is treated as a
# failed write: no raise, {:error, :store_unavailable}, mirror untouched,
# seen-mark RELEASED. Self-converging: since the nonconforming write landed,
# the store's own uniqueness answers {:error, :duplicate} on the healed
# redelivery and the entry settles exactly once (durable-first reads serve
# the real balance).
defmodule NonconformingStore do
  def reset do
    :persistent_term.put({__MODULE__, :d}, %{
      balances: %{},
      keys: MapSet.new(),
      nonconforming: true
    })
  end

  defp d, do: :persistent_term.get({__MODULE__, :d})
  defp put(m), do: :persistent_term.put({__MODULE__, :d}, m)
  def heal!, do: put(%{d() | nonconforming: false})
  def entries_balance(bi), do: Map.get(d().balances, bi, Decimal.new("0"))
  def entry_count, do: MapSet.size(d().keys)

  def llm_credit_balance(bi), do: {:ok, entries_balance(bi)}

  def record_llm_credit_entry(%{idempotency_key: key, budget_identity: bi, amount_usd: amt}) do
    if MapSet.member?(d().keys, key) do
      {:error, :duplicate}
    else
      # The write LANDS (Ecto's {:ok, struct} means insert succeeded) …
      put(%{
        d()
        | keys: MapSet.put(d().keys, key),
          balances: Map.update(d().balances, bi, amt, &Decimal.add(&1, amt))
      })

      # … but the adapter forwards a nonconforming shape while unhealed.
      if d().nonconforming, do: {:ok, %{id: 1}}, else: :ok
    end
  end
end

NonconformingStore.reset()
{:ok, nc_pid} = Proxy.start_state_link()
nc_entry = entry.("nc:1", "5.00")

nc_result =
  try do
    Proxy.apply_credit_entry(nc_pid, NonconformingStore, nc_entry)
  rescue
    e -> {:raised, e.__struct__}
  end

check.(
  "nonconforming return ({:ok, struct}): no raise, treated as store failure " <>
    "({:error, :store_unavailable})",
  nc_result == {:error, :store_unavailable}
)

check.(
  "nonconforming return: mirror NOT applied (balance stays 0)",
  Decimal.equal?(Proxy.credit_balance(nc_pid, nil, bi), Decimal.new("0"))
)

NonconformingStore.heal!()

check.(
  "nonconforming return: seen-mark was RELEASED — the healed redelivery reaches the " <>
    "store again and its uniqueness contract answers :duplicate (the landed write wins)",
  Proxy.apply_credit_entry(nc_pid, NonconformingStore, nc_entry) == :duplicate
)

check.(
  "nonconforming return: the entry settled EXACTLY once durably (one key, 5.00)",
  NonconformingStore.entry_count() == 1 and
    Decimal.equal?(NonconformingStore.entries_balance(bi), Decimal.new("5.00"))
)

check.(
  "nonconforming return: durable-first read serves the landed balance (5.00) — " <>
    "the payment converges, never silently lost",
  Decimal.equal?(Proxy.credit_balance(nc_pid, NonconformingStore, bi), Decimal.new("5.00"))
)

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_CREDIT_LEDGER: ALL PASS")
else
  IO.puts("LLM_PROXY_CREDIT_LEDGER: FAILED")
  IO.puts("  Failed: #{Enum.join(Enum.reverse(failed), ", ")}")
  System.halt(1)
end
