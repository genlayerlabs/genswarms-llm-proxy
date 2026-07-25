# Outbox consumer stuck-queue bound and quota_status operator surface.
# Standalone — no Postgres, no network.
alias Genswarms.LlmProxy, as: Proxy

{:ok, failures} = Agent.start_link(fn -> [] end)

check = fn label, ok ->
  if ok do
    IO.puts("  ok   #{label}")
  else
    IO.puts("  FAIL #{label}")
    Agent.update(failures, &[label | &1])
  end
end

defmodule PaymentsStuckStore do
  def reset do
    :persistent_term.put(
      {__MODULE__, :state},
      %{cursor: nil, stuck: [], metrics: []}
    )
  end

  def state, do: :persistent_term.get({__MODULE__, :state})
  defp update(fun), do: :persistent_term.put({__MODULE__, :state}, fun.(state()))

  # Coherent credit pair: none of these permanent rows reaches the writer.
  def llm_credit_balance(_budget_identity), do: {:ok, Decimal.new("0")}
  def record_llm_credit_entry(_entry), do: :ok

  def llm_payments_cursor(_consumer), do: {:ok, state().cursor}

  def put_llm_payments_cursor(_consumer, cursor) do
    update(&%{&1 | cursor: cursor})
    :ok
  end

  def record_llm_stuck_payment(row) do
    update(&%{&1 | stuck: &1.stuck ++ [row]})
    :ok
  end

  def bump_metric(event, meta, value) do
    update(&%{&1 | metrics: &1.metrics ++ [{event, meta, value}]})
    :ok
  end
end

PaymentsStuckStore.reset()
{:ok, pid} = Proxy.start_state_link()

rows =
  for seq <- 1..205 do
    %{
      beneficiary: "w:default|k:dm|c:tg:#{seq}:0",
      amount_usd: "1.00",
      method: "debit",
      ref: "poison-#{seq}",
      idempotency_key: "8453:poison-#{seq}",
      namespace: "llm_quota",
      outbox_seq: seq,
      at: ~U[2026-07-25 10:00:00Z]
    }
  end

state = %{
  state_pid: pid,
  endpoint: "http://127.0.0.1:4318/v1/chat/completions",
  provider: "openai-compatible",
  quota: %{
    store_mod: PaymentsStuckStore,
    default_daily_limit: Decimal.new("0.50"),
    daily_request_limit: 0,
    global_daily_limit: Decimal.new("0"),
    clock: fn -> ~U[2026-07-25 12:00:00Z] end
  },
  store_mod: PaymentsStuckStore,
  payments_source: "payments",
  credit_namespace: "llm_quota",
  credit_per_usd: Decimal.new("1.0"),
  credits_enabled: true,
  settlements_fn: fn 0, 300 ->
    {:ok, %{settlements: rows, max_seq: 205, next_seq: 205, complete: true}}
  end,
  payments_consumer: "llm_proxy",
  poll_lag: 100,
  poll_limit: 300,
  poll_sources: ["cron"]
}

{:reply, poll_json, ^state} =
  Proxy.handle_message("cron", Jason.encode!(%{action: "poll_payments"}), state)

poll = Jason.decode!(poll_json)
durable = PaymentsStuckStore.state()
mirror = Agent.get(pid, &Map.get(&1, :stuck_payments, []))

check.(
  "all permanent rows resolve and the page advances",
  poll["ok"] == true and poll["stuck"] == 205 and poll["deferred"] == 0 and
    poll["cursor"] == 205 and poll["lag"] == 0
)

check.(
  "record_llm_stuck_payment is used for every permanent row",
  length(durable.stuck) == 205 and hd(durable.stuck).idempotency_key == "8453:poison-1" and
    List.last(durable.stuck).idempotency_key == "8453:poison-205"
)

check.(
  "in-memory stuck mirror is FIFO-bounded to 200 entries",
  length(mirror) == 200 and hd(mirror).idempotency_key == "8453:poison-6" and
    List.last(mirror).idempotency_key == "8453:poison-205"
)

check.(
  "every durable stuck row includes reason and timestamp",
  Enum.all?(durable.stuck, fn row ->
    row.reason == "reserved_method" and match?(%DateTime{}, row.at)
  end)
)

quota_message =
  Jason.encode!(%{
    action: "quota_status",
    conversation_id: "tg:9:0",
    kind: "dm",
    workspace_key: "default",
    day: "2026-07-25"
  })

{:reply, quota_json, ^state} = Proxy.handle_message("operator", quota_message, state)
quota = Jason.decode!(quota_json)

check.(
  "quota_status exposes configured poll cursor, lag, and bounded stuck count",
  quota["payments_poll"] == %{"cursor" => 205, "lag" => 0, "stuck" => 200}
)

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_PAYMENTS_POLL_STUCK: ALL PASS")
else
  IO.puts("LLM_PROXY_PAYMENTS_POLL_STUCK: FAILED")
  Enum.each(Enum.reverse(failed), &IO.puts("  Failed: #{&1}"))
  System.halt(1)
end
