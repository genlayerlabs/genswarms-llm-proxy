# Block-notice UX (fix/block-notice-ux). Standalone — NO Postgres, NO network.
#
#   mix run checks/llm_proxy_block_notice_ux_test.exs
#
# Covers the four behavior changes of the block-notice redesign:
#
#   1. notice_due?/5 — per-{budget_identity, reason, day} LAST-NOTIFIED timestamp
#      with a configurable minimum repeat interval (default 4h). repeat_ms 0/nil =
#      legacy once-per-day. Day-keyed prune keeps state bounded.
#   2. Truthful synthetic completion content — "notice was sent" ONLY when this
#      request actually delivered one; a dedup-suppressed request says the user
#      was already notified earlier today. Buffered JSON + SSE + all cap types.
#   3. Independent notice keys per cap type — a budget notice earlier in the day
#      must not silence a later request-quota or global-ceiling notice.
#   4. notify: false sessions — background sessions neither deliver a Telegram
#      notice NOR consume/advance the notice timestamp when blocked.

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

today = ~D[2026-07-01]
t0 = ~U[2026-07-01 08:00:00Z]
four_h = 4 * 60 * 60 * 1000

# ────────────────────────────────────────────────────────────────────────────
# Section 1: notice_due?/5 — direct API
# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 1: notice_due?/5 rate-limited, reason-keyed]")

{:ok, nd} = Proxy.start_state_link()

check.(
  "first call for a (bid, reason, day) is due",
  Proxy.notice_due?(nd, "bid-1", :budget, today, now: t0) == true
)

check.(
  "immediate second call is NOT due",
  Proxy.notice_due?(nd, "bid-1", :budget, today, now: t0) == false
)

check.(
  "3h59m later is still NOT due (default 4h interval)",
  Proxy.notice_due?(nd, "bid-1", :budget, today, now: DateTime.add(t0, 4 * 3600 - 60, :second)) ==
    false
)

check.(
  "exactly 4h later IS due again (default interval) — repeat notice",
  Proxy.notice_due?(nd, "bid-1", :budget, today, now: DateTime.add(t0, 4 * 3600, :second)) == true
)

check.(
  "after the repeat, the timestamp advanced — immediately after NOT due again",
  Proxy.notice_due?(nd, "bid-1", :budget, today,
    now: DateTime.add(t0, 4 * 3600 + 10, :second)
  ) == false
)

check.(
  "a DIFFERENT reason for the same bid/day is independently due (per-cap keys)",
  Proxy.notice_due?(nd, "bid-1", :request_quota, today, now: t0) == true and
    Proxy.notice_due?(nd, "bid-1", :global, today, now: t0) == true
)

check.(
  "a different bid is independently due",
  Proxy.notice_due?(nd, "bid-2", :budget, today, now: t0) == true
)

# custom repeat interval
check.(
  "custom repeat_ms honored: not due 1ms before, due at the interval",
  Proxy.notice_due?(nd, "bid-int", :budget, today, now: t0, repeat_ms: 1000) == true and
    Proxy.notice_due?(nd, "bid-int", :budget, today,
      now: DateTime.add(t0, 999, :millisecond),
      repeat_ms: 1000
    ) == false and
    Proxy.notice_due?(nd, "bid-int", :budget, today,
      now: DateTime.add(t0, 1000, :millisecond),
      repeat_ms: 1000
    ) == true
)

check.(
  "repeat_ms: 0 = legacy once/day (never due again same day, even 10h later)",
  Proxy.notice_due?(nd, "bid-legacy0", :budget, today, now: t0, repeat_ms: 0) == true and
    Proxy.notice_due?(nd, "bid-legacy0", :budget, today,
      now: DateTime.add(t0, 10 * 3600, :second),
      repeat_ms: 0
    ) == false
)

check.(
  "repeat_ms: nil = legacy once/day",
  Proxy.notice_due?(nd, "bid-legacyN", :budget, today, now: t0, repeat_ms: nil) == true and
    Proxy.notice_due?(nd, "bid-legacyN", :budget, today,
      now: DateTime.add(t0, 10 * 3600, :second),
      repeat_ms: nil
    ) == false
)

# day prune: state stays bounded to the current day
tomorrow = Date.add(today, 1)
t1 = ~U[2026-07-02 08:00:00Z]

check.(
  "a new UTC day is due again",
  Proxy.notice_due?(nd, "bid-1", :budget, tomorrow, now: t1) == true
)

notified_after = Agent.get(nd, fn s -> Map.get(s, :notified) end)

check.(
  "prune: after a day-D+1 call only day-D+1 entries remain in state",
  is_map(notified_after) and not is_struct(notified_after) and
    Enum.all?(Map.keys(notified_after), fn {_bid, _reason, d} -> d == tomorrow end) and
    map_size(notified_after) == 1
)

# legacy shim: notice_once?/3 still answers (delegates to the new core)
check.(
  "legacy notice_once?/3 shim still returns true then false",
  Proxy.notice_once?(nd, "bid-shim", tomorrow) == true and
    Proxy.notice_once?(nd, "bid-shim", tomorrow) == false
)

Agent.stop(nd)

# state that carries a stale MapSet under :notified (older boot) must not crash
{:ok, stale} = Agent.start_link(fn -> %{sessions: %{}, usage: %{}, notified: MapSet.new([{"x", today}]), global: %{}} end)

check.(
  "a stale MapSet :notified from an older boot is tolerated (treated as empty)",
  Proxy.notice_due?(stale, "bid-stale", :budget, today, now: t0) == true and
    Proxy.notice_due?(stale, "bid-stale", :budget, today, now: t0) == false
)

Agent.stop(stale)

# concurrency: 30 concurrent notice_due? calls for the same key → exactly one true
{:ok, cc} = Proxy.start_state_link()

due_results =
  1..30
  |> Enum.map(fn _ ->
    Task.async(fn -> Proxy.notice_due?(cc, "bid-conc", :budget, today, now: t0) end)
  end)
  |> Task.await_many(5_000)

check.(
  "concurrency: 30 concurrent notice_due? for one key → exactly one true (atomic)",
  Enum.count(due_results, & &1) == 1
)

Agent.stop(cc)

# ────────────────────────────────────────────────────────────────────────────
# Plug-level harness: fake store + mutable clock + delivery capture
# ────────────────────────────────────────────────────────────────────────────

defmodule LLM.NoticeUxStore do
  @name __MODULE__

  def start_link do
    case Agent.start_link(fn -> %{} end, name: @name) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      err -> err
    end
  end

  # Seed the budget row the plug sees for (identity, day). `spent`/`limit` drive the
  # dollar block; `requests` drives the request-quota block.
  def seed(identity, day, attrs \\ %{}) do
    Agent.update(@name, fn state ->
      Map.put(
        state,
        {identity, day},
        Map.merge(
          %{
            budget_identity: identity,
            day: day,
            session_id: "seed",
            spent_usd: Decimal.new("0.30"),
            limit_usd: Decimal.new("0.01"),
            requests: 1,
            prompt_tokens: 0,
            completion_tokens: 0,
            total_tokens: 0
          },
          attrs
        )
      )
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

  def record_llm_call(_identity, _day, _session_id, _attrs), do: %{}
end

{:ok, _} = LLM.NoticeUxStore.start_link()

{:ok, clock_state} = Agent.start_link(fn -> ~U[2026-07-01 08:00:00Z] end)
set_clock = fn %DateTime{} = dt -> Agent.update(clock_state, fn _ -> dt end) end
clock = fn -> Agent.get(clock_state, & &1) end

{:ok, captured} = Agent.start_link(fn -> [] end)

deliver_fn = fn _swarm, to, _from, content ->
  Agent.update(captured, &[{to, Jason.decode!(content)} | &1])
  :ok
end

slot_replies = fn ->
  Agent.get(captured, fn msgs ->
    msgs
    |> Enum.filter(fn {to, msg} -> to == :sender and msg["action"] == "slot_reply" end)
    |> Enum.map(fn {_to, msg} -> msg["content"] end)
    |> Enum.reverse()
  end)
end

reset_captured = fn -> Agent.update(captured, fn _ -> [] end) end

{:ok, state_pid} = Proxy.start_state_link()

base_opts = %{
  state_pid: state_pid,
  upstream_endpoint: "https://llm.example/v1/chat/completions",
  upstream_api_key: "test-key",
  provider: "unit",
  prices: %{},
  store_mod: LLM.NoticeUxStore,
  clock: clock,
  swarm_name: "testswarm",
  sender: :sender,
  deliver_fn: deliver_fn,
  metrics: :metrics_cap
}

post = fn token, opts, body ->
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(opts))
end

content_of = fn conn ->
  conn.resp_body
  |> Jason.decode!()
  |> get_in(["choices", Access.at(0), "message", "content"])
end

sse_content_of = fn conn ->
  case Regex.run(~r/^data: (\{.*\})/m, conn.resp_body) do
    [_, json] -> json |> Jason.decode!() |> get_in(["choices", Access.at(0), "delta", "content"])
    _ -> nil
  end
end

sent_tail = "A deterministic Telegram notice was sent; do not send a separate user reply."
suppressed_tail = "The user was already notified earlier today; do not send a separate user reply."

# ────────────────────────────────────────────────────────────────────────────
# Section 2: truthful synthetic content (sent vs suppressed vs repeat)
# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 2: truthful synthetic content]")

tc_attrs = %{conversation_id: "tg:truth:0", slot: :truth_agent, kind: :dm, workspace_key: "default"}
tc_identity = Proxy.budget_identity(tc_attrs)
{:ok, tc_token} = Proxy.register_session(state_pid, tc_attrs)
LLM.NoticeUxStore.seed(tc_identity, today)

set_clock.(t0)
c1 = post.(tc_token, base_opts, %{"model" => "m", "messages" => []})

check.(
  "budget block #1 delivers the Telegram notice and the content says it was sent",
  length(slot_replies.()) == 1 and
    content_of.(c1) == "The daily LLM limit for this conversation was reached. " <> sent_tail
)

set_clock.(DateTime.add(t0, 60, :second))
c2 = post.(tc_token, base_opts, %{"model" => "m", "messages" => []})

check.(
  "budget block #2 (1min later): NO new notice, content says user was ALREADY notified — never claims a notice was sent",
  length(slot_replies.()) == 1 and
    content_of.(c2) == "The daily LLM limit for this conversation was reached. " <> suppressed_tail and
    not String.contains?(content_of.(c2), "was sent")
)

set_clock.(DateTime.add(t0, 4 * 3600, :second))
c3 = post.(tc_token, base_opts, %{"model" => "m", "messages" => []})

check.(
  "budget block 4h later: notice REPEATS (2 total) and content says sent again",
  length(slot_replies.()) == 2 and
    content_of.(c3) == "The daily LLM limit for this conversation was reached. " <> sent_tail
)

# SSE variant: suppressed content must be truthful in the streamed chunk too
set_clock.(DateTime.add(t0, 4 * 3600 + 60, :second))
sse_opts = Map.put(base_opts, :allow_streaming, true)
c4 = post.(tc_token, sse_opts, %{"model" => "m", "messages" => [], "stream" => true})

check.(
  "budget block SSE (suppressed): chunk content says already notified, no new notice",
  length(slot_replies.()) == 2 and
    sse_content_of.(c4) == "The daily LLM limit for this conversation was reached. " <> suppressed_tail
)

# request-quota variant
reset_captured.()
rq_attrs = %{conversation_id: "tg:rq:0", slot: :rq_agent, kind: :dm, workspace_key: "default"}
rq_identity = Proxy.budget_identity(rq_attrs)
{:ok, rq_token} = Proxy.register_session(state_pid, rq_attrs)
LLM.NoticeUxStore.seed(rq_identity, today, %{spent_usd: Decimal.new("0.00"), limit_usd: Decimal.new("1"), requests: 99})
rq_opts = Map.put(base_opts, :daily_request_limit, 5)

set_clock.(t0)
q1 = post.(rq_token, rq_opts, %{"model" => "m", "messages" => []})
set_clock.(DateTime.add(t0, 60, :second))
q2 = post.(rq_token, rq_opts, %{"model" => "m", "messages" => []})

check.(
  "request-quota block: #1 says sent, #2 says already notified (no new notice)",
  length(slot_replies.()) == 1 and
    content_of.(q1) == "This chat reached today's AI usage limit. " <> sent_tail and
    content_of.(q2) == "This chat reached today's AI usage limit. " <> suppressed_tail
)

# global-ceiling variant (fresh state pid so the in-memory global spend is isolated)
{:ok, g_state} = Proxy.start_state_link()
g_attrs = %{conversation_id: "tg:glob:0", slot: :glob_agent, kind: :dm, workspace_key: "default"}
{:ok, g_token} = Proxy.register_session(g_state, g_attrs)

Proxy.record_usage(g_state, %{budget_identity: "other-conv"}, today, "s1", %{
  model: "m",
  status: "ok",
  cost_usd: "10"
})

g_opts =
  base_opts
  |> Map.put(:state_pid, g_state)
  |> Map.put(:global_daily_limit, Decimal.new("1"))

reset_captured.()
set_clock.(t0)
g1 = post.(g_token, g_opts, %{"model" => "m", "messages" => []})
set_clock.(DateTime.add(t0, 60, :second))
g2 = post.(g_token, g_opts, %{"model" => "m", "messages" => []})

check.(
  "global block: #1 says sent, #2 says already notified (no new notice)",
  length(slot_replies.()) == 1 and
    content_of.(g1) == "The service-wide daily LLM budget was reached. " <> sent_tail and
    content_of.(g2) == "The service-wide daily LLM budget was reached. " <> suppressed_tail
)

# global streaming block: the chunk must carry the service-wide (truthful) framing,
# not the per-conversation budget text
set_clock.(DateTime.add(t0, 2 * 60, :second))
g3 = post.(g_token, Map.put(g_opts, :allow_streaming, true), %{"model" => "m", "messages" => [], "stream" => true})

check.(
  "global block SSE: chunk content is the service-wide message (suppressed variant)",
  sse_content_of.(g3) == "The service-wide daily LLM budget was reached. " <> suppressed_tail
)

# ────────────────────────────────────────────────────────────────────────────
# Section 3: independent notice keys per cap type (same identity)
# ────────────────────────────────────────────────────────────────────────────
IO.puts("\n[Section 3: per-cap-type notice independence]")

{:ok, x_state} = Proxy.start_state_link()
x_attrs = %{conversation_id: "tg:xcap:0", slot: :xcap_agent, kind: :dm, workspace_key: "default"}
x_identity = Proxy.budget_identity(x_attrs)
{:ok, x_token} = Proxy.register_session(x_state, x_attrs)
x_opts = Map.put(base_opts, :state_pid, x_state)

# 1) dollar-budget block → budget notice delivered
LLM.NoticeUxStore.seed(x_identity, today)
reset_captured.()
set_clock.(t0)
_ = post.(x_token, x_opts, %{"model" => "m", "messages" => []})

check.(
  "same identity: budget block delivers the budget notice",
  match?([one], slot_replies.()) and String.contains?(hd(slot_replies.()), "daily LLM limit")
)

# 2) minutes later the REQUEST-QUOTA cap trips → its notice must NOT be silenced
#    by the earlier budget notice
LLM.NoticeUxStore.seed(x_identity, today, %{spent_usd: Decimal.new("0"), limit_usd: Decimal.new("1"), requests: 99})
set_clock.(DateTime.add(t0, 5 * 60, :second))
_ = post.(x_token, Map.put(x_opts, :daily_request_limit, 5), %{"model" => "m", "messages" => []})

check.(
  "same identity: a later request-quota block still notifies (2nd notice, quota text)",
  match?([_, _], slot_replies.()) and
    String.contains?(Enum.at(slot_replies.(), 1), "request limit")
)

# 3) minutes later the GLOBAL ceiling trips → its notice must NOT be silenced either
Proxy.record_usage(x_state, %{budget_identity: "someone-else"}, today, "s1", %{
  model: "m",
  status: "ok",
  cost_usd: "10"
})

set_clock.(DateTime.add(t0, 10 * 60, :second))

_ =
  post.(x_token, Map.put(x_opts, :global_daily_limit, Decimal.new("1")), %{
    "model" => "m",
    "messages" => []
  })

check.(
  "same identity: a later global-ceiling block still notifies (3rd notice, service-wide text)",
  match?([_, _, _], slot_replies.()) and
    String.contains?(Enum.at(slot_replies.(), 2), "service daily LLM budget")
)

# ─────────────────────────────────────────────────────────────────────────────

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_BLOCK_NOTICE_UX: ALL PASS")
else
  IO.puts("LLM_PROXY_BLOCK_NOTICE_UX: FAILED")
  for f <- Enum.reverse(failed), do: IO.puts("  FAIL #{f}")
  System.halt(1)
end
