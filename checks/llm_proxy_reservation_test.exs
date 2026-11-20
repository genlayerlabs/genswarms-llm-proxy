# Admission reservations: the gate must see what is IN FLIGHT, not only what the
# store has recorded, and every request sent upstream must burn the request
# quota whatever its outcome. Drives the plug with a stub upstream and an
# in-memory store. Standalone — NO Postgres, NO network.
#
#   mix run checks/llm_proxy_reservation_test.exs

Application.ensure_all_started(:plug)

alias Genswarms.LlmProxy, as: Proxy
alias Genswarms.LlmProxy.Plug, as: ProxyPlug
import Plug.Test
import Plug.Conn, only: [put_req_header: 3]

defmodule ReservationStore do
  # Same shape as a host store: `requests` only counts status "ok" rows.
  @name __MODULE__
  def start_link, do: Agent.start_link(fn -> %{} end, name: @name)
  def reset, do: Agent.update(@name, fn _ -> %{} end)
  defp dec(%Decimal{} = v), do: v
  defp dec(v), do: Decimal.new(to_string(v))

  defp blank(id, day, sid, limit),
    do: %{budget_identity: id, day: day, session_id: sid, spent_usd: Decimal.new("0"),
          limit_usd: dec(limit), requests: 0, prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  def llm_usage_today(day) do
    Agent.get(@name, fn s ->
      %{spent_usd:
          s |> Enum.filter(fn {{_, d}, _} -> d == day end)
            |> Enum.reduce(Decimal.new("0"), fn {_, r}, a -> Decimal.add(a, r.spent_usd) end)}
    end)
  end

  def llm_budget_status(id, day, sid, limit) do
    Agent.get_and_update(@name, fn s ->
      row = Map.get(s, {id, day}) || blank(id, day, sid, limit)
      {row, Map.put(s, {id, day}, row)}
    end)
  end

  def record_llm_call(id, day, sid, attrs) do
    Agent.get_and_update(@name, fn s ->
      row = Map.get(s, {id, day}) || blank(id, day, sid, "0.50")
      cost = dec(attrs[:cost_usd] || "0")
      ok? = to_string(attrs[:status] || "ok") == "ok"
      row = %{row | spent_usd: Decimal.add(row.spent_usd, cost), requests: row.requests + if(ok?, do: 1, else: 0)}
      {row, Map.put(s, {id, day}, row)}
    end)
  end

  def usage(id, day), do: Agent.get(@name, &Map.get(&1, {id, day}))
end

{:ok, failures} = Agent.start_link(fn -> [] end)
check = fn label, ok ->
  IO.puts(((ok && "  ok   ") || "  FAIL ") <> label)
  unless ok, do: Agent.update(failures, &[label | &1])
end

{:ok, _} = ReservationStore.start_link()
{:ok, calls} = Agent.start_link(fn -> 0 end)
day = ~D[2026-06-25]
eq = fn a, b -> Decimal.equal?(a, Decimal.new(b)) end

ok_upstream = fn cost ->
  fn _b, _h, _c ->
    Agent.update(calls, &(&1 + 1))
    Process.sleep(200)

    {:ok, 200,
     %{"id" => "stub", "object" => "chat.completion", "created" => 1, "model" => "stub-model",
       "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "pong"}, "finish_reason" => "stop"}],
       "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2},
       "x_router" => %{"cost_usd" => cost}}}
  end
end

counted = fn result -> fn _b, _h, _c -> Agent.update(calls, &(&1 + 1)); result.() end end
timeout_upstream = counted.(fn -> {:error, {:curl, 28}} end)
error_upstream = counted.(fn -> {:error, 500, %{"error" => %{"message" => "boom", "code" => "upstream_500"}}} end)
raising_upstream = counted.(fn -> raise "stub upstream exploded" end)

# A fresh proxy state + store per scenario. Returns the handles a scenario needs.
setup = fn limits ->
  ReservationStore.reset()
  Agent.update(calls, fn _ -> 0 end)
  {:ok, state_pid} = Proxy.start_state_link([])

  opts =
    Map.merge(
      %{
        state_pid: state_pid,
        upstream_endpoint: "https://llm.invalid/v1/chat/completions",
        upstream_api_key: "stub-key",
        provider: "stub",
        prices: %{},
        store_mod: ReservationStore,
        clock: fn -> ~U[2026-06-25 12:00:00Z] end,
        swarm_name: "reservation",
        sender: :sender,
        deliver_fn: fn _, _, _, _ -> :ok end,
        default_daily_limit: Decimal.new("0.50"),
        daily_request_limit: 0,
        global_daily_limit: Decimal.new("0")
      },
      limits
    )

  session = fn name ->
    attrs = %{conversation_id: "tg:reservation:#{name}", slot: "agent_#{name}", kind: :dm, workspace_key: "reservation"}
    {:ok, token} = Proxy.register_session(state_pid, attrs)
    {token, Proxy.budget_identity(attrs)}
  end

  req = fn token, upstream ->
    conn(:post, "/v1/chat/completions", Jason.encode!(%{"model" => "m", "messages" => [%{"role" => "user", "content" => "hi"}]}))
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> ProxyPlug.call(ProxyPlug.init(Map.put(opts, :upstream, upstream)))
  end

  %{state_pid: state_pid, session: session, req: req}
end

sent = fn -> Agent.get(calls, & &1) end
parallel = fn funs -> funs |> Enum.map(&Task.async/1) |> Task.await_many(10_000) end
inflight = fn state_pid -> Agent.get(state_pid, &((Map.get(&1, :gate) || %{inflight: %{}}).inflight)) end

# ── 1. Request quota counts in-flight requests (the reproduced bug) ──────────
s = setup.(%{daily_request_limit: 2, global_daily_limit: Decimal.new("1.00")})
{token, id} = s.session.("burst")
parallel.(for _ <- 1..5, do: fn -> s.req.(token, ok_upstream.(0.40)) end)
u = ReservationStore.usage(id, day)
check.("5 parallel calls, request limit 2: only 2 reach the upstream (got #{sent.()})", sent.() == 2)
check.("5 parallel calls, request limit 2: 2 requests / 0.80 recorded, same as sequential",
  u.requests == 2 and eq.(u.spent_usd, "0.80"))
check.("reservations are released after the burst", inflight.(s.state_pid) == %{})

# ── 2. USD budget counts in-flight calls (no request limit) ──────────────────
s = setup.(%{})
{token, id} = s.session.("usd")
s.req.(token, ok_upstream.(0.10))
parallel.(for _ <- 1..8, do: fn -> s.req.(token, ok_upstream.(0.10)) end)
u = ReservationStore.usage(id, day)
check.("8 parallel 0.10 calls at 0.10/0.50 spent: 4 admitted, like sequential (got #{sent.() - 1})", sent.() == 5)
check.("parallel spend stays within the limit plus one call (spent #{u.spent_usd})",
  Decimal.compare(u.spent_usd, Decimal.new("0.60")) != :gt)

# ── 3. Global ceiling counts in-flight calls across identities ───────────────
s = setup.(%{default_daily_limit: Decimal.new("5.00"), global_daily_limit: Decimal.new("0.30")})
{first, _} = s.session.("g0")
s.req.(first, ok_upstream.(0.10))
tokens = for n <- 1..6, do: elem(s.session.("g#{n}"), 0)
parallel.(for t <- tokens, do: fn -> s.req.(t, ok_upstream.(0.10)) end)
check.("6 parallel identities at 0.10/0.30 global: 2 admitted, like sequential (got #{sent.() - 1})", sent.() == 3)
check.("global spend stays within the ceiling plus one call",
  Decimal.compare(Proxy.global_spent_inmem(s.state_pid, day), Decimal.new("0.40")) != :gt)

# ── 4. Timed-out calls burn the request quota (the reproduced bug) ───────────
s = setup.(%{daily_request_limit: 2})
{token, id} = s.session.("timeouts")
results = for _ <- 1..5, do: s.req.(token, timeout_upstream)
u = ReservationStore.usage(id, day)
check.("5 timed-out calls, request limit 2: only 2 reach the upstream (got #{sent.()})", sent.() == 2)
check.("the timed-out calls still answer 502 upstream_error",
  Enum.count(results, &(&1.status == 502)) == 2)
check.("store contract untouched: error rows stay out of the store's request count", u.requests == 0)

quota =
  results |> List.last() |> Map.get(:resp_body) |> Jason.decode!() |> get_in(["x_router", "request_quota_exhausted"])

check.("later calls are blocked as request_quota_exhausted", quota == true)

# ── 5. Reservations are released after upstream errors ──────────────────────
s = setup.(%{daily_request_limit: 3})
{token, _id} = s.session.("release")
parallel.(for _ <- 1..2, do: fn -> s.req.(token, error_upstream) end)
check.("no reservation survives an upstream 5xx", inflight.(s.state_pid) == %{})
raised = s.req.(token, raising_upstream)
check.("no reservation survives an upstream exception (502 proxy_internal)",
  raised.status == 502 and inflight.(s.state_pid) == %{})

# 3 requests were sent (2 errors + 1 exception): the quota of 3 is now used up.
before = sent.()
s.req.(token, ok_upstream.(0.01))
check.("failed calls count toward the request quota: the 4th is blocked", sent.() == before)

# Errors hold no USD reservation: with no request limit, later calls are admitted.
s = setup.(%{})
{token, id} = s.session.("release-usd")
s.req.(token, ok_upstream.(0.40))
parallel.(for _ <- 1..3, do: fn -> s.req.(token, error_upstream) end)
before = sent.()
s.req.(token, ok_upstream.(0.40))
u = ReservationStore.usage(id, day)
check.("after upstream errors a later call is still admitted", sent.() == before + 1 and u.requests == 2)

# A killed handler never runs its cleanup: its reservation is reaped lazily.
s = setup.(%{daily_request_limit: 2})
{token, id} = s.session.("killed")
hang = fn _b, _h, _c -> Agent.update(calls, &(&1 + 1)); Process.sleep(:infinity) end
{:ok, victim} = Task.start(fn -> s.req.(token, hang) end)
Process.sleep(100)
check.("an in-flight call holds a reservation", map_size(inflight.(s.state_pid)) == 1)
Process.exit(victim, :kill)
Process.sleep(50)
s.req.(token, ok_upstream.(0.01))
u = ReservationStore.usage(id, day)
check.("a killed handler's reservation is released: the next call is admitted", u.requests == 1)
check.("...and only the live reservation's bookkeeping remains", inflight.(s.state_pid) == %{})
before = sent.()
s.req.(token, ok_upstream.(0.01))
check.("the killed call was sent upstream, so it burned 1 of the 2 requests", sent.() == before)

fails = Agent.get(failures, & &1)

if fails == [] do
  IO.puts("\nLLM_PROXY_RESERVATION: ALL PASS")
else
  IO.puts("\nLLM_PROXY_RESERVATION: #{length(fails)} FAILED")
  System.halt(1)
end
