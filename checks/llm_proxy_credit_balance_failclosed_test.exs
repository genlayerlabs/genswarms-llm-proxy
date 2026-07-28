# Durable credit-balance read failures fail closed for paid admission.
# Standalone — NO Postgres, NO network.
#
#   mix run checks/llm_proxy_credit_balance_failclosed_test.exs

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

defmodule BalanceFailclosed.Store do
  @name __MODULE__

  def start_link do
    Agent.start_link(
      fn ->
        %{
          mode: :healthy,
          durable_balance: Decimal.new("7.00"),
          budget_spent: Decimal.new("0.60"),
          balance_reads: 0,
          metrics: []
        }
      end,
      name: @name
    )
  end

  def mode(mode), do: Agent.update(@name, &Map.put(&1, :mode, mode))
  def budget_spent(spent), do: Agent.update(@name, &Map.put(&1, :budget_spent, spent))
  def reset_balance_reads, do: Agent.update(@name, &Map.put(&1, :balance_reads, 0))
  def balance_reads, do: Agent.get(@name, & &1.balance_reads)
  def metrics, do: Agent.get(@name, &Enum.reverse(&1.metrics))

  def llm_budget_status(identity, day, session_id, _default_limit) do
    %{
      budget_identity: identity,
      day: day,
      session_id: session_id,
      spent_usd: Agent.get(@name, & &1.budget_spent),
      limit_usd: Decimal.new("0.50"),
      requests: 1
    }
  end

  def record_llm_call(identity, day, session_id, _attrs) do
    llm_budget_status(identity, day, session_id, Decimal.new("0.50"))
  end

  def llm_usage_today(_day), do: %{spent_usd: Decimal.new("0")}

  def llm_credit_balance(_identity) do
    case Agent.get_and_update(@name, fn state ->
           {{state.mode, state.durable_balance}, Map.update!(state, :balance_reads, &(&1 + 1))}
         end) do
      {:healthy, balance} -> {:ok, balance}
      {:error, _balance} -> {:error, :db_down}
      {:raise, _balance} -> raise "db_down"
      {:throw, _balance} -> throw(:db_down)
      {:exit, _balance} -> exit(:db_down)
      {:raw_decimal, balance} -> balance
      {nil, _balance} -> nil
      {:wrong_inner, _balance} -> {:ok, "7.00"}
    end
  end

  def record_llm_credit_entry(%{amount_usd: amount}) do
    Agent.update(@name, fn state ->
      Map.update!(state, :durable_balance, &Decimal.add(&1, amount))
    end)

    :ok
  end

  def bump_metric(event, meta, value) do
    Agent.update(@name, fn state ->
      Map.update!(state, :metrics, &[{event, meta, value} | &1])
    end)

    :ok
  end
end

defmodule BalanceFailclosed.MirrorModeStore do
  # Deliberately no credit callback pair: this is the supported in-memory mode.
  def llm_budget_status(identity, day, session_id, _default_limit) do
    %{
      budget_identity: identity,
      day: day,
      session_id: session_id,
      spent_usd: Decimal.new("0.60"),
      limit_usd: Decimal.new("0.50"),
      requests: 1
    }
  end

  def record_llm_call(identity, day, session_id, _attrs) do
    llm_budget_status(identity, day, session_id, Decimal.new("0.50"))
  end

  def llm_usage_today(_day), do: %{spent_usd: Decimal.new("0")}
end

defmodule BalanceFailclosed.BalanceOnlyStore do
  defdelegate llm_budget_status(identity, day, session_id, default_limit),
    to: BalanceFailclosed.MirrorModeStore

  defdelegate record_llm_call(identity, day, session_id, attrs),
    to: BalanceFailclosed.MirrorModeStore

  defdelegate llm_usage_today(day), to: BalanceFailclosed.MirrorModeStore

  def llm_credit_balance(_identity), do: raise("partial read callback must not be called")
end

defmodule BalanceFailclosed.RecordOnlyStore do
  defdelegate llm_budget_status(identity, day, session_id, default_limit),
    to: BalanceFailclosed.MirrorModeStore

  defdelegate record_llm_call(identity, day, session_id, attrs),
    to: BalanceFailclosed.MirrorModeStore

  defdelegate llm_usage_today(day), to: BalanceFailclosed.MirrorModeStore

  def record_llm_credit_entry(_entry), do: raise("partial write callback must not be called")
end

defmodule BalanceFailclosed.LogSink do
  def reset, do: :persistent_term.put({__MODULE__, :hits}, 0)
  def hits, do: :persistent_term.get({__MODULE__, :hits}, 0)

  def log(event, _config) do
    text =
      case event.msg do
        {:string, string} -> IO.chardata_to_string(string)
        {:report, report} -> inspect(report)
        {format, args} -> IO.chardata_to_string(:io_lib.format(format, args))
      end

    if String.contains?(text, "credit balance store read FAILED") and
         String.contains?(text, "blocking paid request") do
      :persistent_term.put({__MODULE__, :hits}, hits() + 1)
    end

    :ok
  rescue
    _ -> :ok
  end
end

{:ok, _store} = BalanceFailclosed.Store.start_link()
{:ok, state_pid} = Proxy.start_state_link()

{:ok, token} =
  Proxy.register_session(state_pid, %{
    conversation_id: "tg:balance-failclosed:0",
    slot: :agent,
    kind: :dm,
    workspace_key: "default"
  })

session = Proxy.lookup_session(state_pid, token)

stale_entry = %{
  idempotency_key: "mirror:stale-positive",
  budget_identity: session.budget_identity,
  amount_usd: Decimal.new("5.00"),
  kind: "credit",
  at: ~U[2026-07-28 10:00:00Z],
  meta: %{}
}

{:ok, _} = Proxy.apply_credit_entry(state_pid, nil, stale_entry)

{:ok, delivered} = Agent.start_link(fn -> [] end)
{:ok, upstream_calls} = Agent.start_link(fn -> 0 end)

deliver_fn = fn _swarm, to, _from, payload ->
  Agent.update(delivered, &[{to, Jason.decode!(payload)} | &1])
  :ok
end

upstream = fn _body, _headers, _opts ->
  Agent.update(upstream_calls, &(&1 + 1))

  {:ok, 200,
   %{
     "id" => "chatcmpl-recovered",
     "object" => "chat.completion",
     "created" => 1_750_000_000,
     "model" => "test-model",
     "choices" => [
       %{
         "index" => 0,
         "message" => %{"role" => "assistant", "content" => "recovered"},
         "finish_reason" => "stop"
       }
     ],
     "usage" => %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}
   }}
end

base_opts = %{
  state_pid: state_pid,
  upstream_endpoint: "https://llm.invalid/v1/chat/completions",
  upstream_api_key: "test-key",
  upstream: upstream,
  provider: "unit",
  prices: %{},
  store_mod: BalanceFailclosed.Store,
  clock: fn -> ~U[2026-07-28 12:00:00Z] end,
  credits_enabled: true,
  swarm_name: "test",
  sender: :sender,
  metrics: :metrics,
  deliver_fn: deliver_fn
}

request = fn token, opts ->
  conn(
    :post,
    "/v1/chat/completions",
    Jason.encode!(%{"model" => "test", "messages" => []})
  )
  |> put_req_header("authorization", "Bearer #{token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(opts))
end

BalanceFailclosed.LogSink.reset()
:ok = :logger.add_handler(:balance_failclosed_log_sink, BalanceFailclosed.LogSink, %{})
BalanceFailclosed.Store.mode(:error)

# The free daily budget remains authoritative before credits. Its healthy
# remainder must admit without touching even a configured-but-down credit store.
BalanceFailclosed.Store.budget_spent(Decimal.new("0.40"))
BalanceFailclosed.Store.reset_balance_reads()
free_budget_upstream_before = Agent.get(upstream_calls, & &1)
free_budget_conn = request.(token, base_opts)

check.(
  "remaining free budget admits while the credit store is down without consulting it",
  free_budget_conn.status == 200 and
    Agent.get(upstream_calls, & &1) == free_budget_upstream_before + 1 and
    BalanceFailclosed.Store.balance_reads() == 0
)

BalanceFailclosed.Store.budget_spent(Decimal.new("0.60"))

blocked_conn = request.(token, base_opts)
blocked_body = Jason.decode!(blocked_conn.resp_body)

check.(
  "configured store {:error, :db_down} + stale positive mirror blocks before upstream",
  blocked_conn.status == 200 and blocked_body["model"] == "llm-proxy-budget" and
    Agent.get(upstream_calls, & &1) == free_budget_upstream_before + 1
)

notices =
  Agent.get(delivered, fn messages ->
    for {:sender, %{"action" => "slot_reply", "content" => content}} <- Enum.reverse(messages),
        do: content
  end)

check.(
  "store-outage block notice is truthful and does not tell the user to wait until tomorrow",
  Enum.any?(notices, fn notice ->
    String.contains?(notice, "prepaid balance is temporarily unavailable") and
      String.contains?(notice, "no paid request was sent") and
      not String.contains?(notice, "tomorrow")
  end)
)

check.(
  "agent-facing synthetic response says the paid request was not sent",
  blocked_body
  |> get_in(["choices", Access.at(0), "message", "content"])
  |> then(fn content ->
    is_binary(content) and String.contains?(content, "prepaid balance is temporarily unavailable") and
      String.contains?(content, "no paid request was sent")
  end)
)

compact_conn =
  conn(
    :post,
    "/v1/compact",
    Jason.encode!(%{"messages" => [], "keep_recent" => 6, "max_tokens" => 512})
  )
  |> put_req_header("authorization", "Bearer #{token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(base_opts))

compact_body = Jason.decode!(compact_conn.resp_body)

check.(
  "configured-store outage also blocks the paid /v1/compact call before upstream",
  compact_conn.status == 429 and
    get_in(compact_body, ["error", "code"]) == "credit_store_unavailable" and
    Agent.get(upstream_calls, & &1) == free_budget_upstream_before + 1
)

check.(
  "structured quota metric distinguishes the block as store_unavailable",
  Enum.any?(BalanceFailclosed.Store.metrics(), fn
    {"llm_proxy.quota_blocked", %{reason: "store_unavailable"}, 1} -> true
    _ -> false
  end)
)

flat_metric_keys =
  Agent.get(delivered, fn messages ->
    for {:metrics, %{"action" => "bump", "key" => key}} <- messages, do: key
  end)

check.(
  "read outage uses the existing degraded and budget-block metric bumps",
  "llm_proxy_budget_degraded" in flat_metric_keys and
    "llm_proxy_budget_block" in flat_metric_keys
)

check.(
  "read outage is logged as an admission failure",
  BalanceFailclosed.LogSink.hits() >= 1
)

check.(
  "failed durable read reports unavailable; public API returns conservative zero; mirror is untouched",
  match?(
    {:error, :db_down},
    Proxy.credit_balance_result(
      state_pid,
      BalanceFailclosed.Store,
      session.budget_identity
    )
  ) and
    Decimal.equal?(
      Proxy.credit_balance(state_pid, BalanceFailclosed.Store, session.budget_identity),
      Decimal.new("0")
    ) and
    Decimal.equal?(
      Proxy.credit_balance(state_pid, nil, session.budget_identity),
      Decimal.new("5.00")
    )
)

BalanceFailclosed.Store.mode(:raise)

check.(
  "configured durable read raise is also unavailable and does not overwrite the mirror",
  match?(
    {:error, {:raised, RuntimeError, "db_down"}},
    Proxy.credit_balance_result(
      state_pid,
      BalanceFailclosed.Store,
      session.budget_identity
    )
  ) and
    Decimal.equal?(
      Proxy.credit_balance(state_pid, nil, session.budget_identity),
      Decimal.new("5.00")
    )
)

BalanceFailclosed.Store.mode(:healthy)
recovered_conn = request.(token, base_opts)
recovered_body = Jason.decode!(recovered_conn.resp_body)

check.(
  "next successful durable read resumes paid admission after recovery",
  recovered_conn.status == 200 and
    get_in(recovered_body, ["choices", Access.at(0), "message", "content"]) == "recovered" and
    Agent.get(upstream_calls, & &1) == free_budget_upstream_before + 2 and
    Decimal.equal?(
      Proxy.credit_balance(state_pid, BalanceFailclosed.Store, session.budget_identity),
      Decimal.new("7.00")
    )
)

BalanceFailclosed.Store.mode(:error)

quota_state = %{
  state_pid: state_pid,
  credits_enabled: true,
  quota: %{
    store_mod: BalanceFailclosed.Store,
    default_daily_limit: Decimal.new("0.50"),
    daily_request_limit: 0,
    global_daily_limit: Decimal.new("0"),
    clock: fn -> ~U[2026-07-28 12:00:00Z] end
  }
}

{:reply, quota_json, _} =
  Proxy.handle_message(
    :commands,
    Jason.encode!(%{
      action: "quota_status",
      conversation_id: session.conversation_id,
      kind: "dm",
      workspace_key: "default"
    }),
    quota_state
  )

quota_body = Jason.decode!(quota_json)

check.(
  "quota_status reports configured-store read failure as unavailable, not a stale balance",
  quota_body["credit"] == %{"balance_usd" => nil, "unavailable" => true}
)

check.(
  "quota_status read failure is metered with bounded store_unavailable labels",
  Enum.any?(BalanceFailclosed.Store.metrics(), fn
    {"llm_credit_balance_read_failed", %{context: "quota_status", reason: "store_unavailable"}, 1} ->
      true

    _ ->
      false
  end)
)

BalanceFailclosed.Store.mode(:healthy)

# A host without the coherent credit callback pair remains in supported mirror mode.
{:ok, mirror_pid} = Proxy.start_state_link()

{:ok, mirror_token} =
  Proxy.register_session(mirror_pid, %{
    conversation_id: "tg:balance-mirror-mode:0",
    slot: :agent,
    kind: :dm,
    workspace_key: "default"
  })

mirror_session = Proxy.lookup_session(mirror_pid, mirror_token)

{:ok, _} =
  Proxy.apply_credit_entry(mirror_pid, BalanceFailclosed.MirrorModeStore, %{
    stale_entry
    | idempotency_key: "mirror:callback-absent",
      budget_identity: mirror_session.budget_identity
  })

mirror_opts = %{
  base_opts
  | state_pid: mirror_pid,
    store_mod: BalanceFailclosed.MirrorModeStore
}

mirror_conn = request.(mirror_token, mirror_opts)
mirror_body = Jason.decode!(mirror_conn.resp_body)

check.(
  "callback-absent mode still admits an exhausted-budget request from a positive mirror",
  mirror_conn.status == 200 and
    get_in(mirror_body, ["choices", Access.at(0), "message", "content"]) == "recovered" and
    Agent.get(upstream_calls, & &1) == free_budget_upstream_before + 3
)

# Every exceptional and nonconforming configured-store read must take the same
# paid-admission fail-closed path. None may reach upstream.
for {mode, label} <- [
      {:throw, "configured durable read throw fails closed"},
      {:exit, "configured durable read exit fails closed"},
      {:raw_decimal, "raw Decimal return fails closed"},
      {nil, "nil return fails closed"},
      {:wrong_inner, "ok tuple with non-Decimal inner value fails closed"}
    ] do
  BalanceFailclosed.Store.mode(mode)
  upstream_before = Agent.get(upstream_calls, & &1)
  conn = request.(token, base_opts)

  check.(
    label,
    conn.status == 200 and Jason.decode!(conn.resp_body)["model"] == "llm-proxy-budget" and
      Agent.get(upstream_calls, & &1) == upstream_before
  )
end

# 0.4.0's both-callbacks-or-neither contract: either partial pair is treated as
# callback-absent mirror mode for both reads and writes.
for {store_mod, suffix} <- [
      {BalanceFailclosed.BalanceOnlyStore, "balance-only"},
      {BalanceFailclosed.RecordOnlyStore, "record-only"}
    ] do
  {:ok, partial_pid} = Proxy.start_state_link()

  {:ok, partial_token} =
    Proxy.register_session(partial_pid, %{
      conversation_id: "tg:balance-#{suffix}:0",
      slot: :agent,
      kind: :dm,
      workspace_key: "default"
    })

  partial_session = Proxy.lookup_session(partial_pid, partial_token)

  {:ok, _} =
    Proxy.apply_credit_entry(partial_pid, store_mod, %{
      stale_entry
      | idempotency_key: "mirror:#{suffix}",
        budget_identity: partial_session.budget_identity
    })

  partial_opts = %{base_opts | state_pid: partial_pid, store_mod: store_mod}
  upstream_before = Agent.get(upstream_calls, & &1)
  partial_conn = request.(partial_token, partial_opts)

  check.(
    "#{suffix} partial pair remains in documented mirror mode",
    partial_conn.status == 200 and
      get_in(Jason.decode!(partial_conn.resp_body), [
        "choices",
        Access.at(0),
        "message",
        "content"
      ]) == "recovered" and
      Agent.get(upstream_calls, & &1) == upstream_before + 1
  )
end

# Same-reason store-outage blocks are rate-limited, not once-and-silent or
# unbounded spam: first is sent, one just inside the boundary is suppressed,
# and one exactly at the boundary is sent.
{:ok, repeat_pid} = Proxy.start_state_link()

{:ok, repeat_token} =
  Proxy.register_session(repeat_pid, %{
    conversation_id: "tg:balance-repeat:0",
    slot: :agent,
    kind: :dm,
    workspace_key: "default"
  })

{:ok, repeat_clock} = Agent.start_link(fn -> ~U[2026-07-28 12:00:00Z] end)
{:ok, repeat_delivered} = Agent.start_link(fn -> [] end)

repeat_deliver_fn = fn _swarm, to, _from, payload ->
  Agent.update(repeat_delivered, &[{to, Jason.decode!(payload)} | &1])
  :ok
end

repeat_opts =
  Map.merge(base_opts, %{
    state_pid: repeat_pid,
    clock: fn -> Agent.get(repeat_clock, & &1) end,
    notice_repeat_ms: 1_000,
    deliver_fn: repeat_deliver_fn
  })

BalanceFailclosed.Store.mode(:error)
repeat_upstream_before = Agent.get(upstream_calls, & &1)
request.(repeat_token, repeat_opts)
Agent.update(repeat_clock, fn at -> DateTime.add(at, 999, :millisecond) end)
request.(repeat_token, repeat_opts)
Agent.update(repeat_clock, fn at -> DateTime.add(at, 1, :millisecond) end)
request.(repeat_token, repeat_opts)

repeat_notices =
  Agent.get(repeat_delivered, fn messages ->
    Enum.count(messages, fn
      {:sender, %{"action" => "slot_reply"}} -> true
      _ -> false
    end)
  end)

check.(
  "same-reason blocks send exactly two notices across notice_repeat_ms boundary",
  repeat_notices == 2 and Agent.get(upstream_calls, & &1) == repeat_upstream_before
)

:logger.remove_handler(:balance_failclosed_log_sink)

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_CREDIT_BALANCE_FAILCLOSED: ALL PASS")
else
  IO.puts("LLM_PROXY_CREDIT_BALANCE_FAILCLOSED: FAILED")
  IO.puts("  Failed: #{Enum.join(Enum.reverse(failed), ", ")}")
  System.halt(1)
end
