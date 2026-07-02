# In-memory operator-wide spend accumulation for the GLOBAL daily cost ceiling — the
# PG-independent backstop that holds the cap even when Postgres is down (the per-conversation
# budget fails open on a PG outage). Standalone — NO Postgres, NO network.
#
#   mix run tests/llm_proxy_global_ceiling_test.exs

repo_root = Path.expand(Path.join(__DIR__, ".."))

alias Genswarms.LlmProxy, as: Proxy

{:ok, failures} = Agent.start_link(fn -> [] end)
check = fn label, ok ->
  IO.puts((ok && "  ok   ") <> label)
  unless ok, do: Agent.update(failures, &[label | &1])
end

{:ok, pid} = Proxy.start_state_link([])
d = ~D[2026-06-28]
d2 = ~D[2026-06-29]
sess = fn id -> %{budget_identity: id, slot: "wingston_agent_0"} end
rec = fn id, cost -> Proxy.record_usage(pid, sess.(id), d, id, %{model: "m", status: "ok", cost_usd: cost}) end
eq = fn a, b -> Decimal.equal?(a, b) end

# unseen day → 0
check.("global_spent_inmem is 0 for a day with no spend", eq.(Proxy.global_spent_inmem(pid, d), Decimal.new("0")))

# accumulates ACROSS conversations (the whole point — per-conv budgets don't bound aggregate)
rec.("conv-a", "0.10")
rec.("conv-b", "0.05")
rec.("conv-a", "0.02")
check.("global_spent_inmem accumulates across all conversations for the day (0.17)",
  eq.(Proxy.global_spent_inmem(pid, d), Decimal.new("0.17")))

# a zero-cost (free model) call doesn't move it
rec.("conv-c", "0")
check.("a $0 call leaves the global total unchanged (0.17)",
  eq.(Proxy.global_spent_inmem(pid, d), Decimal.new("0.17")))

# day rollover: recording a new day prunes the old day's accumulator (per-UTC-day ceiling)
Proxy.record_usage(pid, sess.("conv-d"), d2, "conv-d", %{model: "m", status: "ok", cost_usd: "0.20"})
check.("a new UTC day prunes the prior day's in-memory total to 0", eq.(Proxy.global_spent_inmem(pid, d), Decimal.new("0")))
check.("the new day accumulates independently (0.20)", eq.(Proxy.global_spent_inmem(pid, d2), Decimal.new("0.20")))

fails = Agent.get(failures, & &1)
if fails == [] do
  IO.puts("\nLLM_PROXY_GLOBAL_CEILING: ALL PASS")
else
  IO.puts("\nLLM_PROXY_GLOBAL_CEILING: #{length(fails)} FAILED")
  System.halt(1)
end
