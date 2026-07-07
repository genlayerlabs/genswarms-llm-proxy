# LLM proxy contract (Task 3). Standalone — NO Postgres, NO network.
#
#   mix run tests/llm_proxy_test.exs
#
# Drives the Plug entirely through Plug.Test conns with injected seams:
#   * store_mod  — an in-proc Agent fake (no PG);
#   * :upstream  — an injected fun replacing the real curl http_upstream/3 (no network);
#   * :deliver_fn — captures slot_reply deliveries (no ObjectServer).

Application.ensure_all_started(:plug)

# curl.ex is referenced by http_upstream/3 (call-time only — never exercised here), but
# requiring it keeps the proxy free of compile-time "undefined module" warnings.

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

defmodule ProxyCheck.TestLLMProxyStore do
  @name __MODULE__

  def start_link, do: Agent.start_link(fn -> %{daily: %{}, events: []} end, name: @name)
  def reset, do: Agent.update(@name, fn _ -> %{daily: %{}, events: []} end)

  def seed_usage(identity, day, spent, limit \\ "0.50") do
    Agent.update(@name, fn state ->
      put_in(state, [:daily, {identity, day}], %{
        budget_identity: identity,
        day: day,
        session_id: "seed",
        spent_usd: dec(spent),
        limit_usd: dec(limit),
        requests: 0,
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0
      })
    end)
  end

  # Operator-wide aggregate for the global-ceiling check: SUM(spent_usd) across all
  # budget identities for `day` (the durable half of Genswarms.LlmProxy global_spent/2).
  def llm_usage_today(day) do
    total =
      Agent.get(@name, fn s ->
        s.daily
        |> Enum.filter(fn {{_id, d}, _row} -> d == day end)
        |> Enum.reduce(Decimal.new("0"), fn {_k, row}, acc -> Decimal.add(acc, row.spent_usd) end)
      end)

    %{spent_usd: total}
  end

  def llm_budget_status(identity, day, session_id, default_limit) do
    Agent.get_and_update(@name, fn state ->
      key = {identity, day}

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

      row = %{row | session_id: session_id}
      {row, put_in(state, [:daily, key], row)}
    end)
  end

  def record_llm_call(identity, day, session_id, attrs) do
    Agent.get_and_update(@name, fn state ->
      key = {identity, day}
      cost = dec(attrs[:cost_usd] || attrs["cost_usd"] || "0")
      prompt = attrs[:prompt_tokens] || 0
      completion = attrs[:completion_tokens] || 0
      total = attrs[:total_tokens] || prompt + completion
      # L4 (LENIENT): only status:"ok" burns the daily request quota — mirrors the
      # real store.ex `record_llm_call` SQL gate (CASE WHEN status = 'ok' THEN 1 ELSE 0).
      status = to_string(attrs[:status] || attrs["status"] || "ok")

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

      row = %{
        row
        | session_id: session_id,
          spent_usd: Decimal.add(row.spent_usd, cost),
          requests: row.requests + if(status == "ok", do: 1, else: 0),
          prompt_tokens: row.prompt_tokens + prompt,
          completion_tokens: row.completion_tokens + completion,
          total_tokens: row.total_tokens + total
      }

      event =
        attrs
        |> Map.take([
          :request_id,
          :status,
          :model,
          :prompt_tokens,
          :completion_tokens,
          :total_tokens,
          :provider
        ])
        |> Map.merge(%{
          budget_identity: identity,
          day: day,
          session_id: session_id,
          cost_usd: cost
        })

      {row, %{state | daily: Map.put(state.daily, key, row), events: [event | state.events]}}
    end)
  end

  def usage(identity, day), do: Agent.get(@name, &Map.get(&1.daily, {identity, day}))
  def events, do: Agent.get(@name, &Enum.reverse(&1.events))

  def llm_usage_for_budget(identity, day, default_limit) do
    Agent.get(@name, fn state ->
      Map.get(state.daily, {identity, day}) ||
        %{
          budget_identity: identity,
          day: day,
          session_id: "",
          spent_usd: Decimal.new("0"),
          limit_usd: dec(default_limit),
          requests: 0,
          prompt_tokens: 0,
          completion_tokens: 0,
          total_tokens: 0,
          cached_tokens: 0,
          non_cached_tokens: 0
        }
    end)
  end

  def llm_usage_by_budget(day, _limit) do
    Agent.get(@name, fn state ->
      state.daily
      |> Enum.filter(fn {{_identity, d}, _row} -> d == day end)
      |> Enum.map(fn {_key, row} ->
        row
        |> Map.put_new(:cached_tokens, 0)
        |> Map.put_new(:non_cached_tokens, 0)
      end)
    end)
  end

  defp dec(%Decimal{} = value), do: value
  defp dec(value), do: Decimal.new(to_string(value))
end

defmodule ProxyCheck.TestLLMProxyNoStore do
  def llm_budget_status(_identity, _day, _session_id, _default_limit), do: nil
  def record_llm_call(_identity, _day, _session_id, _attrs), do: nil
  def llm_usage_for_budget(_identity, _day, _default_limit), do: nil
  def llm_usage_today(_day), do: nil
end

{:ok, state_pid} = Proxy.start_state_link()
{:ok, _store} = ProxyCheck.TestLLMProxyStore.start_link()
ProxyCheck.TestLLMProxyStore.reset()

# /healthz works with a Plug built from NO opts — proving the wingston put_new defaults
# (injected store_mod etc.) are wired and the proxy never references the old
# MicroMarkets.Store. (healthz never touches a store, so this can't crash on defaults.)
healthz_conn =
  conn(:get, "/healthz")
  |> ProxyPlug.call(ProxyPlug.init(%{}))

check.(
  "GET /healthz returns 200 ok with the default (opt-less) plug",
  healthz_conn.status == 200 and json.(healthz_conn) == %{"ok" => true}
)

base_identity_attrs = %{
  conversation_id: "tg:123:0",
  slot: :agent_0,
  kind: :dm,
  workspace_key: "irvine"
}

budget_identity = Proxy.budget_identity(base_identity_attrs)
same_budget_identity = Proxy.budget_identity(%{base_identity_attrs | slot: :agent_99})

other_budget_identity =
  Proxy.budget_identity(%{base_identity_attrs | conversation_id: "tg:124:0"})

check.(
  "budget identity is stable from workspace/kind/conversation and not pooled slot",
  budget_identity == same_budget_identity and budget_identity != other_budget_identity and
    is_binary(budget_identity) and not String.contains?(budget_identity, "tg:123") and
    not String.contains?(budget_identity, "agent_0")
)

today = ~D[2026-06-25]
tomorrow = ~D[2026-06-26]
today_session = Proxy.upstream_session_id(budget_identity, today)
tomorrow_session = Proxy.upstream_session_id(budget_identity, tomorrow)

check.(
  "unhardcoded session id is deterministic per budget identity and UTC day",
  today_session == Proxy.upstream_session_id(budget_identity, today) and
    today_session != tomorrow_session and not String.contains?(today_session, "tg:123")
)

{:ok, token} =
  Proxy.register_session(state_pid, base_identity_attrs)

session = Proxy.lookup_session(state_pid, token)

check.(
  "register_session/2 returns an opaque bearer token mapped to deterministic host identity",
  is_binary(token) and byte_size(token) >= 32 and session.conversation_id == "tg:123:0" and
    session.slot == "agent_0" and session.kind == "dm" and session.workspace_key == "irvine" and
    session.budget_identity == budget_identity and not String.contains?(token, "tg:123")
)

{:ok, second_token} =
  Proxy.register_session(state_pid, %{
    conversation_id: "tg:123:0",
    slot: :agent_0,
    kind: :dm,
    workspace_key: "irvine"
  })

second_session = Proxy.lookup_session(state_pid, second_token)

check.(
  "each registration gets a distinct opaque bearer token",
  second_token != token and second_session.budget_identity == session.budget_identity and
    second_session.conversation_id == session.conversation_id and
    second_session.slot == session.slot
)

check.(
  "new slot registration invalidates stale bearer tokens",
  Proxy.lookup_session(state_pid, token) == nil and
    Proxy.lookup_session(state_pid, second_token) == second_session and
    Agent.get(state_pid, &(map_size(&1.sessions) == 1))
)

active_token = second_token

base_opts = %{
  state_pid: state_pid,
  upstream_endpoint: "https://llm.example/v1/chat/completions",
  upstream_api_key: "upstream-secret",
  provider: "unit",
  prices: %{prompt_per_mtok: 0.25, completion_per_mtok: 0.75},
  store_mod: ProxyCheck.TestLLMProxyStore,
  clock: fn -> ~U[2026-06-25 12:00:00Z] end,
  swarm_name: "wingston",
  sender: :sender,
  deliver_fn: fn swarm_name, to, from, content ->
    send(self(), {:delivered, swarm_name, to, from, Jason.decode!(content)})
    :ok
  end
}

unauth_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(%{"model" => "gpt-test", "messages" => []}))
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(base_opts))

check.("unauthorized requests are rejected", unauth_conn.status == 401)

upstream_seen = self()

ok_upstream = fn body, headers, cfg ->
  send(upstream_seen, {:upstream_call, body, headers, cfg})

  {:ok, 200,
   %{
     "id" => "chatcmpl-upstream",
     "object" => "chat.completion",
     "created" => 1_750_000_000,
     "model" => "gpt-test-served",
     "choices" => [
       %{
         "index" => 0,
         "message" => %{"role" => "assistant", "content" => "pong"},
         "finish_reason" => "stop"
       }
     ],
     "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 4, "total_tokens" => 16},
     "x_router" => %{
       "provider" => "openrouter",
       "model_family" => "deepseek-v3",
       "served_model_id" => "deepseek/deepseek-chat",
       "price_in" => 0.14,
       "price_out" => 0.28,
       "cost_usd" => 0.000123,
       "policy_fingerprint" => "fp1",
       "decision_trace" => %{
         "decision_path" => [%{"event" => "attempted", "provider_id" => "openrouter"}]
       },
       "unsafe_extra" => "secret prompt text"
     }
   }}
end

body = %{
  "model" => "gpt-test",
  "messages" => [%{"role" => "user", "content" => "secret prompt text"}]
}

ok_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{active_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :upstream, ok_upstream)))

ok_body = json.(ok_conn)

receive do
  {:upstream_call, seen_body, seen_headers, seen_cfg} ->
    check.(
      "authorized requests forward the OpenAI body with unhardcoded session; the dead Authorization header copy is gone (B4 — http_upstream builds auth from the 0600 --config, never from this list)",
      seen_body["model"] == body["model"] and
        seen_body["session"] == today_session and
        {"x-unhardcoded-session", today_session} in seen_headers and
        not Enum.any?(seen_headers, fn {k, _v} -> k == "authorization" end) and
        seen_cfg.upstream_endpoint == "https://llm.example/v1/chat/completions"
    )

    [seen_msg] = seen_body["messages"]

    check.(
      "proxy marks the (sole/system/last) message with an ephemeral cache_control breakpoint before forwarding",
      match?(
        [
          %{
            "type" => "text",
            "text" => "secret prompt text",
            "cache_control" => %{"type" => "ephemeral"}
          }
        ],
        seen_msg["content"]
      )
    )

    check.(
      "every non-messages body key is forwarded untouched (full-body equality minus the marked messages)",
      Map.drop(seen_body, ["messages", "session"]) == Map.drop(body, ["messages"])
    )
after
  100 ->
    check.(
      "authorized requests forward the OpenAI body with host key and unhardcoded session",
      false
    )
end

# ── mark_prompt_cache/1 direct coverage (multi-message + guard cases) ─────────
marked_multi =
  ProxyPlug.mark_prompt_cache(%{
    "model" => "m",
    "temperature" => 0.7,
    "messages" => [
      %{"role" => "system", "content" => "sys prompt"},
      %{"role" => "user", "content" => "q1"},
      %{"role" => "assistant", "content" => "a1"},
      %{"role" => "tool", "content" => "tool result"}
    ]
  })

multi_msgs = marked_multi["messages"]

check.(
  "mark_prompt_cache multi-message: system message (not just last) gets the breakpoint",
  match?(
    [%{"type" => "text", "text" => "sys prompt", "cache_control" => %{"type" => "ephemeral"}}],
    Enum.at(multi_msgs, 0)["content"]
  )
)

check.(
  "mark_prompt_cache multi-message: middle messages stay untouched plain strings",
  Enum.at(multi_msgs, 1)["content"] == "q1" and Enum.at(multi_msgs, 2)["content"] == "a1"
)

check.(
  "mark_prompt_cache multi-message: last (tool-role, the dominant agent-loop shape) gets the breakpoint",
  match?(
    [%{"type" => "text", "text" => "tool result", "cache_control" => %{"type" => "ephemeral"}}],
    Enum.at(multi_msgs, 3)["content"]
  )
)

check.(
  "mark_prompt_cache preserves every non-messages key",
  marked_multi["model"] == "m" and marked_multi["temperature"] == 0.7
)

# Anthropic rejects cache_control on EMPTY text blocks — the list clause must
# mirror the string clause's non-empty guard.
marked_empty_block =
  ProxyPlug.mark_prompt_cache(%{
    "messages" => [%{"role" => "assistant", "content" => [%{"type" => "text", "text" => ""}]}]
  })

check.(
  "mark_prompt_cache skips empty text blocks (Anthropic 400s on cache_control there)",
  marked_empty_block["messages"] == [
    %{"role" => "assistant", "content" => [%{"type" => "text", "text" => ""}]}
  ]
)

check.(
  "mark_prompt_cache no-ops on empty/missing messages",
  ProxyPlug.mark_prompt_cache(%{"messages" => []}) == %{"messages" => []} and
    ProxyPlug.mark_prompt_cache(%{"model" => "x"}) == %{"model" => "x"}
)

# A cache-aware client that already placed its own breakpoints knows better than
# the proxy — injecting more could exceed Anthropic's 4-breakpoint limit (400).
client_marked_body = %{
  "messages" => [
    %{
      "role" => "system",
      "content" => [
        %{"type" => "text", "text" => "sys", "cache_control" => %{"type" => "ephemeral"}}
      ]
    },
    %{"role" => "user", "content" => "q"}
  ]
}

check.(
  "mark_prompt_cache defers to client-supplied breakpoints (no injection when any cache_control already present)",
  ProxyPlug.mark_prompt_cache(client_marked_body) == client_marked_body
)

# Kill switch: prompt_cache: false must forward the body with NO marking at all
# (plain string content survives), so ops can disable injection without a deploy.
# Isolated on its OWN state agent + session so this extra request never skews the
# shared state_pid's in-memory counts that later dashboard checks assert on.
{:ok, ks_state} = Proxy.start_state_link()

{:ok, ks_token} =
  Proxy.register_session(ks_state, %{
    conversation_id: "tg:999123:0",
    slot: :agent_ks,
    kind: :dm,
    workspace_key: "irvine"
  })

kill_switch_upstream = fn ks_seen_body, _headers, _cfg ->
  send(self(), {:kill_switch_call, ks_seen_body})

  {:ok, 200,
   %{
     "id" => "chatcmpl-ks",
     "object" => "chat.completion",
     "created" => 1_750_000_000,
     "model" => "gpt-test-served",
     "choices" => [
       %{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}
     ],
     "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
   }}
end

_ =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{ks_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(
      base_opts
      |> Map.put(:state_pid, ks_state)
      |> Map.put(:upstream, kill_switch_upstream)
      |> Map.put(:prompt_cache, false)
    )
  )

receive do
  {:kill_switch_call, ks_body} ->
    check.(
      "prompt_cache: false disables cache marking (content forwarded as the original plain string)",
      match?([%{"content" => "secret prompt text"}], ks_body["messages"])
    )
after
  100 ->
    check.("prompt_cache: false disables cache marking (content forwarded as the original plain string)", false)
end

check.(
  "OpenAI-compatible responses preserve choices and usage",
  ok_conn.status == 200 and
    get_in(ok_body, ["choices", Access.at(0), "message", "content"]) == "pong" and
    ok_body["usage"] == %{"prompt_tokens" => 12, "completion_tokens" => 4, "total_tokens" => 16}
)

xr = ok_body["x_router"] || %{}

check.(
  "x_router metadata is useful, re-stamped, and sanitized",
  xr["provider"] == "openrouter" and xr["model_family"] == "deepseek-v3" and
    xr["served_model_id"] == "deepseek/deepseek-chat" and
    xr["served_model"] == "deepseek/deepseek-chat" and xr["cost_usd"] == 0.000123 and
    xr["price_in"] == 0.14 and xr["price_out"] == 0.28 and
    get_in(xr, ["decision_trace", "decision_path"]) != nil and
    xr["request_id"] != nil and xr["session_id"] == today_session and
    xr["prompt_tokens"] == 12 and xr["completion_tokens"] == 4 and
    is_number(xr["latency_ms"]) and is_number(xr["cost_usd"]) and
    not String.contains?(Jason.encode!(xr), "upstream-secret") and
    not String.contains?(Jason.encode!(xr), "secret prompt text") and
    not String.contains?(Jason.encode!(xr), "tg:123")
)

totals = Proxy.usage_totals(state_pid)

check.(
  "usage totals are keyed by opaque budget identity without raw conversation id",
  Enum.any?(totals, fn row ->
    row.budget_identity == budget_identity and row.session_id == today_session and
      row.model == "deepseek/deepseek-chat" and row.status == "ok" and
      row.prompt_tokens == 12 and row.completion_tokens == 4 and row.total_tokens == 16 and
      Decimal.equal?(row.cost_usd, Decimal.new("0.000123")) and
      not Map.has_key?(row, :conversation_id)
  end)
)

check.(
  "call events record the router's provider for later cache-rate-by-backend correlation",
  Enum.any?(ProxyCheck.TestLLMProxyStore.events(), fn event ->
    event[:model] == "deepseek/deepseek-chat" and event[:provider] == "openrouter"
  end)
)

dashboard_ext =
  Proxy.dashboard_extension(
    state_pid: state_pid,
    store_mod: nil,
    day: today,
    users_by_cid: %{"tg:123:0" => %{handle: "alice", name: "Alice"}}
  )

dashboard_page = dashboard_ext["dashboard_pages"] |> hd()
dashboard_table = Enum.find(dashboard_page["sections"], &(&1["type"] == "table"))
dashboard_row = dashboard_table["rows"] |> hd()

check.(
  "dashboard extension publishes a generic proxy-router page with per-user spend and unmapped budget ids",
  dashboard_ext["proxy_router"]["requests"] == 1 and
    dashboard_table["meta"] == "unmapped rows come from budget hashes" and
    dashboard_page["id"] == "proxy-router" and
    dashboard_row["user"] == "@alice · Alice" and
    dashboard_row["spent"] == "$0.000123" and
    String.starts_with?(dashboard_row["budget"], "llmb_") and
    not String.contains?(dashboard_row["budget"], "tg:123")
)

budget_health_rules = [
  %{
    "id" => "budget_guard_75",
    "severity" => "info",
    "card" => "LLM spend at 75% of the daily ceiling",
    "where" => %{"op" => "gt", "lhs" => %{"path" => "ceiling_usd"}, "rhs" => 0},
    "when" => %{
      "op" => "gte",
      "lhs" => %{"div" => [%{"path" => "spent_usd"}, %{"path" => "ceiling_usd"}]},
      "rhs" => 0.75
    }
  },
  %{
    "id" => "budget_guard_90",
    "severity" => "warn",
    "card" => "LLM spend at 90% of the daily ceiling — agents hard-block at 100%",
    "where" => %{"op" => "gt", "lhs" => %{"path" => "ceiling_usd"}, "rhs" => 0},
    "when" => %{
      "op" => "gte",
      "lhs" => %{"div" => [%{"path" => "spent_usd"}, %{"path" => "ceiling_usd"}]},
      "rhs" => 0.90
    }
  }
]

# A live proxy with an operator-configured global ceiling: the machine block
# publishes it as a float twin of the existing string-formatted totals.
Agent.update(state_pid, fn s ->
  Map.put(s, :quota, %{
    global_daily_limit: Decimal.new("10"),
    default_daily_limit: Decimal.new("0.5")
  })
end)

budget_dashboard_ext =
  Proxy.dashboard_extension(
    state_pid: state_pid,
    store_mod: nil,
    day: today,
    users_by_cid: %{"tg:123:0" => %{handle: "alice", name: "Alice"}}
  )

budget_block = budget_dashboard_ext["llm_proxy_budget"]

check.(
  "llm_proxy_budget machine block publishes numeric ceiling/spend/default + the exact shipped health_rules",
  budget_block["v"] == 1 and
    budget_block["ceiling_usd"] == 10.0 and
    budget_block["spent_usd"] == 0.000123 and
    budget_block["default_daily_limit_usd"] == 0.5 and
    budget_block["health_rules"] == budget_health_rules and
    # existing blocks stay untouched (mm vocabulary — additive only)
    budget_dashboard_ext["llm_proxy"]["spent_usd"] == "0.000123" and
    budget_dashboard_ext["proxy_router"]["requests"] == 1
)

{:ok, idle_dashboard_state} = Proxy.start_state_link()

idle_dashboard_ext =
  Proxy.dashboard_extension(
    state_pid: idle_dashboard_state,
    store_mod: nil,
    day: today
  )

idle_dashboard_page = idle_dashboard_ext["dashboard_pages"] |> hd()

check.(
  "dashboard extension registers the proxy-router page while the enabled proxy is idle",
  idle_dashboard_ext["proxy_router"]["requests"] == 0 and
    idle_dashboard_page["id"] == "proxy-router" and
    Enum.any?(idle_dashboard_page["sections"], &(&1["type"] == "table" and &1["rows"] == []))
)

check.(
  "llm_proxy_budget ceiling defaults to 0.0 (disabled) when no quota was configured on the Agent — the shipped rules stay present, inert via their own where-guard",
  idle_dashboard_ext["llm_proxy_budget"]["ceiling_usd"] == 0.0 and
    idle_dashboard_ext["llm_proxy_budget"]["default_daily_limit_usd"] == 0.0 and
    idle_dashboard_ext["llm_proxy_budget"]["health_rules"] == budget_health_rules
)

check.(
  "dashboard extension stays hidden when the proxy state is absent",
  Proxy.dashboard_extension(
    state_pid: :definitely_missing_proxy_state,
    store_mod: nil,
    day: today
  ) == %{}
)

{:ok, empty_dashboard_state} = Proxy.start_state_link()

durable_dashboard_ext =
  Proxy.dashboard_extension(
    state_pid: empty_dashboard_state,
    store_mod: ProxyCheck.TestLLMProxyStore,
    day: today,
    users_by_budget: %{budget_identity => %{handle: "alice", name: "Alice"}}
  )

durable_dashboard_page = durable_dashboard_ext["dashboard_pages"] |> hd()
durable_dashboard_table = Enum.find(durable_dashboard_page["sections"], &(&1["type"] == "table"))
durable_dashboard_row = durable_dashboard_table["rows"] |> hd()

check.(
  "dashboard extension can label durable Postgres rows after proxy restart via budget identity map",
  durable_dashboard_ext["proxy_router"]["source"] == "postgres" and
    durable_dashboard_row["user"] == "@alice · Alice" and
    durable_dashboard_row["spent"] == "$0.000123"
)

group_budget_identity =
  Proxy.budget_identity(%{
    conversation_id: "tg:-1001234567890:5",
    kind: :group,
    workspace_key: "default"
  })

ProxyCheck.TestLLMProxyStore.seed_usage(group_budget_identity, today, "0.02")

group_origin_dashboard_ext =
  Proxy.dashboard_extension(
    state_pid: empty_dashboard_state,
    store_mod: ProxyCheck.TestLLMProxyStore,
    day: today,
    origins_by_budget: %{
      group_budget_identity => %{
        kind: "group",
        conversation_id: "tg:-1001234567890:5",
        label: "Telegram group tg:-1001234567890:5"
      }
    }
  )

group_origin_dashboard_page = group_origin_dashboard_ext["dashboard_pages"] |> hd()

group_origin_dashboard_table =
  Enum.find(group_origin_dashboard_page["sections"], &(&1["type"] == "table"))

group_short_budget =
  "llmb_" <> (group_budget_identity |> String.replace_prefix("llmb_", "") |> String.slice(0, 10))

group_origin_dashboard_row =
  Enum.find(group_origin_dashboard_table["rows"], &(&1["budget"] == group_short_budget))

check.(
  "dashboard extension labels durable group budget rows from the persisted origin map",
  group_origin_dashboard_row["user"] == "Telegram group tg:-1001234567890:5" and
    group_origin_dashboard_row["slot"] == "—"
)

usage = ProxyCheck.TestLLMProxyStore.usage(budget_identity, today)

check.(
  "DB daily usage insert/update uses the default $0.50 UTC-day limit",
  usage.session_id == today_session and Decimal.equal?(usage.limit_usd, Decimal.new("0.50")) and
    Decimal.equal?(usage.spent_usd, Decimal.new("0.000123")) and usage.requests == 1
)

premium_attrs =
  Map.merge(base_identity_attrs, %{
    conversation_id: "tg:456:0",
    slot: :agent_1,
    daily_limit_usd: Decimal.new("1.00")
  })

premium_identity = Proxy.budget_identity(premium_attrs)
{:ok, premium_token} = Proxy.register_session(state_pid, premium_attrs)

premium_upstream = fn _body, _headers, _cfg ->
  {:ok, 200,
   %{
     "id" => "chatcmpl-premium",
     "object" => "chat.completion",
     "created" => 1_750_000_001,
     "model" => "gpt-test-served",
     "choices" => [
       %{
         "index" => 0,
         "message" => %{"role" => "assistant", "content" => "pong"},
         "finish_reason" => "stop"
       }
     ],
     "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2},
     "x_router" => %{"cost_usd" => 0.000123}
   }}
end

premium_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{premium_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :upstream, premium_upstream)))

premium_usage = ProxyCheck.TestLLMProxyStore.usage(premium_identity, today)

check.(
  "Telegram Premium sessions use the $1.00 daily LLM limit",
  premium_conn.status == 200 and Decimal.equal?(premium_usage.limit_usd, Decimal.new("1.00"))
)

{:ok, fallback_state_pid} = Proxy.start_state_link()

fallback_attrs = %{
  conversation_id: "tg:999:0",
  slot: :fallback_agent,
  kind: :dm,
  workspace_key: "irvine"
}

fallback_identity = Proxy.budget_identity(fallback_attrs)
fallback_session_id = Proxy.upstream_session_id(fallback_identity, today)
{:ok, fallback_token} = Proxy.register_session(fallback_state_pid, fallback_attrs)
fallback_session = Proxy.lookup_session(fallback_state_pid, fallback_token)

fallback_opts =
  Map.merge(base_opts, %{
    state_pid: fallback_state_pid,
    store_mod: ProxyCheck.TestLLMProxyNoStore,
    default_daily_limit: Decimal.new("0.0001"),
    upstream: ok_upstream
  })

fallback_first_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{fallback_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(fallback_opts))

# Drain the {:upstream_call, ...} message ok_upstream sent on the first fallback call so it
# can't be mistaken for the (forbidden) second call below.
receive do
  {:upstream_call, _, _, _} -> :ok
after
  100 -> :ok
end

fallback_budget =
  Proxy.fallback_budget_status(
    fallback_state_pid,
    fallback_session,
    today,
    fallback_session_id,
    Decimal.new("0.0001")
  )

fallback_blocked_upstream = fn _body, _headers, _cfg ->
  send(self(), :fallback_blocked_upstream_called)
  {:ok, 200, %{"choices" => []}}
end

fallback_blocked_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{fallback_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(fallback_opts, :upstream, fallback_blocked_upstream)))

fallback_blocked_body = json.(fallback_blocked_conn)

fallback_notice? =
  receive do
    {:delivered, "wingston", :sender, :llm_proxy,
     %{"action" => "slot_reply", "slot" => "fallback_agent", "content" => notice}} ->
      String.contains?(notice, "daily LLM limit") and not String.contains?(notice, "tg:999")
  after
    100 -> false
  end

fallback_upstream_skipped? =
  receive do
    :fallback_blocked_upstream_called -> false
  after
    20 -> true
  end

check.(
  "in-memory fallback enforces daily budget after recorded spend",
  fallback_first_conn.status == 200 and fallback_budget.requests == 1 and
    Decimal.equal?(fallback_budget.spent_usd, Decimal.new("0.000123")) and
    fallback_blocked_conn.status == 200 and fallback_upstream_skipped? and fallback_notice? and
    get_in(fallback_blocked_body, ["x_router", "budget_exhausted"]) == true
)

# ── Per-user/chat daily request quota ────────────────────────────────────────
quota_attrs = %{
  conversation_id: "tg:quota:0",
  slot: :quota_agent,
  kind: :dm,
  workspace_key: "irvine"
}

quota_identity = Proxy.budget_identity(quota_attrs)
{:ok, quota_token} = Proxy.register_session(state_pid, quota_attrs)
{:ok, quota_events} = Agent.start_link(fn -> [] end)

quota_deliver = fn sw, to, from, content ->
  Agent.update(quota_events, &[{sw, to, from, Jason.decode!(content)} | &1])
  :ok
end

quota_ok_upstream = fn _body, _headers, _cfg ->
  {:ok, 200,
   %{
     "id" => "chatcmpl-quota-ok",
     "object" => "chat.completion",
     "created" => 1_750_000_003,
     "model" => "gpt-test-served",
     "choices" => [
       %{
         "index" => 0,
         "message" => %{"role" => "assistant", "content" => "pong"},
         "finish_reason" => "stop"
       }
     ],
     "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2},
     "x_router" => %{"cost_usd" => 0.000001}
   }}
end

quota_opts =
  Map.merge(base_opts, %{
    daily_request_limit: 1,
    deliver_fn: quota_deliver,
    upstream: quota_ok_upstream
  })

quota_first_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{quota_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(quota_opts))

quota_second_upstream = fn _body, _headers, _cfg ->
  send(self(), :quota_second_upstream_called)
  quota_ok_upstream.(%{}, [], %{})
end

quota_second_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{quota_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(quota_opts, :upstream, quota_second_upstream)))

quota_second_body = json.(quota_second_conn)
quota_usage = ProxyCheck.TestLLMProxyStore.usage(quota_identity, today)

quota_upstream_skipped? =
  receive do
    :quota_second_upstream_called -> false
  after
    20 -> true
  end

quota_events_list = Agent.get(quota_events, & &1)

quota_notice? =
  Enum.any?(quota_events_list, fn
    {"wingston", :sender, :llm_proxy,
     %{"action" => "slot_reply", "slot" => "quota_agent", "content" => notice}} ->
      String.contains?(notice, "daily LLM request limit")

    _ ->
      false
  end)

quota_metric? =
  Enum.any?(quota_events_list, fn
    {"wingston", :metrics, :llm_proxy,
     %{"action" => "bump", "key" => "llm_proxy_request_quota_block"}} ->
      true

    _ ->
      false
  end)

check.(
  "daily request quota: limit=1 lets first call through, blocks second before upstream, and emits quota metric",
  quota_first_conn.status == 200 and quota_second_conn.status == 200 and
    quota_upstream_skipped? and quota_notice? and quota_metric? and
    get_in(quota_second_body, ["x_router", "request_quota_exhausted"]) == true and
    get_in(quota_second_body, ["x_router", "request_limit"]) == 1 and
    quota_usage.requests == 1
)

# ── Read-only quota status API for commands/dashboard surfaces ───────────────
quota_status_cid = "tg:424242:0"
quota_status_day = ~D[2026-06-29]

quota_status_identity =
  Proxy.budget_identity(%{
    conversation_id: quota_status_cid,
    kind: "dm",
    workspace_key: "default"
  })

_ =
  ProxyCheck.TestLLMProxyStore.record_llm_call(
    quota_status_identity,
    quota_status_day,
    "sess-quota-status",
    %{
      cost_usd: "0.03",
      prompt_tokens: 100,
      completion_tokens: 40,
      total_tokens: 140,
      model: "gpt-test",
      status: "ok"
    }
  )

quota_status_state = %{
  state_pid: state_pid,
  quota: %{
    store_mod: ProxyCheck.TestLLMProxyStore,
    default_daily_limit: Decimal.new("0.50"),
    daily_request_limit: 30,
    global_daily_limit: Decimal.new("0.30"),
    clock: fn -> ~U[2026-06-29 10:00:00Z] end
  }
}

{:reply, quota_status_json, ^quota_status_state} =
  Proxy.handle_message(
    :commands,
    Jason.encode!(%{
      action: "quota_status",
      conversation_id: quota_status_cid,
      kind: "dm",
      workspace_key: "default"
    }),
    quota_status_state
  )

quota_status_body = Jason.decode!(quota_status_json)

check.(
  "quota_status action is read-only and reports request quota, spend, reset, and source",
  quota_status_body["ok"] == true and quota_status_body["conversation_id"] == quota_status_cid and
    quota_status_body["day"] == "2026-06-29" and
    quota_status_body["reset_at"] == "2026-06-30T00:00:00Z" and
    quota_status_body["source"] == "postgres" and
    quota_status_body["requests"]["used"] == 1 and
    quota_status_body["requests"]["limit"] == 30 and
    quota_status_body["requests"]["remaining"] == 29 and
    quota_status_body["requests"]["pct"] == 3 and
    quota_status_body["spend"]["used_usd"] == "0.030000" and
    quota_status_body["spend"]["limit_usd"] == "0.500000" and
    quota_status_body["spend"]["pct"] == 6 and
    quota_status_body["global"]["limit_usd"] == "0.300000"
)

quota_memory_cid = "tg:424243:0"
quota_memory_day = ~D[2026-06-29]

{:ok, quota_memory_token} =
  Proxy.register_session(state_pid, %{
    conversation_id: quota_memory_cid,
    slot: :agent_quota_memory,
    kind: :dm,
    workspace_key: "default"
  })

quota_memory_session = Proxy.lookup_session(state_pid, quota_memory_token)

quota_memory_session_id =
  Proxy.upstream_session_id(quota_memory_session.budget_identity, quota_memory_day)

Proxy.record_usage(state_pid, quota_memory_session, quota_memory_day, quota_memory_session_id, %{
  cost_usd: "0.04",
  prompt_tokens: 10,
  completion_tokens: 5,
  total_tokens: 15,
  model: "gpt-test",
  status: "ok"
})

quota_memory_state = %{
  state_pid: state_pid,
  quota: %{
    store_mod: ProxyCheck.TestLLMProxyNoStore,
    default_daily_limit: Decimal.new("0.50"),
    daily_request_limit: 30,
    global_daily_limit: Decimal.new("0.30"),
    clock: fn -> ~U[2026-06-29 10:00:00Z] end
  }
}

{:reply, quota_memory_json, ^quota_memory_state} =
  Proxy.handle_message(
    :commands,
    Jason.encode!(%{action: "quota_status", conversation_id: quota_memory_cid, kind: "dm"}),
    quota_memory_state
  )

quota_memory_body = Jason.decode!(quota_memory_json)

check.(
  "quota_status falls back to in-memory usage when the durable store is down",
  quota_memory_body["source"] == "memory" and quota_memory_body["requests"]["used"] == 1 and
    quota_memory_body["spend"]["used_usd"] == "0.040000" and
    quota_memory_body["global"]["used_usd"] == "0.040000"
)

session_acc_upstream = fn _body, _headers, _cfg ->
  {:ok, 200,
   %{
     "id" => "chatcmpl-session-acc",
     "object" => "chat.completion",
     "created" => 1_750_000_001,
     "model" => "gpt-test-served",
     "choices" => [
       %{
         "index" => 0,
         "message" => %{"role" => "assistant", "content" => "pong"},
         "finish_reason" => "stop"
       }
     ],
     "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5},
     "x_router" => %{
       "provider" => "unhardcoded",
       "served_model_id" => "gpt-5.5",
       "session_acc" => %{"calls" => 2, "cost_usd" => 0.0002}
     }
   }}
end

session_acc_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{active_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :upstream, session_acc_upstream)))

usage = ProxyCheck.TestLLMProxyStore.usage(budget_identity, today)

check.(
  "exact cost can be recorded from x_router.session_acc when per-call cost is absent",
  session_acc_conn.status == 200 and Decimal.equal?(usage.spent_usd, Decimal.new("0.0002")) and
    usage.requests == 2
)

events_json = Jason.encode!(ProxyCheck.TestLLMProxyStore.events())

check.(
  "stored LLM budget events contain no prompt, secret, token, or raw conversation id",
  not String.contains?(events_json, "secret prompt text") and
    not String.contains?(events_json, "upstream-secret") and
    not String.contains?(events_json, active_token) and
    not String.contains?(events_json, "tg:123")
)

ProxyCheck.TestLLMProxyStore.seed_usage(budget_identity, today, "0.50")

budget_blocked_upstream = fn _body, _headers, _cfg ->
  send(self(), :budget_blocked_upstream_called)
  {:error, 429, %{"error" => %{"message" => "raw upstream 429", "code" => "rate_limit"}}}
end

blocked_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{active_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :upstream, budget_blocked_upstream)))

blocked_body = json.(blocked_conn)
blocked_json = Jason.encode!(blocked_body)

delivered_budget_notice? =
  receive do
    {:delivered, "wingston", :sender, :llm_proxy,
     %{"action" => "slot_reply", "slot" => "agent_0", "content" => notice}} ->
      notice ==
        "⏳ This chat reached its daily LLM limit. Try again tomorrow at 00:00 UTC (2026-06-26)." and
        not String.contains?(notice, "tg:123")
  after
    100 -> false
  end

upstream_skipped? =
  receive do
    :budget_blocked_upstream_called -> false
  after
    20 -> true
  end

check.(
  "budget exhaustion sends deterministic Telegram notice and returns harmless synthetic response",
  blocked_conn.status == 200 and upstream_skipped? and delivered_budget_notice? and
    get_in(blocked_body, ["choices", Access.at(0), "message", "content"]) =~ "daily LLM limit" and
    blocked_body["model"] == "llm-proxy-budget" and
    not String.contains?(blocked_json, "429") and not String.contains?(blocked_json, "tg:123")
)

rollover_seen = self()

rollover_upstream = fn seen_body, seen_headers, _cfg ->
  send(rollover_seen, {:rollover_upstream, seen_body, seen_headers})

  {:ok, 200,
   Map.put(ok_upstream.(seen_body, seen_headers, %{}) |> elem(2), "x_router", %{
     "cost_usd" => 0.000001
   })}
end

# ok_upstream above also sends an {:upstream_call, ...}; drain it after the rollover call.
rollover_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{active_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(
      Map.merge(base_opts, %{
        clock: fn -> ~U[2026-06-26 00:00:01Z] end,
        upstream: rollover_upstream
      })
    )
  )

receive do
  {:upstream_call, _, _, _} -> :ok
after
  100 -> :ok
end

rollover_session_seen? =
  receive do
    {:rollover_upstream, seen_body, seen_headers} ->
      seen_body["session"] == tomorrow_session and
        {"x-unhardcoded-session", tomorrow_session} in seen_headers
  after
    100 -> false
  end

check.(
  "UTC day rollover resets budget and injects the new day's session id",
  rollover_conn.status == 200 and rollover_session_seen? and
    Decimal.equal?(
      ProxyCheck.TestLLMProxyStore.usage(budget_identity, tomorrow).spent_usd,
      Decimal.new("0.000001")
    )
)

ProxyCheck.TestLLMProxyStore.seed_usage(budget_identity, today, "0.0002")

error_upstream = fn _body, _headers, _cfg ->
  {:error, 429,
   %{"error" => %{"message" => String.duplicate("rate limit ", 80), "code" => "rate_limit"}}}
end

err_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{active_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :upstream, error_upstream)))

err_body = json.(err_conn)
err_json = Jason.encode!(err_body)

check.(
  "upstream errors map through with bounded sanitized x_router metadata",
  err_conn.status == 429 and get_in(err_body, ["error", "code"]) == "rate_limit" and
    byte_size(get_in(err_body, ["x_router", "error"]) || "") <= 220 and
    not String.contains?(err_json, "upstream-secret") and
    not String.contains?(err_json, "secret prompt text") and
    not String.contains?(err_json, "tg:123")
)

# ── Fix 1: curl arg-assembly + auth-config offline tests ─────────────────────

test_api_key = "sk-test-api-key-xyz"
test_session_id = "llms_test_session_abc"
cfg_content = ProxyPlug.auth_config(test_api_key, test_session_id)

check.(
  "auth_config/2 contains Authorization: Bearer header line",
  String.contains?(cfg_content, ~s(header = "Authorization: Bearer #{test_api_key}"))
)

check.(
  "auth_config/2 contains x-unhardcoded-session header line",
  String.contains?(cfg_content, ~s(header = "x-unhardcoded-session: #{test_session_id}"))
)

fake_body_path = "/tmp/test-body-proxy.json"
fake_cfg_path = "/tmp/test-cfg-proxy.conf"
args_endpoint = "https://llm.example/v1/chat/completions"
test_args = ProxyPlug.curl_args(fake_body_path, args_endpoint, fake_cfg_path, %{})

# Helper: true when `a` and `b` appear consecutively in `list`.
adjacent? = fn list, a, b ->
  list |> Enum.zip(tl(list)) |> Enum.any?(fn {x, y} -> x == a and y == b end)
end

check.(
  "curl_args/4 contains --config, --data-binary @body, --max-time 120, --connect-timeout 10, -H Expect:, Content-Type, endpoint-last",
  "--config" in test_args and
    fake_cfg_path in test_args and
    "--data-binary" in test_args and
    "@#{fake_body_path}" in test_args and
    adjacent?.(test_args, "--max-time", "120") and
    adjacent?.(test_args, "--connect-timeout", "10") and
    adjacent?.(test_args, "-H", "Expect:") and
    "Content-Type: application/json" in test_args and
    args_endpoint in test_args and
    List.last(test_args) == args_endpoint
)

# Non-vacuous: thread BOTH secrets through the opts map curl_args actually RECEIVES, and prove
# they still never appear in argv (they must ride the 0600 --config file / body file). With the
# old `%{}` opts the key/session were never in scope, so the assertion could not have failed.
secret_args =
  ProxyPlug.curl_args(fake_body_path, args_endpoint, fake_cfg_path, %{
    upstream_api_key: test_api_key,
    upstream_session_id: test_session_id
  })

check.(
  "curl_args/4 keeps the api key + session id (passed via opts) OUT of argv — they ride --config, never an argument",
  fake_cfg_path in secret_args and "@#{fake_body_path}" in secret_args and
    not Enum.any?(secret_args, &String.contains?(to_string(&1), test_api_key)) and
    not Enum.any?(secret_args, &String.contains?(to_string(&1), test_session_id))
)

# ── Task 5: configurable timeouts + 100-continue suppression ─────────────────

# T5-1: explicit opts override defaults. The secrets are threaded through opts too, so the
# T5-3 no-leak assertion below is non-vacuous (curl_args must never copy them into argv).
custom_args =
  ProxyPlug.curl_args("/b", "http://x", "/c", %{
    upstream_timeout_s: 45,
    connect_timeout_s: 7,
    upstream_api_key: test_api_key,
    upstream_session_id: test_session_id
  })

check.(
  "curl_args/4 with explicit opts uses upstream_timeout_s:45 and connect_timeout_s:7",
  adjacent?.(custom_args, "--max-time", "45") and
    adjacent?.(custom_args, "--connect-timeout", "7") and
    adjacent?.(custom_args, "-H", "Expect:") and
    adjacent?.(custom_args, "--config", "/c") and
    adjacent?.(custom_args, "--data-binary", "@/b") and
    List.last(custom_args) == "http://x"
)

# T5-2: empty opts fall back to defaults (120 / 10)
default_args = ProxyPlug.curl_args("/b", "http://x", "/c", %{})

check.(
  "curl_args/4 with empty opts defaults to --max-time 120 and --connect-timeout 10",
  adjacent?.(default_args, "--max-time", "120") and
    adjacent?.(default_args, "--connect-timeout", "10")
)

# T5-3: secrets-in-config invariant holds with explicit opts too
check.(
  "curl_args/4 output (explicit opts) contains neither api key nor session id",
  not Enum.any?(custom_args, &String.contains?(to_string(&1), test_api_key)) and
    not Enum.any?(custom_args, &String.contains?(to_string(&1), test_session_id))
)

# T5-4: behavioral — upstream_timeout_s is actually honored by curl (~5s total)
#
# A Bandit stub sleeps 2000ms before replying. With upstream_timeout_s: 1 curl exits
# with code 28 (CURLE_OPERATION_TIMEDOUT) → http_upstream returns {:error, {:curl, 28}}.
# With upstream_timeout_s: 4 the request completes → {:ok, 200, _}.
Application.ensure_all_started(:bandit)

defmodule Genswarms.LlmProxy.SlowStub do
  @moduledoc false
  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, _body, conn} = Plug.Conn.read_body(conn)
    Process.sleep(2000)

    resp =
      Jason.encode!(%{
        "id" => "chatcmpl-stub",
        "object" => "chat.completion",
        "created" => 1_750_000_000,
        "model" => "stub-model",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "ok"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      })

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, resp)
  end
end

# port: 0 → OS-assigned free port (read back via ThousandIsland) so a fixed-port collision
# can never abort the whole suite. Mirrors the other Bandit stubs in this branch.
{:ok, stub_pid} =
  Bandit.start_link(plug: Genswarms.LlmProxy.SlowStub, scheme: :http, ip: {127, 0, 0, 1}, port: 0)

{:ok, {_stub_addr, stub_port}} = ThousandIsland.listener_info(stub_pid)
stub_endpoint = "http://127.0.0.1:#{stub_port}/v1/chat/completions"
stub_body = %{"model" => "test", "messages" => [%{"role" => "user", "content" => "hi"}]}

stub_headers = [
  {"authorization", "Bearer sk-test-timeout-key"},
  {"x-unhardcoded-session", "test-timeout-session-id"}
]

# 1s limit — stub takes 2s → curl times out (exit 28)
timeout_result =
  ProxyPlug.http_upstream(stub_body, stub_headers, %{
    upstream_endpoint: stub_endpoint,
    upstream_api_key: "sk-test-timeout-key",
    upstream_timeout_s: 1,
    connect_timeout_s: 5
  })

# 4s limit — stub takes 2s → succeeds
success_result =
  ProxyPlug.http_upstream(stub_body, stub_headers, %{
    upstream_endpoint: stub_endpoint,
    upstream_api_key: "sk-test-timeout-key",
    upstream_timeout_s: 4,
    connect_timeout_s: 5
  })

GenServer.stop(stub_pid)

check.(
  "upstream_timeout_s honored: curl exit 28 on 1s limit, 200 ok on 4s limit (stub sleeps 2s)",
  match?({:error, {:curl, 28}}, timeout_result) and match?({:ok, 200, _}, success_result)
)

priv_path = ProxyPlug.write_private_tmp("wingston-test-mode", "test content")
{:ok, priv_stat} = File.stat(priv_path)
File.rm(priv_path)

check.(
  "write_private_tmp/2 creates a file with mode 0600 (rwx bits only)",
  # rem/2 extracts the bottom 3 octal digits (rwxrwxrwx permission bits)
  rem(priv_stat.mode, 0o1000) == 0o600
)

# ── Fix 2: present-but-unknown bearer → 401 ──────────────────────────────────

garbage_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(%{"model" => "gpt-test", "messages" => []}))
  |> put_req_header("authorization", "Bearer totally-garbage-token-xyz")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(base_opts))

garbage_body = json.(garbage_conn)

check.(
  "unknown (present but unmapped) bearer token returns 401 with 'unknown bearer token' message",
  garbage_conn.status == 401 and
    get_in(garbage_body, ["error", "message"]) == "unknown bearer token"
)

# ── Fix 3: upstream error → 502 branches (via injected :upstream seam) ───────

# 3a: {:error, reason} bare tuple — call_upstream maps to {502, error_map}
ProxyCheck.TestLLMProxyStore.seed_usage(budget_identity, today, "0.0002")

error_reason_upstream = fn _body, _headers, _cfg -> {:error, :econnrefused} end

err_reason_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{active_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :upstream, error_reason_upstream)))

check.(
  "upstream {:error, reason} bare tuple maps to 502 response",
  err_reason_conn.status == 502
)

# 3b: {:error, 502, decode_error_map} — simulates http_upstream returning a 502 when the
# upstream body is non-JSON (the decode-error path in http_upstream/3).
ProxyCheck.TestLLMProxyStore.seed_usage(budget_identity, today, "0.0002")

decode_error_upstream = fn _body, _headers, _cfg ->
  {:error, 502,
   %{
     "error" => %{
       "message" => "upstream returned non-JSON response",
       "type" => "upstream_error",
       "code" => "upstream_invalid_json"
     }
   }}
end

decode_err_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{active_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :upstream, decode_error_upstream)))

decode_err_body = json.(decode_err_conn)

check.(
  "upstream decode-error {:error, 502, map} results in 502 with upstream_invalid_json code",
  decode_err_conn.status == 502 and
    get_in(decode_err_body, ["error", "code"]) == "upstream_invalid_json"
)

# ── Fix 4: negative upstream cost_usd is floored to 0 (ledger defense) ───────
#
# A buggy or misconfigured upstream returning a negative x_router.cost_usd
# must NOT decrement the budget (spent_usd). The direct cost branch in
# executed_cost_usd/4 now applies the same max_decimal(..., 0) floor as the
# session_acc delta branch.

ProxyCheck.TestLLMProxyStore.reset()

negative_cost_attrs = %{
  conversation_id: "tg:777:0",
  slot: :agent_neg,
  kind: :dm,
  workspace_key: "irvine"
}

negative_cost_identity = Proxy.budget_identity(negative_cost_attrs)
{:ok, neg_token} = Proxy.register_session(state_pid, negative_cost_attrs)

negative_cost_upstream = fn _body, _headers, _cfg ->
  {:ok, 200,
   %{
     "id" => "chatcmpl-neg-cost",
     "object" => "chat.completion",
     "created" => 1_750_000_002,
     "model" => "gpt-test-served",
     "choices" => [
       %{
         "index" => 0,
         "message" => %{"role" => "assistant", "content" => "pong"},
         "finish_reason" => "stop"
       }
     ],
     "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8},
     "x_router" => %{
       "provider" => "unit",
       "served_model_id" => "gpt-test",
       "cost_usd" => -5.0
     }
   }}
end

neg_cost_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{neg_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :upstream, negative_cost_upstream)))

neg_cost_usage = ProxyCheck.TestLLMProxyStore.usage(negative_cost_identity, today)

check.(
  "negative upstream x_router.cost_usd is floored to 0 (spent_usd never decrements)",
  neg_cost_conn.status == 200 and
    neg_cost_usage != nil and
    Decimal.equal?(neg_cost_usage.spent_usd, Decimal.new("0")) and
    neg_cost_usage.requests == 1
)

# ═══════════════════════════════════════════════════════════════════════════════
# Task 8 PART B — folded cross-task hard-gates (buffered path)
# ═══════════════════════════════════════════════════════════════════════════════

# A deliver_fn that records metric-bump keys into `agent` (and swallows everything else).
metric_capture = fn agent ->
  fn _sw, _to, _from, content ->
    case Jason.decode(content) do
      {:ok, %{"action" => "bump", "key" => key}} -> Agent.update(agent, &[key | &1])
      _ -> :ok
    end

    :ok
  end
end

# A standard 200 completion carrying `cost` as x_router.cost_usd.
cost_completion = fn cost, content ->
  {:ok, 200,
   %{
     "id" => "chatcmpl-b1",
     "object" => "chat.completion",
     "model" => "gpt-test-served",
     "choices" => [
       %{
         "index" => 0,
         "message" => %{"role" => "assistant", "content" => content},
         "finish_reason" => "stop"
       }
     ],
     "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2},
     "x_router" => %{"provider" => "unit", "served_model_id" => "m", "cost_usd" => cost}
   }}
end

# ── B1 ⚠️ HARD GATE — sanitize_cost wired into the production (buffered) cost path ──
#
# A finite >1e9 cost from a trusted-but-buggy router must be CLAMPED to NUMERIC(18,9)
# (else the durable insert overflows, guard/1 swallows it, and the in-memory mirror is
# poisoned → false-block). The clamp must fire `llm_proxy_cost_invalid`, and a follow-up
# call on the same (non-exhausted) budget must still be served normally.

ProxyCheck.TestLLMProxyStore.reset()

b1_attrs = %{
  conversation_id: "tg:b1ovf:0",
  slot: :agent_b1ovf,
  kind: :dm,
  workspace_key: "b1ovfws",
  daily_limit_usd: Decimal.new("2000000000")
}

b1_identity = Proxy.budget_identity(b1_attrs)
{:ok, b1_token} = Proxy.register_session(state_pid, b1_attrs)
{:ok, b1_metrics} = Agent.start_link(fn -> [] end)

b1_opts =
  Map.merge(base_opts, %{
    deliver_fn: metric_capture.(b1_metrics),
    default_daily_limit: Decimal.new("2000000000")
  })

# Call 1: router emits cost_usd "1000000000" (> NUMERIC(18,9) max) as a RAW string so
# sanitize_cost sees the real magnitude.
b1_conn1 =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{b1_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(
      Map.put(b1_opts, :upstream, fn _b, _h, _o -> cost_completion.("1000000000", "ovf") end)
    )
  )

b1_usage1 = ProxyCheck.TestLLMProxyStore.usage(b1_identity, today)

# Call 2 (follow-up): a normal small cost — proves the clamp left the budget consistent
# and a subsequent call is still served (not poisoned / not crashed).
b1_conn2 =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{b1_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(
      Map.put(b1_opts, :upstream, fn _b, _h, _o -> cost_completion.(0.001, "ok2") end)
    )
  )

b1_usage2 = ProxyCheck.TestLLMProxyStore.usage(b1_identity, today)

check.(
  "B1 overflow: >1e9 cost CLAMPED to NUMERIC(18,9) max 999999999.999999999, llm_proxy_cost_invalid fires, NO overflow, follow-up call still served",
  b1_conn1.status == 200 and
    Decimal.equal?(b1_usage1.spent_usd, Decimal.new("999999999.999999999")) and
    "llm_proxy_cost_invalid" in Agent.get(b1_metrics, & &1) and
    b1_conn2.status == 200 and
    Decimal.equal?(
      b1_usage2.spent_usd,
      Decimal.add(Decimal.new("999999999.999999999"), Decimal.new("0.001"))
    ) and
    b1_usage2.requests == 2
)

# B1 finite/non-finite cost matrix (single call each): assert recorded spend + whether
# llm_proxy_cost_invalid fired.
b1_case = fn label, cost_value, expect_spent, expect_invalid? ->
  ProxyCheck.TestLLMProxyStore.reset()
  uniq = :erlang.unique_integer([:positive])

  attrs = %{
    conversation_id: "tg:b1c:#{uniq}",
    slot: :agent_b1c,
    kind: :dm,
    workspace_key: "b1cws#{uniq}"
  }

  identity = Proxy.budget_identity(attrs)
  {:ok, tok} = Proxy.register_session(state_pid, attrs)
  {:ok, mcap} = Agent.start_link(fn -> [] end)

  c =
    conn(:post, "/v1/chat/completions", Jason.encode!(body))
    |> put_req_header("authorization", "Bearer #{tok}")
    |> put_req_header("content-type", "application/json")
    |> ProxyPlug.call(
      ProxyPlug.init(
        Map.merge(base_opts, %{
          deliver_fn: metric_capture.(mcap),
          upstream: fn _b, _h, _o -> cost_completion.(cost_value, "x") end
        })
      )
    )

  usage = ProxyCheck.TestLLMProxyStore.usage(identity, today)
  invalid_bumped? = "llm_proxy_cost_invalid" in Agent.get(mcap, & &1)

  check.(
    label,
    c.status == 200 and usage != nil and Decimal.equal?(usage.spent_usd, expect_spent) and
      invalid_bumped? == expect_invalid?
  )
end

b1_case.(
  "B1 \"Infinity\" cost → recorded 0 + llm_proxy_cost_invalid",
  "Infinity",
  Decimal.new("0"),
  true
)

b1_case.(
  "B1 float token 0.25 → recorded 0.25, NOT flagged invalid",
  0.25,
  Decimal.new("0.25"),
  false
)

b1_case.(
  "B1 negative -3.0 → floored to 0, NOT flagged invalid (floor, not invalid)",
  -3.0,
  Decimal.new("0"),
  false
)

# ── Item 9: non-finite x_router.session_acc.cost_usd is FLAGGED, not silently zeroed ──
# The session_acc cost branch now feeds sanitize_cost a value it can still detect as
# non-finite (raw_decimal, not decimal/1) → cost stays a clean 0 AND llm_proxy_cost_invalid
# fires (previously decimal/1 zeroed "Infinity" before it could be flagged).
ProxyCheck.TestLLMProxyStore.reset()

sa_inf_attrs = %{
  conversation_id: "tg:sainf:0",
  slot: :agent_sainf,
  kind: :dm,
  workspace_key: "sainfws"
}

sa_inf_identity = Proxy.budget_identity(sa_inf_attrs)
{:ok, sa_inf_token} = Proxy.register_session(state_pid, sa_inf_attrs)
{:ok, sa_inf_metrics} = Agent.start_link(fn -> [] end)

sa_inf_upstream = fn _b, _h, _o ->
  {:ok, 200,
   %{
     "id" => "chatcmpl-sainf",
     "object" => "chat.completion",
     "model" => "gpt-test-served",
     "choices" => [
       %{
         "index" => 0,
         "message" => %{"role" => "assistant", "content" => "x"},
         "finish_reason" => "stop"
       }
     ],
     "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2},
     "x_router" => %{
       "provider" => "unit",
       "served_model_id" => "m",
       "session_acc" => %{"cost_usd" => "Infinity"}
     }
   }}
end

sa_inf_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{sa_inf_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(
      Map.merge(base_opts, %{
        deliver_fn: metric_capture.(sa_inf_metrics),
        upstream: sa_inf_upstream
      })
    )
  )

sa_inf_usage = ProxyCheck.TestLLMProxyStore.usage(sa_inf_identity, today)

check.(
  "item9: non-finite session_acc.cost_usd → recorded 0 + llm_proxy_cost_invalid fires (no longer silently zeroed)",
  sa_inf_conn.status == 200 and sa_inf_usage != nil and
    Decimal.equal?(sa_inf_usage.spent_usd, Decimal.new("0")) and
    "llm_proxy_cost_invalid" in Agent.get(sa_inf_metrics, & &1)
)

# ── B2 ⚠️ HARD GATE — retry bills ONCE end-to-end (through record_budget_call/store) ──
#
# curl-7 (connect-phase, never reached server) on attempt 1 → 200 on attempt 2. The whole
# request flows the Plug → call_upstream → call_with_retry → respond_upstream →
# record_budget_call → store. Exactly one record_llm_call; exactly one retry bump.

ProxyCheck.TestLLMProxyStore.reset()

b2_attrs = %{conversation_id: "tg:b2:0", slot: :agent_b2, kind: :dm, workspace_key: "b2ws"}
b2_identity = Proxy.budget_identity(b2_attrs)
{:ok, b2_token} = Proxy.register_session(state_pid, b2_attrs)
{:ok, b2_metrics} = Agent.start_link(fn -> [] end)
{:ok, b2_count} = Agent.start_link(fn -> 0 end)

b2_completion = %{
  "id" => "chatcmpl-b2",
  "object" => "chat.completion",
  "model" => "gpt-test-served",
  "choices" => [
    %{
      "index" => 0,
      "message" => %{"role" => "assistant", "content" => "retry-pong"},
      "finish_reason" => "stop"
    }
  ],
  "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5},
  "x_router" => %{"provider" => "unit", "served_model_id" => "m", "cost_usd" => 0.0001}
}

{:ok, b2_resp} = Agent.start_link(fn -> [{:error, {:curl, 7}}, {:ok, 200, b2_completion}] end)

b2_upstream = fn _body, _headers, _opts ->
  Agent.update(b2_count, &(&1 + 1))

  Agent.get_and_update(b2_resp, fn
    [h] -> {h, [h]}
    [h | t] -> {h, t}
  end)
end

b2_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{b2_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(
      Map.merge(base_opts, %{
        upstream: b2_upstream,
        deliver_fn: metric_capture.(b2_metrics),
        max_retries: 1
      })
    )
  )

b2_body = json.(b2_conn)
b2_record_calls = length(ProxyCheck.TestLLMProxyStore.events())
b2_retry_bumps = Agent.get(b2_metrics, & &1) |> Enum.count(&(&1 == "llm_proxy_upstream_retry"))

check.(
  "B2 retry bills ONCE: curl-7 then 200 → 200 + completion forwarded; record_llm_call==1; llm_proxy_upstream_retry bumped exactly once",
  b2_conn.status == 200 and
    get_in(b2_body, ["choices", Access.at(0), "message", "content"]) == "retry-pong" and
    Agent.get(b2_count, & &1) == 2 and
    b2_record_calls == 1 and
    b2_retry_bumps == 1 and
    Decimal.equal?(
      ProxyCheck.TestLLMProxyStore.usage(b2_identity, today).spent_usd,
      Decimal.new("0.0001")
    )
)

# ── B3 — llm_proxy_upstream_error metric emission ──

# B3a: genuine 503 → 503 forwarded + upstream_error bumped (respond_upstream non-2xx arm).
ProxyCheck.TestLLMProxyStore.reset()
b3a_attrs = %{conversation_id: "tg:b3a:0", slot: :agent_b3a, kind: :dm, workspace_key: "b3aws"}
{:ok, b3a_token} = Proxy.register_session(state_pid, b3a_attrs)
{:ok, b3a_metrics} = Agent.start_link(fn -> [] end)

b3a_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{b3a_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(
      Map.merge(base_opts, %{
        deliver_fn: metric_capture.(b3a_metrics),
        upstream: fn _b, _h, _o ->
          {:ok, 503,
           %{"error" => %{"message" => "overloaded", "type" => "server_error", "code" => "503"}}}
        end
      })
    )
  )

check.(
  "B3a upstream 503 → 503 forwarded + llm_proxy_upstream_error bumped",
  b3a_conn.status == 503 and "llm_proxy_upstream_error" in Agent.get(b3a_metrics, & &1)
)

# B3b: transport {:error, :timeout} → mapped to 502 + upstream_error bumped (call_upstream).
ProxyCheck.TestLLMProxyStore.reset()
b3b_attrs = %{conversation_id: "tg:b3b:0", slot: :agent_b3b, kind: :dm, workspace_key: "b3bws"}
{:ok, b3b_token} = Proxy.register_session(state_pid, b3b_attrs)
{:ok, b3b_metrics} = Agent.start_link(fn -> [] end)

b3b_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{b3b_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(
      Map.merge(base_opts, %{
        deliver_fn: metric_capture.(b3b_metrics),
        upstream: fn _b, _h, _o -> {:error, :timeout} end
      })
    )
  )

check.(
  "B3b transport {:error,:timeout} → 502 + llm_proxy_upstream_error bumped",
  b3b_conn.status == 502 and "llm_proxy_upstream_error" in Agent.get(b3b_metrics, & &1)
)

# ── L4 — only status:"ok" events burn the daily request quota (LENIENT policy) ──
# Self-contained (own reset + identity): B3a/B3b's store rows don't survive each
# other's `reset()`, so this exercises the SAME 5xx/transport-error → ok sequence
# against a store state this block fully owns.
ProxyCheck.TestLLMProxyStore.reset()
l4_attrs = %{conversation_id: "tg:l4:0", slot: :agent_l4, kind: :dm, workspace_key: "l4ws"}
l4_identity = Proxy.budget_identity(l4_attrs)
{:ok, l4_token} = Proxy.register_session(state_pid, l4_attrs)

l4_503_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{l4_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(
      Map.put(base_opts, :upstream, fn _b, _h, _o ->
        {:ok, 503,
         %{"error" => %{"message" => "overloaded", "type" => "server_error", "code" => "503"}}}
      end)
    )
  )

l4_usage_after_503 = ProxyCheck.TestLLMProxyStore.usage(l4_identity, today)

check.(
  "L4: a 5xx upstream event does NOT burn the daily request quota",
  l4_503_conn.status == 503 and not is_nil(l4_usage_after_503) and
    l4_usage_after_503.requests == 0
)

l4_transport_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{l4_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(Map.put(base_opts, :upstream, fn _b, _h, _o -> {:error, :timeout} end))
  )

l4_usage_after_transport = ProxyCheck.TestLLMProxyStore.usage(l4_identity, today)

check.(
  "L4: a transport-error (502) event does NOT burn the daily request quota (still 0 after 2 errors)",
  l4_transport_conn.status == 502 and l4_usage_after_transport.requests == 0
)

# A subsequent ok call on the SAME identity that just had two errors DOES burn the quota.
l4_ok_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{l4_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :upstream, ok_upstream)))

receive do
  {:upstream_call, _l4_seen_body, _l4_headers, _l4_cfg} -> :ok
after
  100 -> :ok
end

l4_ok_usage = ProxyCheck.TestLLMProxyStore.usage(l4_identity, today)

check.(
  "L4: a subsequent ok event DOES increment requests (0 → 1) after 2 prior errors were excluded",
  l4_ok_conn.status == 200 and l4_ok_usage.requests == 1
)

# ── L4 (mirror) — the PG-down in-memory fallback obeys the same LENIENT rule ────
# With the store fully down (NoStore → budget_status nil → fallback mirror), quota
# enforcement reads the mirror's `requests`. Errors must not advance it there either:
# daily_request_limit=1 means a single burned request blocks the NEXT call, so the
# ok call REACHING upstream after two prior errors proves the errors burned nothing.
{:ok, l4m_state_pid} = Proxy.start_state_link()
l4m_attrs = %{conversation_id: "tg:l4m:0", slot: :agent_l4m, kind: :dm, workspace_key: "l4mws"}
l4m_identity = Proxy.budget_identity(l4m_attrs)
{:ok, l4m_token} = Proxy.register_session(l4m_state_pid, l4m_attrs)

l4m_opts =
  Map.merge(base_opts, %{
    state_pid: l4m_state_pid,
    store_mod: ProxyCheck.TestLLMProxyNoStore,
    daily_request_limit: 1
  })

l4m_post = fn upstream ->
  conn(:post, "/v1/chat/completions", Jason.encode!(body))
  |> put_req_header("authorization", "Bearer #{l4m_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(l4m_opts, :upstream, upstream)))
end

l4m_503_conn =
  l4m_post.(fn _b, _h, _o ->
    {:ok, 503,
     %{"error" => %{"message" => "overloaded", "type" => "server_error", "code" => "503"}}}
  end)

l4m_transport_conn = l4m_post.(fn _b, _h, _o -> {:error, :timeout} end)

l4m_mirror_after_errors =
  Proxy.usage_for_budget_inmem(l4m_state_pid, l4m_identity, today, Decimal.new("0.50"))

check.(
  "L4 mirror: with the store DOWN, two error events (5xx + transport) leave the in-memory requests count at 0",
  l4m_503_conn.status == 503 and l4m_transport_conn.status == 502 and
    l4m_mirror_after_errors.requests == 0
)

l4m_ok_conn = l4m_post.(ok_upstream)

l4m_ok_reached_upstream? =
  receive do
    {:upstream_call, _b, _h, _c} -> true
  after
    100 -> false
  end

l4m_mirror_after_ok =
  Proxy.usage_for_budget_inmem(l4m_state_pid, l4m_identity, today, Decimal.new("0.50"))

check.(
  "L4 mirror: an ok event STILL reaches upstream under daily_request_limit=1 (errors burned no quota) and advances the mirror to 1",
  l4m_ok_conn.status == 200 and l4m_ok_reached_upstream? and
    l4m_mirror_after_ok.requests == 1
)

# ── L8 — gate-off stream downgrade also drops stream_options (upstream-strict 400
# ── avoidance: "stream_options can only be defined when stream is true") ────────
ProxyCheck.TestLLMProxyStore.reset()
l8_attrs = %{conversation_id: "tg:l8:0", slot: :agent_l8, kind: :dm, workspace_key: "l8ws"}
{:ok, l8_token} = Proxy.register_session(state_pid, l8_attrs)

l8_body = %{
  "model" => "gpt-test",
  "messages" => [%{"role" => "user", "content" => "hi"}],
  "stream" => true,
  "stream_options" => %{"include_usage" => true}
}

l8_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(l8_body))
  |> put_req_header("authorization", "Bearer #{l8_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :upstream, ok_upstream)))

receive do
  {:upstream_call, l8_seen_body, _l8_headers, _l8_cfg} ->
    check.(
      "L8: gate-off stream downgrade forces stream:false AND drops stream_options",
      l8_conn.status == 200 and l8_seen_body["stream"] == false and
        not Map.has_key?(l8_seen_body, "stream_options")
    )
after
  100 ->
    check.("L8: gate-off stream downgrade forwards a body to upstream", false)
end

# ── Global daily cost ceiling (public cost-DoS backstop) ──────────────────────
# Seed a high CROSS-conversation spend on a DIFFERENT identity, so it's the GLOBAL
# aggregate (not the fresh session's per-conversation budget) that does the blocking.
ProxyCheck.TestLLMProxyStore.seed_usage("other-conv-gc", ~D[2026-06-25], "1.00")

gc_body =
  Jason.encode!(%{"model" => "gpt-test", "messages" => [%{"role" => "user", "content" => "hi"}]})

{:ok, gc_token} =
  Proxy.register_session(state_pid, %{
    conversation_id: "tg:gc:0",
    slot: :agent_5,
    kind: :dm,
    workspace_key: "irvine"
  })

gc_block =
  conn(:post, "/v1/chat/completions", gc_body)
  |> put_req_header("authorization", "Bearer #{gc_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(
      Map.merge(base_opts, %{global_daily_limit: Decimal.new("0.50"), upstream: ok_upstream})
    )
  )

gc_block_body = json.(gc_block)

check.(
  "global ceiling: $1.00 spend over a $0.50 cap blocks EVERY conversation (synthetic block, not upstream)",
  gc_block.status == 200 and gc_block_body["model"] == "llm-proxy-budget" and
    gc_block_body["x_router"]["global_budget_exhausted"] == true
)

{:ok, gc_token2} =
  Proxy.register_session(state_pid, %{
    conversation_id: "tg:gc2:0",
    slot: :agent_6,
    kind: :dm,
    workspace_key: "irvine"
  })

gc_off =
  conn(:post, "/v1/chat/completions", gc_body)
  |> put_req_header("authorization", "Bearer #{gc_token2}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(
    ProxyPlug.init(
      Map.merge(base_opts, %{global_daily_limit: Decimal.new("0"), upstream: ok_upstream})
    )
  )

check.(
  "global ceiling = 0 disables the cap (forwards to upstream despite high global spend)",
  json.(gc_off)["model"] == "gpt-test-served"
)

# ─────────────────────────────────────────────────────────────────────────────

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY: ALL PASS")
else
  IO.puts("LLM_PROXY: FAILED")
  System.halt(1)
end
