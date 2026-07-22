# payment_confirmed entry point (Task 2): trusted source + namespace gate,
# idempotent top-up via the Task 1 credit-ledger primitives.
# Standalone — NO Postgres, NO network.   mix run checks/llm_proxy_credit_topup_test.exs
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

{:ok, pid} = Proxy.start_state_link()
bi = "w:default|k:dm|c:tg:9:0"

msg = fn over ->
  Jason.encode!(
    Map.merge(
      %{
        "action" => "payment_confirmed",
        "beneficiary" => bi,
        "amount_usd" => "5.00",
        "method" => "usdc_base",
        "ref" => "0xT:0",
        "namespace" => "llm_quota",
        "at" => "2026-07-22T12:00:00Z"
      },
      over
    )
  )
end

# Object state under test: mirror the shape handle_message/3 actually receives
# (see init/1 around the Bandit/state_pid assembly, and quota_status/2's
# tolerant `Map.get(state, :store_mod)` fallback) plus the three new credit
# config keys.
state = %{
  state_pid: pid,
  bandit: nil,
  port: 4318,
  endpoint: "http://127.0.0.1:4318/v1/chat/completions",
  provider: "openai-compatible",
  quota: %{store_mod: nil},
  store_mod: nil,
  payments_source: "payments",
  credit_namespace: "llm_quota",
  credit_per_usd: Decimal.new("1.0")
}

# 1. trusted source + right namespace credits
{:reply, json, _} = Proxy.handle_message("payments", msg.(%{}), state)
reply = Jason.decode!(json)
check.("credited ok", reply["ok"] == true and reply["credited_usd"] == "5.00")

check.(
  "balance visible",
  Decimal.equal?(Proxy.credit_balance(pid, nil, bi), Decimal.new("5.00"))
)

# 2. duplicate ref → acknowledged, NOT double-credited
{:reply, json2, _} = Proxy.handle_message("payments", msg.(%{}), state)

check.(
  "duplicate acked without double credit",
  Jason.decode!(json2)["duplicate"] == true and
    Decimal.equal?(Proxy.credit_balance(pid, nil, bi), Decimal.new("5.00"))
)

# 3. untrusted source → silently ignored (noreply), no credit
check.(
  "untrusted source ignored",
  match?({:noreply, _}, Proxy.handle_message("randomobject", msg.(%{"ref" => "0xT:1"}), state)) and
    Decimal.equal?(Proxy.credit_balance(pid, nil, bi), Decimal.new("5.00"))
)

# 4. foreign namespace → ignored per spec (noreply), no credit
check.(
  "foreign namespace ignored",
  match?(
    {:noreply, _},
    Proxy.handle_message(
      "payments",
      msg.(%{"ref" => "0xT:2", "namespace" => "micromarkets"}),
      state
    )
  ) and
    Decimal.equal?(Proxy.credit_balance(pid, nil, bi), Decimal.new("5.00"))
)

# 5. feature off (payments_source nil) → ignored even from any source
state_off = %{state | payments_source: nil}

check.(
  "feature-off ignores payment_confirmed",
  match?({:noreply, _}, Proxy.handle_message("payments", msg.(%{"ref" => "0xT:3"}), state_off))
)

# 6. conversion: credit_per_usd 2.0 doubles
state2x = %{state | credit_per_usd: Decimal.new("2.0")}

{:reply, json3, _} =
  Proxy.handle_message(
    "payments",
    msg.(%{"ref" => "0xT:4", "beneficiary" => "w:x|k:dm|c:z"}),
    state2x
  )

check.("credit_per_usd conversion", Jason.decode!(json3)["credited_usd"] == "10.00")

# 7. malformed amount → error reply, nothing credited
{:reply, json4, _} =
  Proxy.handle_message("payments", msg.(%{"ref" => "0xT:5", "amount_usd" => "abc"}), state)

check.("malformed amount refused", Jason.decode!(json4)["ok"] == false)

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_CREDIT_TOPUP: ALL PASS")
else
  IO.puts("LLM_PROXY_CREDIT_TOPUP: FAILED")
  IO.puts("  Failed: #{Enum.join(Enum.reverse(failed), ", ")}")
  System.halt(1)
end
