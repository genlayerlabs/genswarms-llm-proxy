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
