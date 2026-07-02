# LLM proxy bounded retry (Task 6). Standalone — NO Postgres, NO network.
#
#   mix run tests/llm_proxy_retry_test.exs
#
# Drives call_upstream/3 directly (exposed @doc false) with an injected :upstream
# seam so no real curl is needed. Verifies:
#   * decode-failure ({:error,502,_}) is NOT retried (never reached call_with_retry retry path)
#   * genuine 5xx ({:ok,5xx,_}) is NOT retried (not an {:error,{:curl,_}} result)
#   * connect-phase codes 6 and 7 ARE retried (request never reached server)
#   * post-send code 28 is NOT retried (may have been billed)
#   * 4xx is not retried
#   * max_retries is clamped to 3 (1 + 3 = 4 attempts when always failing with curl 7)
#   * latency_ms is cumulative across attempts (≥ backoff sleep duration)
#   * no = transient unused-binding in source

Application.ensure_all_started(:plug)


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

# Minimal opts for call_upstream. Includes the fields it reads:
#   upstream_api_key — used in headers
#   swarm_name / metrics / deliver_fn — for bump_metric inside call_with_retry
make_opts = fn overrides ->
  base = %{
    upstream_api_key: "test-key",
    swarm_name: "test-swarm",
    metrics: :test_metrics,
    deliver_fn: fn _, _, _, _ -> :ok end
  }

  Map.merge(base, overrides)
end

# Minimal request context (session_id used in header + body injection).
ctx = %{session_id: "test-session-id"}

# Helper: build a scripted upstream that returns responses in order,
# holding the last item forever once the list is exhausted. Also counts calls.
scripted = fn responses, count_agent ->
  {:ok, resp_agent} = Agent.start_link(fn -> responses end)

  fn body, headers, opts ->
    Agent.update(count_agent, &(&1 + 1))

    Agent.get_and_update(resp_agent, fn
      [h] -> {h, [h]}
      [h | t] -> {h, t}
    end)
    |> then(fn resp ->
      # Allow the scripted fn itself to be a 3-arity function for passthrough
      case resp do
        f when is_function(f, 3) -> f.(body, headers, opts)
        val -> val
      end
    end)
  end
end

# ──────────────────────────────────────────────────────────────────────────────
# Test 1 — decode-failure is NOT retried
# {:error, 502, decode_error_map} comes AFTER receipt (may be billed). The
# result is NOT {:error, {:curl, 6|7}} so call_with_retry passes it straight
# through. call_upstream maps it to {:ok, 502, _, _} via the {:error, s, r}
# clause.
# ──────────────────────────────────────────────────────────────────────────────

{:ok, t1_count} = Agent.start_link(fn -> 0 end)

t1_upstream =
  scripted.(
    [
      {:error, 502,
       %{"error" => %{"message" => "bad", "type" => "upstream_error", "code" => "upstream_invalid_json"}}}
    ],
    t1_count
  )

t1 =
  ProxyPlug.call_upstream(
    %{"model" => "test"},
    make_opts.(%{upstream: t1_upstream, max_retries: 1}),
    ctx
  )

check.(
  "1: decode-failure {:error,502,_} NOT retried — counter==1, returns {:ok,502,_,_}",
  Agent.get(t1_count, & &1) == 1 and match?({:ok, 502, _, _, _}, t1)
)

# ──────────────────────────────────────────────────────────────────────────────
# Test 2 — genuine 5xx is NOT retried
# {:ok, 503, body} is a real server response — call_with_retry never matches
# it against the retry clause (only {:error, {:curl, 6|7}} retries).
# ──────────────────────────────────────────────────────────────────────────────

{:ok, t2_count} = Agent.start_link(fn -> 0 end)

t2_upstream =
  scripted.(
    [
      {:ok, 503,
       %{"error" => %{"message" => "upstream overloaded", "type" => "server_error", "code" => "503"}}}
    ],
    t2_count
  )

t2 =
  ProxyPlug.call_upstream(
    %{"model" => "test"},
    make_opts.(%{upstream: t2_upstream, max_retries: 1}),
    ctx
  )

check.(
  "2: genuine 5xx {:ok,503,_} NOT retried — counter==1, returns {:ok,503,_,_}",
  Agent.get(t2_count, & &1) == 1 and match?({:ok, 503, _, _, _}, t2)
)

# ──────────────────────────────────────────────────────────────────────────────
# Test 3 — connect-phase curl 7 IS retried
# First call returns {:error, {:curl, 7}} (couldn't connect — request never
# sent). call_with_retry bumps metric, sleeps, and retries. Second call returns
# {:ok, 200, completion}.
# ──────────────────────────────────────────────────────────────────────────────

{:ok, t3_count} = Agent.start_link(fn -> 0 end)

t3_completion = %{
  "id" => "chatcmpl-t3",
  "object" => "chat.completion",
  "model" => "test-model",
  "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}],
  "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2, "total_tokens" => 7}
}

t3_upstream =
  scripted.(
    [
      {:error, {:curl, 7}},
      {:ok, 200, t3_completion}
    ],
    t3_count
  )

t3 =
  ProxyPlug.call_upstream(
    %{"model" => "test"},
    make_opts.(%{upstream: t3_upstream, max_retries: 1}),
    ctx
  )

check.(
  "3: {:error,{:curl,7}} retried once, counter==2, returns {:ok,200,_,_}",
  Agent.get(t3_count, & &1) == 2 and match?({:ok, 200, _, _, _}, t3)
)

# ──────────────────────────────────────────────────────────────────────────────
# Test 4 — post-send timeout (curl 28) is NOT retried
# curl 28 = timeout after the request was sent; upstream may have processed/billed
# it. call_with_retry matches the `other ->` clause and returns immediately.
# call_upstream maps {:error, {:curl, 28}} to {:ok, 502, error_map, latency_ms}.
# ──────────────────────────────────────────────────────────────────────────────

{:ok, t4_count} = Agent.start_link(fn -> 0 end)

t4_upstream =
  scripted.(
    [
      {:error, {:curl, 28}},
      {:ok, 200, %{"choices" => []}}
    ],
    t4_count
  )

t4 =
  ProxyPlug.call_upstream(
    %{"model" => "test"},
    make_opts.(%{upstream: t4_upstream, max_retries: 1}),
    ctx
  )

check.(
  "4: {:error,{:curl,28}} (post-send) NOT retried — counter==1, returns {:ok,502,_,_}",
  Agent.get(t4_count, & &1) == 1 and match?({:ok, 502, _, _, _}, t4)
)

# ──────────────────────────────────────────────────────────────────────────────
# Test 5 — 4xx is not retried
# {:ok, 400, _} is an upstream error response, not a transport failure.
# ──────────────────────────────────────────────────────────────────────────────

{:ok, t5_count} = Agent.start_link(fn -> 0 end)

t5_upstream =
  scripted.(
    [{:ok, 400, %{"error" => %{"message" => "bad request", "type" => "invalid", "code" => "400"}}}],
    t5_count
  )

t5 =
  ProxyPlug.call_upstream(
    %{"model" => "test"},
    make_opts.(%{upstream: t5_upstream, max_retries: 1}),
    ctx
  )

check.(
  "5: {:ok,400,_} (4xx) NOT retried — counter==1, returns {:ok,400,_,_}",
  Agent.get(t5_count, & &1) == 1 and match?({:ok, 400, _, _, _}, t5)
)

# ──────────────────────────────────────────────────────────────────────────────
# Test 6 — clamp: max_retries > 3 is clamped to 3 (1 original + 3 retries = 4)
# Also verifies exactly 3 llm_proxy_upstream_retry metric bumps.
# ──────────────────────────────────────────────────────────────────────────────

check.(
  "6a: clamp formula min(max(50,0),3) == 3",
  min(max(50, 0), 3) == 3
)

{:ok, t6_count} = Agent.start_link(fn -> 0 end)
{:ok, t6_metrics} = Agent.start_link(fn -> [] end)

t6_upstream = scripted.([{:error, {:curl, 7}}], t6_count)

t6_opts =
  make_opts.(%{
    upstream: t6_upstream,
    # max_retries: 50 drives call_upstream's own min(max(_,0),3) clamp end-to-end — without
    # the clamp this would retry 50× (51 attempts). Proves deleting the clamp fails a test.
    max_retries: 50,
    deliver_fn: fn _, _, _, json ->
      case Jason.decode(json) do
        {:ok, %{"action" => "bump", "key" => key}} ->
          Agent.update(t6_metrics, &[key | &1])

        _ ->
          :ok
      end

      :ok
    end
  })

_t6 = ProxyPlug.call_upstream(%{"model" => "test"}, t6_opts, ctx)

t6_attempt_count = Agent.get(t6_count, & &1)
t6_bump_count = Agent.get(t6_metrics, & &1) |> Enum.count(&(&1 == "llm_proxy_upstream_retry"))

check.(
  "6b: max_retries:50 CLAMPED to 3 → exactly 4 attempts (1 + 3 retries), always curl-7",
  t6_attempt_count == 4
)

check.(
  "6c: exactly 3 llm_proxy_upstream_retry metric bumps (clamp proven end-to-end)",
  t6_bump_count == 3
)

# ──────────────────────────────────────────────────────────────────────────────
# Test 7 — latency_ms is cumulative (includes backoff sleep ≥ 100ms)
# curl-7 on first attempt triggers a 100–250ms backoff before retry. The
# returned latency_ms must reflect total wall-clock time (≥ 100ms).
# ──────────────────────────────────────────────────────────────────────────────

{:ok, t7_count} = Agent.start_link(fn -> 0 end)

t7_completion = %{
  "id" => "chatcmpl-t7",
  "object" => "chat.completion",
  "model" => "test-model",
  "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}],
  "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
}

t7_upstream =
  scripted.(
    [
      {:error, {:curl, 7}},
      {:ok, 200, t7_completion}
    ],
    t7_count
  )

t7 =
  ProxyPlug.call_upstream(
    %{"model" => "test"},
    make_opts.(%{upstream: t7_upstream, max_retries: 1}),
    ctx
  )

{:ok, _t7_status, _t7_body, t7_latency_ms, _t7_discarded} = t7

check.(
  "7: latency_ms is cumulative across attempts — latency_ms ≥ 100 (includes backoff sleep)",
  t7_latency_ms >= 100
)

# ──────────────────────────────────────────────────────────────────────────────
# Test 8 — no = transient unused binding in source
# The rev1 plan had a = transient binding that emitted a compile-time warning.
# ──────────────────────────────────────────────────────────────────────────────

proxy_source = File.read!(Path.expand("../lib/genswarms/llm_proxy.ex", __DIR__))

check.(
  "8: source contains no '= transient' unused-binding",
  not String.contains?(proxy_source, "= transient")
)

# ──────────────────────────────────────────────────────────────────────────────
# Result
# ──────────────────────────────────────────────────────────────────────────────

fail_list = Agent.get(failures, & &1)

if fail_list == [] do
  IO.puts("\nLLM_PROXY_RETRY: ALL PASS")
else
  IO.puts("\nLLM_PROXY_RETRY: #{length(fail_list)} FAILED")
  for f <- Enum.reverse(fail_list), do: IO.puts("  FAIL  #{f}")
  System.halt(1)
end
