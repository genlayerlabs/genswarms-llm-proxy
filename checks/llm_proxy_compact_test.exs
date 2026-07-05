# /v1/compact forwarding (async context seal). Standalone — NO Postgres, NO network.
#
#   mix run checks/llm_proxy_compact_test.exs
#
# The seal is a real upstream LLM call on the operator's key, so the route must:
#   * authenticate the agent's bearer like a chat call;
#   * forward the body UNCHANGED (no "session" injection — CompactRequest is a
#     strict schema — and no prompt-cache marking) to the sibling /compact URL
#     derived from the configured chat endpoint;
#   * pass the response through verbatim ({messages, compacted});
#   * record a zero-cost status-"ok" / model-"compact" ledger row so the seal
#     burns the per-conversation request quota (the store's quota SQL counts
#     only status='ok') — a compact loop is never free;
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

  def record_llm_call(identity, day, session_id, attrs) do
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
            limit_usd: Decimal.new("0.50"),
            requests: 0,
            prompt_tokens: 0,
            completion_tokens: 0,
            total_tokens: 0
          }

      row = %{row | requests: row.requests + if(status == "ok", do: 1, else: 0)}
      event = Map.merge(Map.take(attrs, [:request_id, :status, :model]), %{identity: identity})
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

failures_list = Agent.get(failures, & &1)

if failures_list == [] do
  IO.puts("\nLLM_PROXY_COMPACT: ALL PASS")
else
  IO.puts("\nLLM_PROXY_COMPACT: FAILED (#{length(failures_list)})")
  Enum.each(failures_list, &IO.puts("  - #{&1}"))
  System.halt(1)
end
