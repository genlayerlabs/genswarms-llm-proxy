# CONN-LEVEL end-to-end credits flow (X1, CRITICAL coverage).
#
# Every other credit check drives internals directly: llm_proxy_credit_ledger_test.exs
# calls Proxy.apply_credit_entry/3 by hand, llm_proxy_credit_spend_test.exs builds a
# bare `opts` map and calls ProxyPlug.record_budget_call/5 / credit_exhausted?/2
# directly, llm_proxy_credit_topup_test.exs hand-builds the object `state` map for
# handle_message/3. NONE of them ever call `Genswarms.LlmProxy.init/1` — the real boot
# path that derives `credits_enabled`, assembles `plug_opts`, and wires the block gate
# to the real Plug. Three one-line mutations (credits_enabled?/1 -> always false; both
# `exhausted?(budget) and credit_exhausted?(opts, session)` gates reverted to bare
# `exhausted?(budget)`; the main record_budget_call/5 call site dropping the
# budget.spent_usd arg) all pass every existing check — none of them boot the object
# for real or drive a genuine request through it.
#
# This check closes that gap: it boots the FULL object via `Genswarms.LlmProxy.init/1`
# (real Bandit listener, real state Agent), then drives an actual HTTP request into
# that real listener with `Genswarms.LlmProxy.Curl.post/2` (the same curl seam the
# object itself uses to reach its upstream — :httpc/:inets is unusable in this OTP
# build, see curl.ex) against a second, real, local Bandit server standing in for the
# upstream. No hand-built opts/state/session — every seam is the real public API
# (Proxy.init/1, Proxy.register_session/2, Proxy.handle_message/3, Proxy.credit_balance/3).
#
# Standalone — NO Postgres, NO internet (loopback-only local Bandit servers).
#   mix run checks/llm_proxy_credit_e2e_test.exs

alias Genswarms.LlmProxy, as: Proxy
alias Genswarms.LlmProxy.Curl
alias Genswarms.LlmProxy.Plug, as: ProxyPlug

Application.ensure_all_started(:bandit)
Application.ensure_all_started(:plug)

# The genswarms engine (peer/runtime dep, see the module's own @moduledoc) is not
# present in this standalone checks environment — Genswarms.LlmProxy.Plug.call/2
# defaults plug_opts[:deliver_fn] to &Genswarms.Objects.ObjectServer.deliver_message/4
# unconditionally (init/1 never sets a deliver_fn of its own), and scenario 2 below
# genuinely calls it (a REAL block-notice delivery attempt, unlike the bump_metric
# path which swallows the same undefined-function error in a try/rescue). Standing
# in for the host's real object server here is the standalone-checks equivalent of
# it being loaded in a full swarm boot — not a test-only bypass of proxy logic.
defmodule Genswarms.Objects.ObjectServer do
  @moduledoc false
  def deliver_message(_swarm_name, _to, _from, _content), do: :ok
end

{:ok, failures} = Agent.start_link(fn -> [] end)

check = fn label, ok ->
  if ok do
    IO.puts("  ok   #{label}")
  else
    IO.puts("  FAIL #{label}")
    Agent.update(failures, &[label | &1])
  end
end

# ── Fake upstream: a real local Bandit server (not the :upstream test-seam fun) —
# the real object's call_upstream/3 shells out to curl regardless, so only a genuine
# HTTP server on loopback exercises the real wiring end to end.
defmodule E2E.FakeUpstream do
  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  post "/v1/chat/completions" do
    resp = %{
      "id" => "chatcmpl-e2e-fake",
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => "fake-model",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => "pong-e2e"},
          "finish_reason" => "stop"
        }
      ],
      # 1e6 prompt / 5e5 completion tokens @ 0.25/0.75 per Mtok -> cost_usd 0.625 (a
      # round, deterministic number for the debit assertion below).
      "usage" => %{
        "prompt_tokens" => 1_000_000,
        "completion_tokens" => 500_000,
        "total_tokens" => 1_500_000
      }
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(resp))
  end

  post "/v1/compact" do
    # Real upstream /v1/compact sibling (compact_endpoint/1 swaps
    # /chat/completions for /compact on this SAME fake upstream). Same token
    # counts as the chat fake above so the priced-seal debit below reuses the
    # scenario 1 arithmetic (1e6 prompt / 5e5 completion @ 0.25/0.75 per Mtok
    # -> cost_usd 0.625).
    resp = %{
      "messages" => [%{"role" => "system", "content" => "[sealed]"}],
      "compacted" => true,
      "usage" => %{
        "prompt_tokens" => 1_000_000,
        "completion_tokens" => 500_000,
        "total_tokens" => 1_500_000
      }
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(resp))
  end

  match _ do
    Plug.Conn.send_resp(conn, 404, "")
  end
end

# ── Fake durable store: real store_mod contract (budget accounting only — no
# credit callbacks, so the credit ledger runs in mirror mode, same as any store that
# hasn't adopted the credit extension yet). `seed/5` lets the check put a budget
# identity into an EXHAUSTED state before the real request is driven in.
defmodule E2E.Store do
  def start_link, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def seed(identity, day, session_id, spent, limit) do
    Agent.update(__MODULE__, fn state ->
      Map.put(state, {identity, day}, %{
        budget_identity: identity,
        day: day,
        session_id: session_id,
        spent_usd: Decimal.new(spent),
        limit_usd: Decimal.new(limit),
        requests: 0
      })
    end)
  end

  def llm_budget_status(identity, day, session_id, default_limit) do
    Agent.get_and_update(__MODULE__, fn state ->
      key = {identity, day}

      row =
        Map.get(state, key) ||
          %{
            budget_identity: identity,
            day: day,
            session_id: session_id,
            spent_usd: Decimal.new("0"),
            limit_usd: dec(default_limit),
            requests: 0
          }

      row = %{row | session_id: session_id}
      {row, Map.put(state, key, row)}
    end)
  end

  def record_llm_call(identity, day, session_id, attrs) do
    Agent.get_and_update(__MODULE__, fn state ->
      key = {identity, day}
      cost = dec(attrs[:cost_usd] || 0)

      row =
        Map.get(state, key) ||
          %{
            budget_identity: identity,
            day: day,
            session_id: session_id,
            spent_usd: Decimal.new("0"),
            limit_usd: Decimal.new("0.50"),
            requests: 0
          }

      status = to_string(attrs[:status] || "ok")

      row = %{
        row
        | session_id: session_id,
          spent_usd: Decimal.add(row.spent_usd, cost),
          requests: row.requests + if(status == "ok", do: 1, else: 0)
      }

      {row, Map.put(state, key, row)}
    end)
  end

  def llm_usage_today(_day), do: %{spent_usd: Decimal.new("0")}

  defp dec(%Decimal{} = d), do: d
  defp dec(v), do: Decimal.new(to_string(v))
end

fake_upstream_port = 41892
proxy_port_credits = 41893
proxy_port_no_credits = 41894

{:ok, _fake_upstream} =
  Bandit.start_link(plug: E2E.FakeUpstream, scheme: :http, ip: {127, 0, 0, 1}, port: fake_upstream_port)

{:ok, _store} = E2E.Store.start_link()

upstream_endpoint = "http://127.0.0.1:#{fake_upstream_port}/v1/chat/completions"

base_config = %{
  upstream_endpoint: upstream_endpoint,
  upstream_api_key: "fake-upstream-key",
  provider: "openai-compatible",
  prices: %{prompt_per_mtok: 0.25, completion_per_mtok: 0.75},
  store_mod: E2E.Store,
  default_daily_limit: "0.50",
  swarm_name: "e2e",
  connect_timeout_s: 2,
  upstream_timeout_s: 5
}

chat_body =
  Jason.encode!(%{"model" => "gpt-e2e", "messages" => [%{"role" => "user", "content" => "hi"}]})

# ═══════════════════════════════════════════════════════════════════════════
# Scenario 1 — payments_source configured, budget already exhausted, identity
# credited: the real request must NOT be blocked, and the debit must land.
# ═══════════════════════════════════════════════════════════════════════════

{:ok, state} =
  Proxy.init(
    Map.merge(base_config, %{
      port: proxy_port_credits,
      payments_source: "payments",
      credit_namespace: "default",
      credit_per_usd: "1.0"
    })
  )

check.("scenario 1: init/1 derives credits_enabled true", state.credits_enabled == true)

{:ok, token} =
  Proxy.register_session(state.state_pid, %{
    conversation_id: "tg:e2e-credits:0",
    slot: :agent_e2e,
    kind: :dm,
    workspace_key: "default"
  })

session = Proxy.lookup_session(state.state_pid, token)
day = Date.utc_today()
session_id = Proxy.upstream_session_id(session.budget_identity, day)

# Pre-exhaust the free daily budget ($0.60 spent against a $0.50 limit) BEFORE the
# real request — the block gate must consult the credit balance for this identity.
E2E.Store.seed(session.budget_identity, day, session_id, "0.60", "0.50")

payment_msg =
  Jason.encode!(%{
    "action" => "payment_confirmed",
    "beneficiary" => session.budget_identity,
    "amount_usd" => "5.00",
    "method" => "e2e",
    "ref" => "e2e-r1",
    "namespace" => "default"
  })

{:reply, credit_reply_json, _state2} = Proxy.handle_message("payments", payment_msg, state)
credit_reply = Jason.decode!(credit_reply_json)

check.(
  "scenario 1: payment_confirmed through handle_message/3 credits the identity",
  credit_reply["ok"] == true and credit_reply["balance_usd"] == "5.00"
)

balance_before = Proxy.credit_balance(state.state_pid, E2E.Store, session.budget_identity)

check.(
  "scenario 1: credit balance visible before the request",
  Decimal.equal?(balance_before, Decimal.new("5.00"))
)

{:ok, req_status, req_body} =
  Curl.post(
    state.endpoint,
    body: chat_body,
    headers: [{"authorization", "Bearer #{token}"}, {"content-type", "application/json"}],
    timeout: 5
  )

decoded = Jason.decode!(req_body)

check.(
  "scenario 1: exhausted daily budget + positive credit balance -> request goes " <>
    "through to upstream (NOT the block body)",
  req_status == 200 and get_in(decoded, ["choices", Access.at(0), "message", "content"]) ==
    "pong-e2e" and decoded["model"] != "llm-proxy-budget" and
    get_in(decoded, ["x_router", "budget_exhausted"]) != true
)

balance_after = Proxy.credit_balance(state.state_pid, E2E.Store, session.budget_identity)

# spent_before (0.60) already exceeds the $0.50 limit, so the ENTIRE $0.625 cost of
# this call is credit-funded (straddle math: overflow(before+cost) - overflow(before)
# == cost when before is already over the limit) — the mirror must reflect it.
check.(
  "scenario 1: the mirror credit balance decreased by the straddle debit (5.00 -> 4.375)",
  Decimal.equal?(balance_after, Decimal.new("4.375"))
)

# ── Scenario 1b — same exhausted-budget-plus-positive-balance identity, but
# hitting /v1/compact instead of /v1/chat/completions. Pins the compact
# route's OWN `exhausted?(budget) and credit_exhausted?(opts, session)` gate
# (checks/llm_proxy_compact_test.exs never drives credits at all, and every
# other credit check only drives /v1/chat/completions — reverting ONLY the
# compact gate to bare `exhausted?(budget)` passed the whole suite).
compact_endpoint_credits = ProxyPlug.compact_endpoint(state.endpoint)

compact_body =
  Jason.encode!(%{
    "messages" => [%{"role" => "user", "content" => "hi"}],
    "keep_recent" => 6,
    "max_tokens" => 512
  })

{:ok, compact_status, compact_resp_body} =
  Curl.post(
    compact_endpoint_credits,
    body: compact_body,
    headers: [{"authorization", "Bearer #{token}"}, {"content-type", "application/json"}],
    timeout: 5
  )

compact_decoded = Jason.decode!(compact_resp_body)

check.(
  "scenario 1b: exhausted daily budget + positive credit balance -> /v1/compact " <>
    "proceeds too (NOT the budget-block response)",
  compact_status == 200 and compact_decoded["compacted"] == true and
    get_in(compact_decoded, ["error", "code"]) != "budget_exhausted"
)

balance_after_compact =
  Proxy.credit_balance(state.state_pid, E2E.Store, session.budget_identity)

# spent_before is already far past the $0.50 limit (scenario 1 alone pushed it
# to 1.225), so the seal's ENTIRE $0.625 rate-card cost is credit-funded —
# same straddle math as scenario 1's chat debit (4.375 -> 3.75).
check.(
  "scenario 1b: the seal's overflow cost debits the SAME mirror balance (4.375 -> 3.75)",
  Decimal.equal?(balance_after_compact, Decimal.new("3.75"))
)

Proxy.terminate(:normal, state)

# ═══════════════════════════════════════════════════════════════════════════
# Scenario 2 — FRESH boot, no payments_source at all: same exhausted budget must
# still get the 0.2.19 block response (credits feature never touched).
# ═══════════════════════════════════════════════════════════════════════════

{:ok, state_off} = Proxy.init(Map.put(base_config, :port, proxy_port_no_credits))

check.("scenario 2: init/1 with no payments_source derives credits_enabled false",
  state_off.credits_enabled == false)

{:ok, token_off} =
  Proxy.register_session(state_off.state_pid, %{
    conversation_id: "tg:e2e-nocredits:0",
    slot: :agent_e2e,
    kind: :dm,
    workspace_key: "default"
  })

session_off = Proxy.lookup_session(state_off.state_pid, token_off)
session_id_off = Proxy.upstream_session_id(session_off.budget_identity, day)

E2E.Store.seed(session_off.budget_identity, day, session_id_off, "0.60", "0.50")

{:ok, req_status_off, req_body_off} =
  Curl.post(
    state_off.endpoint,
    body: chat_body,
    headers: [{"authorization", "Bearer #{token_off}"}, {"content-type", "application/json"}],
    timeout: 5
  )

decoded_off = Jason.decode!(req_body_off)

check.(
  "scenario 2: no payments_source -> exhausted budget gets the byte-identical " <>
    "0.2.19 block response (model llm-proxy-budget, x_router.budget_exhausted true)",
  req_status_off == 200 and decoded_off["model"] == "llm-proxy-budget" and
    get_in(decoded_off, ["x_router", "budget_exhausted"]) == true
)

Proxy.terminate(:normal, state_off)

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_CREDIT_E2E: ALL PASS")
else
  IO.puts("LLM_PROXY_CREDIT_E2E: FAILED")
  IO.puts("  Failed: #{Enum.join(Enum.reverse(failed), ", ")}")
  System.halt(1)
end
