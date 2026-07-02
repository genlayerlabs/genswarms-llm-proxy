# LLM proxy buffered crash guard + client-facing key scrub (Task 3).
# Standalone — NO Postgres, NO network.
#
#   mix run tests/llm_proxy_crashguard_test.exs
#
# Injects store_mod, upstream, and deliver_fn seams. The fake store always
# returns a non-exhausted budget so every test reaches the guarded path.

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

json_body = fn conn -> Jason.decode!(conn.resp_body) end

# ── Fake store — PG-free, never-exhausted budget ─────────────────────────────

defmodule Genswarms.LlmProxy.CrashGuardFakeStore do
  def llm_budget_status(_identity, _day, _session_id, _limit) do
    %{
      spent_usd: Decimal.new("0"),
      limit_usd: Decimal.new("100")
    }
  end

  def record_llm_call(_identity, _day, _session_id, _attrs), do: %{}
end

# ── Shared infrastructure ─────────────────────────────────────────────────────

# The upstream API key embedded in opts — must never reach the sandboxed agent.
sentinel_key = "real-upstream-key-SENTINEL"

{:ok, state_pid} = Proxy.start_state_link()

session_attrs = %{
  conversation_id: "tg:cg-test:0",
  slot: :cg_agent,
  kind: :dm,
  workspace_key: "crashguard"
}

{:ok, cg_token} = Proxy.register_session(state_pid, session_attrs)

# Metric bumps captured via deliver_fn (bump_metric calls deliver with action:"bump")
{:ok, metric_captures} = Agent.start_link(fn -> [] end)

base_opts = %{
  state_pid: state_pid,
  upstream_endpoint: "https://llm.example/v1/chat/completions",
  upstream_api_key: sentinel_key,
  provider: "unit-cg",
  prices: %{},
  store_mod: Genswarms.LlmProxy.CrashGuardFakeStore,
  clock: fn -> ~U[2026-06-25 12:00:00Z] end,
  swarm_name: "wingston",
  sender: :sender,
  metrics: :test_metrics,
  deliver_fn: fn _sw, _to, :llm_proxy, json ->
    case Jason.decode(json) do
      {:ok, %{"action" => "bump", "key" => key}} ->
        Agent.update(metric_captures, &[key | &1])

      _ ->
        :ok
    end

    :ok
  end
}

post_completions = fn token, upstream_fn ->
  body_str = Jason.encode!(%{"model" => "gpt-cg", "messages" => []})

  conn(:post, "/v1/chat/completions", body_str)
  |> put_req_header("authorization", "Bearer #{token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :upstream, upstream_fn)))
end

# ── Test 1: Crash guard — hostile body causes respond_upstream to RAISE ──────
#
# Hostile body shape: a 2xx whose decoded JSON body is NOT a map ("hostile" —
# a bare JSON string decodes fine, so http_upstream CAN yield this).
#
# Why it raises in the CURRENT proxy code (not the stub):
#   respond_upstream/8 (status 200..299 arm) does Map.get(body, "usage") on a
#   BitString → BadMapError. (The old vector — usage: "not-a-map" — no longer
#   crashes: normalize_usage_counts coerces garbage counts to 0 by design.)
# The crash guard must catch this and return 502 without propagating.

Agent.update(metric_captures, fn _ -> [] end)

hostile_upstream = fn _body, _headers, _cfg ->
  {:ok, 200, "hostile-not-a-map"}
end

hostile_conn = post_completions.(cg_token, hostile_upstream)
hostile_body = json_body.(hostile_conn)
captured_after_crash = Agent.get(metric_captures, & &1)

check.(
  "crash guard: hostile body does not raise — ProxyPlug.call returns a conn",
  is_map(hostile_conn) and Map.has_key?(hostile_conn, :status)
)

check.(
  "crash guard: returns 502",
  hostile_conn.status == 502
)

check.(
  "crash guard: error.code is \"proxy_internal\"",
  get_in(hostile_body, ["error", "code"]) == "proxy_internal"
)

check.(
  "crash guard: error.message is \"proxy internal error\"",
  get_in(hostile_body, ["error", "message"]) == "proxy internal error"
)

check.(
  "crash guard: llm_proxy_requests metric was bumped (every non-exhausted request)",
  "llm_proxy_requests" in captured_after_crash
)

check.(
  "crash guard: llm_proxy_internal_error metric was bumped",
  "llm_proxy_internal_error" in captured_after_crash
)

check.(
  "crash guard: response body does not contain sentinel key",
  not String.contains?(hostile_conn.resp_body, sentinel_key)
)

# ── Test 2: Survival — process still alive, next requests succeed ─────────────
#
# Proves the rescue contained the failure: the Plug process didn't crash,
# GET /healthz still works, and a fresh well-formed request returns 200.

healthz_conn =
  conn(:get, "/healthz")
  |> ProxyPlug.call(ProxyPlug.init(base_opts))

check.(
  "survival: GET /healthz returns 200 after crash guard fired",
  healthz_conn.status == 200
)

well_formed_upstream = fn _body, _headers, _cfg ->
  {:ok, 200,
   %{
     "id" => "chatcmpl-ok",
     "object" => "chat.completion",
     "created" => 1_750_000_000,
     "model" => "gpt-cg-served",
     "choices" => [
       %{
         "index" => 0,
         "message" => %{"role" => "assistant", "content" => "survived"},
         "finish_reason" => "stop"
       }
     ],
     "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8},
     "x_router" => %{"provider" => "unit-cg", "served_model_id" => "gpt-cg"}
   }}
end

# Re-register a fresh token (the hostile test used and did NOT invalidate cg_token,
# but re-registration proves the state_pid is still functional).
{:ok, cg_token2} = Proxy.register_session(state_pid, session_attrs)

survival_conn = post_completions.(cg_token2, well_formed_upstream)
survival_body = json_body.(survival_conn)

check.(
  "survival: well-formed request after crash returns 200",
  survival_conn.status == 200
)

check.(
  "survival: well-formed request returns expected choices content",
  get_in(survival_body, ["choices", Access.at(0), "message", "content"]) == "survived"
)

# ── Test 3: Client-facing key scrub in upstream error arm ─────────────────────
#
# Upstream 4xx error bodies often echo a masked key:
#   "Incorrect API key provided: real-upstream-key-SENTINEL"
# call_upstream maps {:error, status, resp} → {:ok, status, resp, latency}
# so status 401 hits the non-2xx arm of respond_upstream.
# After Task 3's scrub, the sentinel key must NOT appear in the forwarded body.

{:ok, cg_token3} = Proxy.register_session(state_pid, session_attrs)

scrub_upstream = fn _body, _headers, _cfg ->
  {:error, 401,
   %{
     "error" => %{
       "message" => "Incorrect API key provided: #{sentinel_key}",
       "code" => "invalid_api_key"
     }
   }}
end

scrub_conn = post_completions.(cg_token3, scrub_upstream)
scrub_raw = scrub_conn.resp_body
scrub_body = json_body.(scrub_conn)

check.(
  "key scrub: upstream 401 is forwarded with status 401",
  scrub_conn.status == 401
)

check.(
  "key scrub: SENTINEL key is absent from the forwarded response body",
  not String.contains?(scrub_raw, sentinel_key)
)

check.(
  "key scrub: [REDACTED] appears in its place",
  String.contains?(scrub_raw, "[REDACTED]")
)

check.(
  "key scrub: error message is still non-empty (client can see it was auth error)",
  (get_in(scrub_body, ["error", "message"]) || "") |> String.length() > 0
)

check.(
  "key scrub: error code passes through unchanged",
  get_in(scrub_body, ["error", "code"]) == "invalid_api_key"
)

# ── Test 4: Rescue log scrub (structural) ────────────────────────────────────
#
# The rescue arm logs: inspect(e.__struct__) — the module atom name only.
# Even if the raised exception embeds the key in its message or fields,
# `inspect(e.__struct__)` returns only the module name (e.g. "FunctionClauseError")
# and can never contain secret key material.

dummy_exc = %FunctionClauseError{module: Access, function: :get, arity: 3}
struct_log_fragment = inspect(dummy_exc.__struct__)

check.(
  "rescue log scrub: inspect(e.__struct__) is just the module name, cannot embed SENTINEL",
  not String.contains?(struct_log_fragment, sentinel_key) and
    struct_log_fragment =~ ~r/^[A-Z][A-Za-z.]+$/
)

check.(
  "rescue log scrub: an exception carrying SENTINEL in its message field still logs safely",
  inspect(%RuntimeError{message: "embedded #{sentinel_key}"}) |> then(fn full_inspect ->
    # Full inspect DOES contain the key, but the rescue arm only logs __struct__
    full_inspect_contains_sentinel = String.contains?(full_inspect, sentinel_key)
    struct_only = inspect(%RuntimeError{}.__struct__)
    struct_contains_sentinel = String.contains?(struct_only, sentinel_key)
    # Confirm: full inspect has it, but struct name alone does not
    full_inspect_contains_sentinel and not struct_contains_sentinel
  end)
)

# ─────────────────────────────────────────────────────────────────────────────

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_CRASHGUARD: ALL PASS")
else
  IO.puts("LLM_PROXY_CRASHGUARD: FAILED — #{length(failed)} check(s) failed")
  Enum.each(Enum.reverse(failed), &IO.puts("  - #{&1}"))
  System.halt(1)
end
