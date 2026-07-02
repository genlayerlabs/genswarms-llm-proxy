# Foundations test for Genswarms.LlmProxy Task 1: bump_metric, secret-scrub, sanitize_cost.
# Standalone — NO Postgres, NO network.
#
#   mix run tests/llm_proxy_foundations_test.exs

repo_root = Path.expand(Path.join(__DIR__, ".."))


alias Genswarms.LlmProxy, as: Proxy
alias Genswarms.LlmProxy.Plug, as: ProxyPlug

{:ok, failures} = Agent.start_link(fn -> [] end)

check = fn label, ok ->
  if ok do
    IO.puts("  ok   #{label}")
  else
    IO.puts("  FAIL #{label}")
    Agent.update(failures, &[label | &1])
  end
end

# ── 1. bump_metric/2 is module-qualified (@doc false def, not defp) ───────────

{:ok, captured} = Agent.start_link(fn -> [] end)

capture_fn = fn swarm, target, from, content ->
  Agent.update(captured, &[{swarm, target, from, content} | &1])
  :ok
end

opts_with_deliver = %{
  swarm_name: "wingston",
  metrics: :metrics,
  deliver_fn: capture_fn
}

result = ProxyPlug.bump_metric(opts_with_deliver, "requests")
calls = Agent.get(captured, &Enum.reverse(&1))

check.(
  "bump_metric/2 is callable module-qualified (proves @doc false def)",
  result == :ok
)

check.(
  "bump_metric/2 invokes deliver_fn with correct args and encoded JSON payload",
  length(calls) == 1 and
    (fn
       [{sw, target, from, content}] ->
         decoded = Jason.decode!(content)
         sw == "wingston" and target == :metrics and from == :llm_proxy and
           decoded == %{"action" => "bump", "key" => "requests"}

       _ ->
         false
     end).(calls)
)

# ── 2. bump_metric/2 no-op with missing opts ──────────────────────────────────

Agent.update(captured, fn _ -> [] end)
result2 = ProxyPlug.bump_metric(%{}, "x")
calls2 = Agent.get(captured, & &1)

check.(
  "bump_metric/2 returns :ok and records nothing when opts keys are missing",
  result2 == :ok and calls2 == []
)

# ── 3. bump_metric/2 swallows a raising deliver_fn ────────────────────────────

raising_deliver = fn _sw, _target, _from, _content ->
  raise "intentional raise from deliver_fn"
end

result3 = ProxyPlug.bump_metric(%{swarm_name: "w", metrics: :m, deliver_fn: raising_deliver}, "k")

check.(
  "bump_metric/2 returns :ok when deliver_fn raises (rescue branch)",
  result3 == :ok
)

# ── 4. bump_metric/2 swallows a throwing deliver_fn ──────────────────────────

throwing_deliver = fn _sw, _target, _from, _content ->
  throw(:boom)
end

result4 =
  ProxyPlug.bump_metric(%{swarm_name: "w", metrics: :m, deliver_fn: throwing_deliver}, "k")

check.(
  "bump_metric/2 returns :ok when deliver_fn throws (catch branch)",
  result4 == :ok
)

# ── 5. scrub_secret/2 removes the literal key ────────────────────────────────

scrubbed5 = ProxyPlug.scrub_secret("hi real-upstream-key-SENTINEL bye", "real-upstream-key-SENTINEL")

check.(
  "scrub_secret/2 replaces the literal key with [REDACTED]",
  not String.contains?(scrubbed5, "SENTINEL") and String.contains?(scrubbed5, "[REDACTED]")
)

# ── 6. scrub_secret/2 redacts sk-… patterns ──────────────────────────────────

scrubbed6 = ProxyPlug.scrub_secret("leaked sk-ABCDEFGHIJKLMNOPQRST tail", "other-key")

check.(
  "scrub_secret/2 redacts sk-… shaped secrets even when key doesn't match",
  not String.contains?(scrubbed6, "sk-ABCDEFGHIJKLMNOPQRST") and String.contains?(scrubbed6, "[REDACTED]")
)

# ── 7. sanitize_log/1 strips control chars and bounds length ─────────────────

sanitized7 = ProxyPlug.sanitize_log("a\n[error] forged\rb c")

check.(
  "sanitize_log/1 strips CR, LF (and other C0 control chars); length ≤ 220",
  not String.contains?(sanitized7, "\n") and
    not String.contains?(sanitized7, "\r") and
    not String.contains?(sanitized7, "\x00") and
    byte_size(sanitized7) <= 220
)

# ── 8. sanitize_cost/1 — all branches ────────────────────────────────────────

{inf_val, inf_flag} = Proxy.sanitize_cost("Infinity")

check.(
  "sanitize_cost/1: \"Infinity\" → {0, true}",
  inf_flag == true and Decimal.equal?(inf_val, Decimal.new("0"))
)

{neg_inf_val, neg_inf_flag} = Proxy.sanitize_cost("-inf")

check.(
  "sanitize_cost/1: \"-inf\" → {0, true}",
  neg_inf_flag == true and Decimal.equal?(neg_inf_val, Decimal.new("0"))
)

{nan_val, nan_flag} = Proxy.sanitize_cost("NaN")

check.(
  "sanitize_cost/1: \"NaN\" → {0, true}",
  nan_flag == true and Decimal.equal?(nan_val, Decimal.new("0"))
)

{neg_val, neg_flag} = Proxy.sanitize_cost(-5.0)

check.(
  "sanitize_cost/1: negative → {0, false} (floor, not flagged invalid)",
  neg_flag == false and Decimal.equal?(neg_val, Decimal.new("0"))
)

{clamped_val, clamped_flag} = Proxy.sanitize_cost(2_000_000_000)

check.(
  "sanitize_cost/1: 2_000_000_000 → clamped to 999999999.999999999 with invalid=true",
  clamped_flag == true and
    Decimal.compare(clamped_val, Decimal.new("999999999.999999999")) == :eq
)

{tiny_val, tiny_flag} = Proxy.sanitize_cost("0.0000000001")

check.(
  "sanitize_cost/1: \"0.0000000001\" rounds to 0 at 9dp, invalid=false",
  tiny_flag == false and Decimal.equal?(tiny_val, Decimal.new("0.000000000"))
)

{point30_val, point30_flag} = Proxy.sanitize_cost("0.30")

check.(
  "sanitize_cost/1: \"0.30\" → {Decimal(0.30), false}",
  point30_flag == false and Decimal.equal?(point30_val, Decimal.new("0.30"))
)

# ── 9. decimal/1 hardening: non-finite inputs return 0 ───────────────────────

check.(
  "Proxy.decimal/1: \"Infinity\" returns 0 (non-finite hardening)",
  Decimal.equal?(Proxy.decimal("Infinity"), Decimal.new("0"))
)

check.(
  "Proxy.decimal/1: \"NaN\" returns 0 (non-finite hardening)",
  Decimal.equal?(Proxy.decimal("NaN"), Decimal.new("0"))
)

# ── 10. sanitize_cost/1 — non-finite %Decimal{} struct inputs ───────────────

{inf_struct, ""} = Decimal.parse("Infinity")
{inf_struct_val, inf_struct_flag} = Proxy.sanitize_cost(inf_struct)

check.(
  "sanitize_cost/1: %Decimal{} Infinity struct → {0, true}",
  inf_struct_flag == true and Decimal.equal?(inf_struct_val, Decimal.new(0))
)

{nan_struct, ""} = Decimal.parse("NaN")
{nan_struct_val, nan_struct_flag} = Proxy.sanitize_cost(nan_struct)

check.(
  "sanitize_cost/1: %Decimal{} NaN struct → {0, true}",
  nan_struct_flag == true and Decimal.equal?(nan_struct_val, Decimal.new(0))
)

# ── 11. scrub_secret/2 Bearer half ───────────────────────────────────────────

scrubbed_bearer = ProxyPlug.scrub_secret("auth Bearer abc123def456ghi tail", "some-other-key")

check.(
  "scrub_secret/2 redacts Bearer … shaped tokens (Bearer half unchanged by sk- tightening)",
  String.contains?(scrubbed_bearer, "[REDACTED]") and
    not String.contains?(scrubbed_bearer, "abc123def456ghi")
)

# ── 12. scrub_secret/2 does not mangle innocent hyphenated words ─────────────

scrubbed_innocent = ProxyPlug.scrub_secret("my task-management and risk-averse plan", "real-key")

check.(
  "scrub_secret/2 does not mangle innocent hyphenated words after sk- tightening",
  String.contains?(scrubbed_innocent, "task-management") and
    String.contains?(scrubbed_innocent, "risk-averse") and
    not String.contains?(scrubbed_innocent, "[REDACTED]")
)

# ── 13. sanitize_log/1 strips DEL byte (0x7f) ────────────────────────────────

sanitized_del = ProxyPlug.sanitize_log("a" <> <<0x7F>> <> "b")

check.(
  "sanitize_log/1 strips DEL byte (0x7f)",
  not String.contains?(sanitized_del, <<0x7F>>)
)

# ─────────────────────────────────────────────────────────────────────────────

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_FOUNDATIONS: ALL PASS")
else
  IO.puts("LLM_PROXY_FOUNDATIONS: FAILED")
  IO.puts("  Failed: #{Enum.join(Enum.reverse(failed), ", ")}")
  System.halt(1)
end
