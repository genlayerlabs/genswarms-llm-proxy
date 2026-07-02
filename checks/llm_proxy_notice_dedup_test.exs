# LLM proxy budget-notice de-duplication (Task 4). Standalone — NO Postgres, NO network.
#
#   mix run tests/llm_proxy_notice_dedup_test.exs
#
# Tests that budget-exhausted Telegram notices are de-duplicated to at most one
# per (budget_identity, UTC day) per proxy process lifetime.  Five cases:
#
#   1. Dedup    — ≥5 blocked calls → exactly 1 slot_reply notice; block metric fires 5×,
#                 notified metric fires 1×; synthetic 200 returned for every call.
#   2. Direct   — notice_once?/3 returns true then false for the same (bid, day).
#   3. Concur   — 30 concurrent blocked calls → exactly 1 notice (atomic Agent CAS).
#   4. Restart  — fresh pid re-notifies (non-durable by design).
#   5. Prune    — day-D entry is dropped from the set when day_D+1 is first seen.

Application.ensure_all_started(:plug)


alias Genswarms.LlmProxy, as: Proxy
alias Genswarms.LlmProxy.Plug, as: ProxyPlug

import Plug.Test
import Plug.Conn, only: [put_req_header: 3]

{:ok, failures} = Agent.start_link(fn -> [] end)

check = fn label, ok ->
  if ok do
    IO.puts("  ok   #{label}")
  else
    IO.puts("  FAIL #{label}")
    Agent.update(failures, &[label | &1])
  end
end

# ── Fake store: returns a pre-seeded exhausted budget; never records blocked calls ──
#
# budget_exhausted_response does NOT call record_budget_call / record_llm_call, so the
# record path is a no-op here. llm_budget_status must return an exhausted row each time.

defmodule LLM.DedupeTestStore do
  @name __MODULE__

  def start_link do
    case Agent.start_link(fn -> %{} end, name: @name) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      err -> err
    end
  end

  def seed(identity, day, spent \\ "0.30", limit \\ "0.01") do
    Agent.update(@name, fn state ->
      Map.put(state, {identity, day}, %{
        budget_identity: identity,
        day: day,
        session_id: "seed",
        spent_usd: Decimal.new(to_string(spent)),
        limit_usd: Decimal.new(to_string(limit)),
        requests: 1,
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0
      })
    end)
  end

  def llm_budget_status(identity, day, session_id, _default_limit) do
    Agent.get(@name, fn state ->
      case Map.get(state, {identity, day}) do
        nil -> nil
        row -> %{row | session_id: session_id}
      end
    end)
  end

  # Blocked calls never reach respond_upstream, so record_llm_call is never invoked
  # for any call in this test file. Provide the callback for completeness.
  def record_llm_call(_identity, _day, _session_id, _attrs), do: %{}
end

{:ok, _} = LLM.DedupeTestStore.start_link()

# ── Shared delivery + metrics capture ────────────────────────────────────────
#
# deliver_fn is called both for Telegram notices (to: :sender) and for metric bumps
# (to: :metrics_cap). Tag by `to` to separate them.

{:ok, captured} = Agent.start_link(fn -> [] end)

build_deliver_fn = fn ->
  fn _swarm, to, _from, content ->
    decoded = Jason.decode!(content)
    Agent.update(captured, &[{to, decoded} | &1])
    :ok
  end
end

slot_replies = fn ->
  Agent.get(captured, fn msgs ->
    msgs
    |> Enum.filter(fn {to, msg} -> to == :sender and msg["action"] == "slot_reply" end)
    |> Enum.map(fn {_to, msg} -> msg end)
    |> Enum.reverse()
  end)
end

metric_keys = fn ->
  Agent.get(captured, fn msgs ->
    msgs
    |> Enum.filter(fn {to, msg} -> to == :metrics_cap and msg["action"] == "bump" end)
    |> Enum.map(fn {_to, msg} -> msg["key"] end)
    |> Enum.reverse()
  end)
end

reset_captured = fn ->
  Agent.update(captured, fn _ -> [] end)
end

# ── Common test date ──────────────────────────────────────────────────────────

today = ~D[2026-06-27]

# ── Helper: build a Plug.Test conn for a budget-blocked request ───────────────

make_blocked_conn = fn state_pid, token, deliver_fn ->
  opts = %{
    state_pid: state_pid,
    upstream_endpoint: "https://llm.example/v1/chat/completions",
    upstream_api_key: "test-key",
    provider: "unit",
    prices: %{},
    store_mod: LLM.DedupeTestStore,
    clock: fn -> ~U[2026-06-27 12:00:00Z] end,
    swarm_name: "wingston",
    sender: :sender,
    deliver_fn: deliver_fn,
    metrics: :metrics_cap
  }

  body = Jason.encode!(%{"model" => "test", "messages" => []})

  conn(:post, "/v1/chat/completions", body)
  |> put_req_header("authorization", "Bearer #{token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(opts))
end

# ────────────────────────────────────────────────────────────────────────────
# Test 2: notice_once?/3 — direct API, no Plug
# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Test 2: notice_once?/3 direct]")

{:ok, nc_pid} = Proxy.start_state_link()

check.(
  "notice_once?/3 returns true on first call for a (bid, day) pair",
  Proxy.notice_once?(nc_pid, "bid-A", today) == true
)

check.(
  "notice_once?/3 returns false on second call for same (bid, day)",
  Proxy.notice_once?(nc_pid, "bid-A", today) == false
)

check.(
  "notice_once?/3 continues to return false on additional calls",
  Proxy.notice_once?(nc_pid, "bid-A", today) == false
)

check.(
  "notice_once?/3 returns true for a different bid on the same day",
  Proxy.notice_once?(nc_pid, "bid-B", today) == true
)

Agent.stop(nc_pid)

# ────────────────────────────────────────────────────────────────────────────
# Test 4: Restart — non-durable (fresh process re-notifies)
# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Test 4: restart non-durable]")

{:ok, pid1} = Proxy.start_state_link()

check.(
  "notice_once? returns true on pid1 for (bid-restart, today)",
  Proxy.notice_once?(pid1, "bid-restart", today) == true
)

check.(
  "notice_once? returns false on second call on same pid1",
  Proxy.notice_once?(pid1, "bid-restart", today) == false
)

Agent.stop(pid1)
{:ok, pid2} = Proxy.start_state_link()

check.(
  "notice_once? returns true again on fresh pid2 — non-durable restart re-notifies",
  Proxy.notice_once?(pid2, "bid-restart", today) == true
)

Agent.stop(pid2)

# ────────────────────────────────────────────────────────────────────────────
# Test 5: Prune boundary — day-D entry removed when day_D+1 call is processed
# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Test 5: prune boundary]")

{:ok, pp_pid} = Proxy.start_state_link()
day_d = ~D[2026-06-27]
day_d_plus_1 = ~D[2026-06-28]

# First call on day_d — populates notified with {bid-prune, day_d}
Proxy.notice_once?(pp_pid, "bid-prune", day_d)

# Call with a different bid on day_d+1 — prune filters OUT day_d entries
Proxy.notice_once?(pp_pid, "bid-prune-2", day_d_plus_1)

notified_set = Agent.get(pp_pid, fn state -> Map.get(state, :notified, MapSet.new()) end)

check.(
  "prune: after day_D+1 call, the day_D entry is removed from the notified set",
  not MapSet.member?(notified_set, {"bid-prune", day_d}) and
    MapSet.member?(notified_set, {"bid-prune-2", day_d_plus_1})
)

check.(
  "prune: notified set has exactly one entry (day_D+1 key only)",
  MapSet.size(notified_set) == 1
)

Agent.stop(pp_pid)

# ────────────────────────────────────────────────────────────────────────────
# Test 1: Dedup — exactly one notice across 5+ budget-blocked calls
# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Test 1: dedup across 5 blocked calls]")

reset_captured.()
{:ok, state1} = Proxy.start_state_link()

dedup_attrs = %{
  conversation_id: "tg:dedup:0",
  slot: :agent_dedup,
  kind: :dm,
  workspace_key: "default",
  daily_limit_usd: "0.01"
}

dedup_identity = Proxy.budget_identity(dedup_attrs)
{:ok, dedup_token} = Proxy.register_session(state1, dedup_attrs)

# Seed: spent ($0.30) well above limit ($0.01) — all calls are budget-blocked.
LLM.DedupeTestStore.seed(dedup_identity, today)

deliver_fn1 = build_deliver_fn.()

# Make 5 blocked calls; each must still return a synthetic 200.
conns1 =
  for _ <- 1..5 do
    make_blocked_conn.(state1, dedup_token, deliver_fn1)
  end

replies1 = slot_replies.()
metrics1 = metric_keys.()

check.(
  "dedup: all 5 blocked calls return HTTP 200",
  Enum.all?(conns1, &(&1.status == 200))
)

check.(
  "dedup: exactly one slot_reply notice delivered across 5 blocked calls",
  length(replies1) == 1
)

check.(
  "dedup: the single notice content contains 'daily LLM limit'",
  case replies1 do
    [%{"content" => content}] -> String.contains?(content, "daily LLM limit")
    _ -> false
  end
)

check.(
  "dedup: llm_proxy_budget_block fired 5 times (every blocked call)",
  Enum.count(metrics1, &(&1 == "llm_proxy_budget_block")) == 5
)

check.(
  "dedup: llm_proxy_budget_block_notified fired exactly once",
  Enum.count(metrics1, &(&1 == "llm_proxy_budget_block_notified")) == 1
)

# Synthetic response body must reflect budget exhaustion on every call.
check.(
  "dedup: synthetic 200 bodies all carry budget_exhausted: true",
  Enum.all?(conns1, fn c ->
    body = Jason.decode!(c.resp_body)
    get_in(body, ["x_router", "budget_exhausted"]) == true
  end)
)

Agent.stop(state1)

# ────────────────────────────────────────────────────────────────────────────
# Test 3: Concurrency — 30 concurrent blocked calls → exactly one notice
# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Test 3: 30-way concurrency → exactly one notice]")

reset_captured.()
{:ok, state3} = Proxy.start_state_link()

conc_attrs = %{
  conversation_id: "tg:conc:0",
  slot: :agent_conc,
  kind: :dm,
  workspace_key: "default",
  daily_limit_usd: "0.01"
}

conc_identity = Proxy.budget_identity(conc_attrs)
{:ok, conc_token} = Proxy.register_session(state3, conc_attrs)

LLM.DedupeTestStore.seed(conc_identity, today)

deliver_fn3 = build_deliver_fn.()

conc_opts = %{
  state_pid: state3,
  upstream_endpoint: "https://llm.example/v1/chat/completions",
  upstream_api_key: "test-key",
  provider: "unit",
  prices: %{},
  store_mod: LLM.DedupeTestStore,
  clock: fn -> ~U[2026-06-27 12:00:00Z] end,
  swarm_name: "wingston",
  sender: :sender,
  deliver_fn: deliver_fn3,
  metrics: :metrics_cap
}

body_json = Jason.encode!(%{"model" => "test", "messages" => []})

tasks =
  for _ <- 1..30 do
    Task.async(fn ->
      conn(:post, "/v1/chat/completions", body_json)
      |> put_req_header("authorization", "Bearer #{conc_token}")
      |> put_req_header("content-type", "application/json")
      |> ProxyPlug.call(ProxyPlug.init(conc_opts))
    end)
  end

conc_results = Task.await_many(tasks, 5_000)

conc_replies = slot_replies.()
conc_metrics = metric_keys.()

check.(
  "concurrency: all 30 calls returned HTTP 200",
  Enum.all?(conc_results, &(&1.status == 200))
)

check.(
  "concurrency: exactly ONE slot_reply delivered across 30 concurrent blocked calls",
  length(conc_replies) == 1
)

check.(
  "concurrency: llm_proxy_budget_block fired 30 times (every blocked call)",
  Enum.count(conc_metrics, &(&1 == "llm_proxy_budget_block")) == 30
)

check.(
  "concurrency: llm_proxy_budget_block_notified fired exactly once",
  Enum.count(conc_metrics, &(&1 == "llm_proxy_budget_block_notified")) == 1
)

Agent.stop(state3)

# ─────────────────────────────────────────────────────────────────────────────

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_NOTICE_DEDUP: ALL PASS")
else
  IO.puts("LLM_PROXY_NOTICE_DEDUP: FAILED")
  for f <- Enum.reverse(failed), do: IO.puts("  FAIL #{f}")
  System.halt(1)
end
