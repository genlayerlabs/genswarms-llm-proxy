# /v1/compact forwarding (async context seal). Standalone — NO Postgres, NO network.
#
#   mix run checks/llm_proxy_compact_test.exs
#
# The seal is a real upstream LLM call on the operator's key, so the route must:
#   * authenticate the agent's bearer like a chat call;
#   * forward the body UNCHANGED (no "session" injection — CompactRequest is a
#     strict schema — and no prompt-cache marking) to the sibling /compact URL
#     derived from the configured chat endpoint;
#   * pass the response through verbatim ({messages, compacted}, plus any
#     additive "usage"/"x_router" a new router attaches);
#   * record a status-"ok" / model-"compact" ledger row so the seal burns the
#     per-conversation request quota (the store's quota SQL counts only
#     status='ok') — a compact loop is never free;
#   * price the seal through the SAME cost chokepoint as a chat call when the
#     upstream response carries OpenAI-shape "usage" and/or the chat-shaped
#     "x_router" (two-spends: user charge + provider cost) — and keep recording
#     the $0 legacy row when BOTH are absent (legacy router compat, no crash);
#   * advance the per-conversation dollar budget AND the operator-wide global
#     ceiling with the seal's cost — the seal is never invisible money;
#   * bump llm_proxy_compact_error (distinct from _block) on upstream failure,
#     recording any x_router cost the new router billed for the failed seal;
#   * answer plain-JSON 429s on the budget gates (no sender delivery — the
#     agent's splice step finds no "messages" and skips, degrading silently).

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

json = fn conn -> Jason.decode!(conn.resp_body) end

# Minimal in-proc store fake mirroring the real quota semantics: only
# status == "ok" rows advance `requests` (store.ex CASE WHEN status = 'ok').
defmodule CompactCheck.Store do
  @name __MODULE__

  def start_link, do: Agent.start_link(fn -> %{daily: %{}, events: []} end, name: @name)

  def llm_budget_status(identity, day, session_id, default_limit) do
    Agent.get(@name, fn state ->
      Map.get(state.daily, {identity, day}) ||
        %{
          budget_identity: identity,
          day: day,
          session_id: session_id,
          spent_usd: Decimal.new("0"),
          limit_usd: dec(default_limit),
          requests: 0,
          prompt_tokens: 0,
          completion_tokens: 0,
          total_tokens: 0
        }
    end)
  end

  def seed(identity, day, spent, limit, requests) do
    Agent.update(@name, fn state ->
      put_in(state, [:daily, {identity, day}], %{
        budget_identity: identity,
        day: day,
        session_id: "seed",
        spent_usd: dec(spent),
        limit_usd: dec(limit),
        requests: requests,
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0
      })
    end)
  end

  def record_llm_call(identity, day, session_id, attrs, default_limit \\ "0.50") do
    Agent.get_and_update(@name, fn state ->
      key = {identity, day}
      status = to_string(attrs[:status] || "ok")

      row =
        Map.get(state.daily, key) ||
          %{
            budget_identity: identity,
            day: day,
            session_id: session_id,
            spent_usd: Decimal.new("0"),
            limit_usd: dec(default_limit),
            requests: 0,
            prompt_tokens: 0,
            completion_tokens: 0,
            total_tokens: 0
          }

      row = %{
        row
        | requests: row.requests + if(status == "ok", do: 1, else: 0),
          spent_usd: Decimal.add(row.spent_usd, dec(attrs[:cost_usd] || 0))
      }

      event =
        Map.merge(
          Map.take(attrs, [
            :request_id,
            :status,
            :model,
            :cost_usd,
            :provider_cost_usd,
            :provider_cost_state,
            :charge_basis,
            :prompt_tokens,
            :completion_tokens,
            :total_tokens,
            :provider
          ]),
          %{identity: identity}
        )

      {row, %{state | daily: Map.put(state.daily, key, row), events: [event | state.events]}}
    end)
  end

  def events, do: Agent.get(@name, &Enum.reverse(&1.events))
  def usage(identity, day), do: Agent.get(@name, &Map.get(&1.daily, {identity, day}))
  def llm_usage_today(_day), do: %{spent_usd: Decimal.new("0")}

  defp dec(%Decimal{} = v), do: v
  defp dec(v), do: Decimal.new(to_string(v))
end

{:ok, state_pid} = Proxy.start_state_link()
{:ok, _} = CompactCheck.Store.start_link()

{:ok, token} =
  Proxy.register_session(state_pid, %{
    conversation_id: "tg:77:0",
    slot: :agent_0,
    kind: :dm,
    workspace_key: "default"
  })

session = Proxy.lookup_session(state_pid, token)

base_opts = %{
  state_pid: state_pid,
  upstream_endpoint: "https://llm.example/v1/chat/completions",
  upstream_api_key: "upstream-secret",
  provider: "unit",
  prices: %{prompt_per_mtok: 0.25, completion_per_mtok: 0.75},
  store_mod: CompactCheck.Store,
  clock: fn -> ~U[2026-07-05 12:00:00Z] end,
  swarm_name: "wingston",
  sender: :sender,
  deliver_fn: fn _swarm, _to, _from, _content -> :ok end
}

compact_body = %{
  "messages" => [%{"role" => "user", "content" => "hi"}],
  "keep_recent" => 6,
  "max_tokens" => 512,
  "policy_ir" => ["policy", ["and", ["meets_req"]], ["zero"], ["argmax"], ["id"], ["always", %{}]]
}

# ── endpoint derivation (pure) ───────────────────────────────────────────────

check.(
  "compact_endpoint/1 swaps /chat/completions for /compact (subzeroclaw's own derivation)",
  ProxyPlug.compact_endpoint("https://llm.example/v1/chat/completions") ==
    "https://llm.example/v1/compact" and
    ProxyPlug.compact_endpoint("https://llm.example/v1/") == "https://llm.example/v1/compact"
)

# ── auth ─────────────────────────────────────────────────────────────────────

unauth =
  conn(:post, "/v1/compact", Jason.encode!(compact_body))
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(base_opts))

check.("compact without a bearer is 401", unauth.status == 401)

# ── happy path: verbatim forward to the /compact URL, response passthrough ──

seen = self()

ok_upstream = fn body, headers, cfg ->
  send(seen, {:compact_call, body, headers, cfg})

  {:ok, 200,
   %{"messages" => [%{"role" => "system", "content" => "[sealed]"}], "compacted" => true}}
end

ok_conn =
  conn(:post, "/v1/compact", Jason.encode!(compact_body))
  |> put_req_header("authorization", "Bearer #{token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :upstream, ok_upstream)))

ok_body = json.(ok_conn)

receive do
  {:compact_call, seen_body, seen_headers, seen_cfg} ->
    check.(
      "forwards to the derived /v1/compact URL with the unhardcoded session header",
      seen_cfg.upstream_endpoint == "https://llm.example/v1/compact" and
        Enum.any?(seen_headers, fn {k, _} -> k == "x-unhardcoded-session" end)
    )

    check.(
      "body goes upstream UNCHANGED: no session injection, no cache_control marking",
      seen_body == compact_body
    )
after
  1_000 -> check.("upstream compact call was made", false)
end

check.(
  "response passes through verbatim ({messages, compacted})",
  ok_conn.status == 200 and ok_body["compacted"] == true and
    length(ok_body["messages"]) == 1
)

events = CompactCheck.Store.events()

check.(
  "seal recorded as a status-ok / model-compact ledger row (burns request quota)",
  match?([%{status: "ok", model: "compact"}], events) and
    CompactCheck.Store.usage(session.budget_identity, ~D[2026-07-05]).requests == 1
)

# EXPLICIT legacy compat (not the only truth anymore): a router that attaches
# no usage/x_router keeps producing the PRE-0.2.18 record byte-identical — the
# minimal 3-key map with NO accounting labels, so durable stores stamp their
# own legacy defaults exactly as they did for 0.2.17 rows. Pinning key ABSENCE
# (not provider_cost_state == "missing") is the point: a 'missing' label here
# would leak the missing-cost-signal noise into the ledger once per legacy seal.
[legacy_event] = events

check.(
  "legacy router (no usage/x_router) → pre-0.2.18 minimal row: no accounting labels, no spend",
  legacy_event.model == "compact" and legacy_event.status == "ok" and
    not Map.has_key?(legacy_event, :cost_usd) and
    not Map.has_key?(legacy_event, :provider_cost_usd) and
    not Map.has_key?(legacy_event, :provider_cost_state) and
    not Map.has_key?(legacy_event, :charge_basis) and
    Decimal.compare(
      CompactCheck.Store.usage(session.budget_identity, ~D[2026-07-05]).spent_usd,
      Decimal.new("0")
    ) == :eq
)

# ── upstream failure: passthrough status, quota-free compact_error row ───────

err_upstream = fn _body, _headers, _cfg ->
  {:ok, 502, %{"error" => %{"message" => "boom", "code" => "upstream_error"}}}
end

err_conn =
  conn(:post, "/v1/compact", Jason.encode!(compact_body))
  |> put_req_header("authorization", "Bearer #{token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :upstream, err_upstream)))

check.(
  "upstream failure passes through and records quota-free compact_error",
  err_conn.status == 502 and
    match?([_, %{status: "compact_error", model: "compact"}], CompactCheck.Store.events()) and
    CompactCheck.Store.usage(session.budget_identity, ~D[2026-07-05]).requests == 1
)

# ── budget gates: plain-JSON 429s, upstream never called ────────────────────

CompactCheck.Store.seed(session.budget_identity, ~D[2026-07-05], "0.60", "0.50", 1)

never_upstream = fn _body, _headers, _cfg ->
  send(seen, :unexpected_upstream)
  {:ok, 200, %{"messages" => [], "compacted" => false}}
end

blocked =
  conn(:post, "/v1/compact", Jason.encode!(compact_body))
  |> put_req_header("authorization", "Bearer #{token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :upstream, never_upstream)))

check.(
  "exhausted dollar budget → plain JSON 429, upstream untouched",
  blocked.status == 429 and json.(blocked)["error"]["code"] == "budget_exhausted" and
    not receive do
      :unexpected_upstream -> true
    after
      50 -> false
    end
)

CompactCheck.Store.seed(session.budget_identity, ~D[2026-07-05], "0.01", "0.50", 3)

quota_blocked =
  conn(:post, "/v1/compact", Jason.encode!(compact_body))
  |> put_req_header("authorization", "Bearer #{token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(base_opts |> Map.put(:upstream, never_upstream) |> Map.put(:daily_request_limit, 3))
  )

check.(
  "exhausted request quota → 429 request_quota_exhausted (a compact loop is never free)",
  quota_blocked.status == 429 and
    json.(quota_blocked)["error"]["code"] == "request_quota_exhausted"
)

# ── NEW router: usage + x_router on the seal → two-spends cost accounting ────
#
# The wire contract is additive: a new router MAY attach OpenAI-shape "usage"
# and the chat-shaped "x_router" to /v1/compact responses. The proxy prices the
# seal through executed_cost_usd (the single money chokepoint) and records BOTH
# spends; the body still passes through verbatim (the agent's splice reads only
# "messages").

metric_deliver = fn _swarm, :metrics, :llm_proxy, payload ->
  send(seen, {:metric, Jason.decode!(payload)["key"]})
  :ok
end

drain_metrics = fn drain ->
  receive do
    {:metric, key} -> [key | drain.(drain)]
  after
    50 -> []
  end
end

{:ok, token2} =
  Proxy.register_session(state_pid, %{
    conversation_id: "tg:88:0",
    slot: :agent_1,
    kind: :dm,
    workspace_key: "default"
  })

session2 = Proxy.lookup_session(state_pid, token2)

seal_usage = %{"prompt_tokens" => 40_000, "completion_tokens" => 2_000, "total_tokens" => 42_000}
seal_x_router = %{"cost_usd" => "0.0123", "provider" => "anthropic", "served_model_id" => "claude-h"}

costed_upstream = fn _body, _headers, _cfg ->
  {:ok, 200,
   %{
     "messages" => [%{"role" => "system", "content" => "[sealed]"}],
     "compacted" => true,
     "usage" => seal_usage,
     "x_router" => seal_x_router
   }}
end

costed_opts =
  base_opts
  |> Map.merge(%{
    upstream: costed_upstream,
    pricing_mode: :rate_card_first,
    metrics: :metrics,
    deliver_fn: metric_deliver
  })

costed_conn =
  conn(:post, "/v1/compact", Jason.encode!(compact_body))
  |> put_req_header("authorization", "Bearer #{token2}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(costed_opts))

costed_body = json.(costed_conn)
costed_event = CompactCheck.Store.events() |> List.last()
_ = drain_metrics.(drain_metrics)

# rate_card_first + complete card: charge = rate card over the seal's tokens
# (40k × 0.25/Mtok + 2k × 0.75/Mtok = 0.0115), NOT the router's provider cost.
check.(
  "costed seal → two-spends row: rate-card user charge AND router provider cost, both > 0",
  costed_event.status == "ok" and costed_event.model == "compact" and
    Decimal.compare(costed_event.cost_usd, Decimal.new("0.0115")) == :eq and
    Decimal.compare(costed_event.provider_cost_usd, Decimal.new("0.0123")) == :eq and
    costed_event.provider_cost_state == "known" and
    costed_event.charge_basis == "rate_card" and
    costed_event.prompt_tokens == 40_000 and
    costed_event.completion_tokens == 2_000 and
    costed_event.total_tokens == 42_000 and
    costed_event.provider == "anthropic"
)

check.(
  "costed seal advances the per-conversation dollar budget in the durable store",
  Decimal.compare(
    CompactCheck.Store.usage(session2.budget_identity, ~D[2026-07-05]).spent_usd,
    Decimal.new("0.0115")
  ) == :eq
)

check.(
  "costed seal body still passes through verbatim (usage/x_router additive, untouched)",
  costed_conn.status == 200 and costed_body["usage"] == seal_usage and
    costed_body["compacted"] == true and costed_body["x_router"] == seal_x_router
)

# ── legacy seal must NOT move llm_proxy_provider_cost_unknown ─────────────────
#
# That counter's standing meaning is "billable chat call whose router omitted a
# cost signal" — it feeds the router-cost-signal investigation. A legacy router
# attaching NEITHER usage NOR x_router is EXPECTED to carry no cost (that is the
# wire contract's compat arm), so a legacy seal must record its $0 row without
# masquerading as a missing chat cost signal.

legacy_metrics_conn =
  conn(:post, "/v1/compact", Jason.encode!(compact_body))
  |> put_req_header("authorization", "Bearer #{token2}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(
      base_opts
      |> Map.merge(%{upstream: ok_upstream, metrics: :metrics, deliver_fn: metric_deliver})
    )
  )

legacy_metrics = drain_metrics.(drain_metrics)

check.(
  "legacy seal (no usage/x_router) bumps llm_proxy_compact, NOT provider_cost_unknown",
  legacy_metrics_conn.status == 200 and "llm_proxy_compact" in legacy_metrics and
    "llm_proxy_provider_cost_unknown" not in legacy_metrics
)

# ...while a NEW router that DOES attach keys but omits the cost still trips the
# signal: x_router without cost_usd on a priced seal is a genuinely missing cost.

no_cost_upstream = fn _body, _headers, _cfg ->
  {:ok, 200,
   %{
     "messages" => [%{"role" => "system", "content" => "[sealed]"}],
     "compacted" => true,
     "usage" => seal_usage,
     "x_router" => %{"provider" => "anthropic"}
   }}
end

no_cost_conn =
  conn(:post, "/v1/compact", Jason.encode!(compact_body))
  |> put_req_header("authorization", "Bearer #{token2}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(
      base_opts
      |> Map.merge(%{upstream: no_cost_upstream, metrics: :metrics, deliver_fn: metric_deliver})
    )
  )

no_cost_metrics = drain_metrics.(drain_metrics)

check.(
  "new-router seal WITH usage/x_router but no cost_usd still bumps provider_cost_unknown",
  no_cost_conn.status == 200 and "llm_proxy_provider_cost_unknown" in no_cost_metrics
)

# ── upstream failure with a billed x_router: compact_error metric + cost row ─

billed_err_upstream = fn _body, _headers, _cfg ->
  {:ok, 500,
   %{
     "error" => %{"message" => "seal blew", "code" => "upstream_error"},
     "x_router" => %{"cost_usd" => "0.002", "provider" => "openai"}
   }}
end

requests_before_err =
  CompactCheck.Store.usage(session2.budget_identity, ~D[2026-07-05]).requests

billed_err_conn =
  conn(:post, "/v1/compact", Jason.encode!(compact_body))
  |> put_req_header("authorization", "Bearer #{token2}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(
      base_opts
      |> Map.merge(%{
        upstream: billed_err_upstream,
        metrics: :metrics,
        deliver_fn: metric_deliver
      })
    )
  )

err_metrics = drain_metrics.(drain_metrics)
billed_err_event = CompactCheck.Store.events() |> List.last()

check.(
  "upstream failure bumps llm_proxy_compact_error (distinct from _block)",
  billed_err_conn.status == 500 and "llm_proxy_compact_error" in err_metrics and
    "llm_proxy_compact_block" not in err_metrics
)

# cost_plus default: the router's known cost for the failed seal is authoritative
# — the row records what the router billed, while staying quota-free.
check.(
  "billed compact_error row records the router's cost, stays quota-free",
  billed_err_event.status == "compact_error" and
    Decimal.compare(billed_err_event.provider_cost_usd, Decimal.new("0.002")) == :eq and
    billed_err_event.provider_cost_state == "known" and
    Decimal.compare(billed_err_event.cost_usd, Decimal.new("0.002")) == :eq and
    CompactCheck.Store.usage(session2.budget_identity, ~D[2026-07-05]).requests ==
      requests_before_err
)

# ── the seal's cost EXHAUSTS the per-conversation budget eventually ──────────
#
# Also pins the partial-failure shape: {"compacted": false} 2xx responses that
# followed a billable upstream call carry usage/x_router and MUST be priced.

{:ok, token3} =
  Proxy.register_session(state_pid, %{
    conversation_id: "tg:99:0",
    slot: :agent_2,
    kind: :dm,
    workspace_key: "default"
  })

partial_upstream = fn _body, _headers, _cfg ->
  {:ok, 200,
   %{"messages" => [], "compacted" => false, "usage" => seal_usage, "x_router" => seal_x_router}}
end

budget_opts =
  base_opts
  |> Map.merge(%{
    upstream: partial_upstream,
    pricing_mode: :rate_card_first,
    default_daily_limit: Decimal.new("0.02")
  })

seal = fn ->
  conn(:post, "/v1/compact", Jason.encode!(compact_body))
  |> put_req_header("authorization", "Bearer #{token3}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(budget_opts))
end

first = seal.()
first_event = CompactCheck.Store.events() |> List.last()
second = seal.()
third = seal.()

check.(
  "a compacted:false partial-failure 2xx is still priced (usage/x_router present)",
  first.status == 200 and
    Decimal.compare(first_event.cost_usd, Decimal.new("0.0115")) == :eq
)

check.(
  "seal cost advances the daily budget until exhausted? blocks (0.0115 + 0.0115 ≥ 0.02)",
  first.status == 200 and second.status == 200 and third.status == 429 and
    json.(third)["error"]["code"] == "budget_exhausted"
)

# ── the seal's cost moves the operator-wide GLOBAL ceiling ────────────────────
#
# Fresh state pid: the in-memory global accumulator must advance from the
# seal's recorded cost alone (the fake store's llm_usage_today is always $0,
# so only the accumulator can trip the ceiling — the exact hole being closed).

{:ok, state_pid2} = Proxy.start_state_link()

{:ok, token4} =
  Proxy.register_session(state_pid2, %{
    conversation_id: "tg:111:0",
    slot: :agent_0,
    kind: :dm,
    workspace_key: "default"
  })

global_opts =
  base_opts
  |> Map.merge(%{
    state_pid: state_pid2,
    upstream: costed_upstream,
    pricing_mode: :rate_card_first,
    global_daily_limit: Decimal.new("0.02")
  })

global_seal = fn ->
  conn(:post, "/v1/compact", Jason.encode!(compact_body))
  |> put_req_header("authorization", "Bearer #{token4}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(global_opts))
end

g1 = global_seal.()
g2 = global_seal.()
g3 = global_seal.()

check.(
  "seal cost moves the global ceiling: third seal blocked global_budget_exhausted",
  g1.status == 200 and g2.status == 200 and g3.status == 429 and
    json.(g3)["error"]["code"] == "global_budget_exhausted"
)

failures_list = Agent.get(failures, & &1)

if failures_list == [] do
  IO.puts("\nLLM_PROXY_COMPACT: ALL PASS")
else
  IO.puts("\nLLM_PROXY_COMPACT: FAILED (#{length(failures_list)})")
  Enum.each(failures_list, &IO.puts("  - #{&1}"))
  System.halt(1)
end
