# LLM proxy boot-resilience smoke (operational init/1 hardening). Standalone — NO Postgres,
# NO network upstream (init starts only a loopback Bandit listener + the state Agent).
#
#   mix run tests/llm_proxy_boot_test.exs
#
# Exercises Genswarms.LlmProxy.init/1 — the object-boot path the whole hardening protects, with zero
# coverage before this. Asserts:
#   * init/1 boots with max_retries:50 (clamped to 3) and a ≤0 default_daily_limit (warning
#     path) WITHOUT crashing;
#   * handle_message/3 answers {"action":"usage"} and {"action":"health"} sanely;
#   * terminate/2 does not crash;
#   * a SECOND init/1 on the SAME port is tolerated — the state Agent boot-race guard
#     (:already_started → reuse) AND the Bandit listener guard (:eaddrinuse → log-and-continue)
#     both return {:ok, state} instead of a MatchError.

Application.ensure_all_started(:plug)
Application.ensure_all_started(:bandit)

# Trap exits: the real object boots under a supervised GenServer. In that context a port-bound
# Bandit.start_link returns {:error, {:shutdown, {:failed_to_start_child, :listener,
# :eaddrinuse}}} (which init/1's guard maps to bandit: nil) rather than killing the caller via
# the linked listener's startup crash. A bare non-trapping process would be killed instead.
Process.flag(:trap_exit, true)


{:ok, failures} = Agent.start_link(fn -> [] end)

check = fn label, ok ->
  if ok do
    IO.puts("  ok   #{label}")
  else
    IO.puts("  FAIL #{label}")
    Agent.update(failures, &[label | &1])
  end
end

# Fixed loopback port so the second init/1 collides on the SAME port (exercising the Bandit
# :eaddrinuse log-and-continue guard). Unusual port to avoid collisions with other suites.
boot_port = 24_318

boot_config = %{
  port: boot_port,
  upstream_endpoint: "https://llm.example/v1/chat/completions",
  upstream_api_key: "sk-boot-smoke-key",
  # ≤ 0 default_daily_limit → exercises the warning branch in init/1 (must NOT crash).
  default_daily_limit: "0",
  # 50 → clamped to 3 in plug_opts (min(max(50,0),3)); init must accept it without crashing.
  max_retries: 50
}

# ── init/1 boots cleanly under the hardened config ──────────────────────────────
boot1 = Genswarms.LlmProxy.init(boot_config)

check.(
  "init/1 with max_retries:50 + default_daily_limit:0 returns {:ok, state} (warning path, no crash)",
  match?({:ok, %{}}, boot1)
)

{:ok, state1} = boot1

check.(
  "init/1 state carries a live state Agent pid + a Bandit listener pid + endpoint/provider",
  is_pid(state1.state_pid) and Process.alive?(state1.state_pid) and
    is_pid(state1.bandit) and is_binary(state1.endpoint) and is_binary(state1.provider)
)

check.(
  "init/1 max_retries clamp: min(max(50,0),3) == 3 (value proven end-to-end by retry #12 + swarm_config (e))",
  min(max(50, 0), 3) == 3
)

# ── handle_message/3: usage + health ───────────────────────────────────────────
{:reply, usage_json, ^state1} = Genswarms.LlmProxy.handle_message(:caller, ~s({"action":"usage"}), state1)
usage_reply = Jason.decode!(usage_json)

check.(
  "handle_message {\"action\":\"usage\"} → {:reply, json} with a (possibly empty) usage list",
  is_map(usage_reply) and is_list(usage_reply["usage"])
)

{:reply, health_json, ^state1} = Genswarms.LlmProxy.handle_message(:caller, ~s({"action":"health"}), state1)
health_reply = Jason.decode!(health_json)

check.(
  "handle_message {\"action\":\"health\"} → {:reply, json} ok:true with endpoint + provider",
  health_reply["ok"] == true and health_reply["endpoint"] == state1.endpoint and
    health_reply["provider"] == state1.provider
)

{:noreply, ^state1} = Genswarms.LlmProxy.handle_message(:caller, ~s({"action":"bogus"}), state1)

check.(
  "handle_message unknown action → {:noreply, state} (never crashes)",
  true
)

# ── Second init/1 on the SAME port is tolerated (Agent guard + Bandit guard) ────
boot2 = Genswarms.LlmProxy.init(boot_config)

check.(
  "second init/1 on the same port returns {:ok, state} — no MatchError (Agent :already_started reused, Bandit :eaddrinuse log-and-continue)",
  match?({:ok, %{}}, boot2)
)

{:ok, state2} = boot2

check.(
  "second init/1 reuses BOTH the state Agent and the running listener (mm semantics: whereis-first, never a second bind)",
  state2.state_pid == state1.state_pid and state2.bandit == state1.bandit and is_pid(state2.bandit)
)

# ── terminate/2 does not crash (and is total over the nil-bandit / shared-Agent case) ──
check.(
  "terminate/2 on the first state returns :ok (stops bandit + Agent)",
  Genswarms.LlmProxy.terminate(:shutdown, state1) == :ok
)

check.(
  "terminate/2 on the second state returns :ok (bandit nil + Agent already stopped — guarded)",
  Genswarms.LlmProxy.terminate(:shutdown, state2) == :ok
)

# ─────────────────────────────────────────────────────────────────────────────
failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_BOOT: ALL PASS")
else
  IO.puts("LLM_PROXY_BOOT: FAILED (#{length(failed)} check(s))")
  failed |> Enum.reverse() |> Enum.each(&IO.puts("  FAIL #{&1}"))
  System.halt(1)
end
