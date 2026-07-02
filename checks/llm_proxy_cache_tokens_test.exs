# Cache-token split for Genswarms.LlmProxy: per call, cached (prompt-cache READ) vs non-cached
# prompt tokens, parsed from the router's x_router.tokens_cached (canonical) with the
# OpenAI usage.prompt_tokens_details.cached_tokens fallback, non-cached derived.
# Standalone — NO Postgres, NO network.
#
#   mix run tests/llm_proxy_cache_tokens_test.exs

repo_root = Path.expand(Path.join(__DIR__, ".."))


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

split = fn usage, router -> Proxy.cache_split(usage, router) end

# ── 1. canonical x_router.tokens_cached drives the split ─────────────────────
check.(
  "x_router.tokens_cached=400 of prompt 1000 → {400, 600}",
  split.(%{"prompt_tokens" => 1000}, %{"tokens_cached" => 400}) == {400, 600}
)

# ── 2. tokens_cached null/absent → fall back to OpenAI usage detail ───────────
check.(
  "tokens_cached null → usage.prompt_tokens_details.cached_tokens=250 → {250, 750}",
  split.(
    %{"prompt_tokens" => 1000, "prompt_tokens_details" => %{"cached_tokens" => 250}},
    %{"tokens_cached" => nil}
  ) == {250, 750}
)

# ── 3. both absent → nothing cached; all prompt tokens are fresh ─────────────
check.(
  "no cache fields → {0, prompt}",
  split.(%{"prompt_tokens" => 1000}, %{}) == {0, 1000}
)

# ── 4. canonical wins over the usage fallback when both present ──────────────
check.(
  "x_router.tokens_cached=400 beats usage detail 999 (canonical wins) → {400, 600}",
  split.(
    %{"prompt_tokens" => 1000, "prompt_tokens_details" => %{"cached_tokens" => 999}},
    %{"tokens_cached" => 400}
  ) == {400, 600}
)

# ── 5. cached == prompt → all cached, zero fresh ─────────────────────────────
check.(
  "fully cached prompt → {prompt, 0}",
  split.(%{"prompt_tokens" => 800}, %{"tokens_cached" => 800}) == {800, 0}
)

# ── 6. anomalous cached > prompt → clamped so the halves sum to prompt ───────
check.(
  "cached 5000 > prompt 1000 (hostile) → clamped {1000, 0}",
  split.(%{"prompt_tokens" => 1000}, %{"tokens_cached" => 5000}) == {1000, 0}
)

# ── 7. negative cached (hostile) → floored to 0 ──────────────────────────────
check.(
  "negative tokens_cached → floored {0, prompt}",
  split.(%{"prompt_tokens" => 1000}, %{"tokens_cached" => -7}) == {0, 1000}
)

# ── 8. missing prompt_tokens → {0, 0} (cannot manufacture a split) ───────────
check.(
  "no prompt_tokens → {0, 0}",
  split.(%{}, %{"tokens_cached" => 400}) == {0, 0}
)

# ── 9. string-valued tokens (non-integer) coerce to 0, never raise ───────────
check.(
  "string prompt_tokens coerces to 0 → {0, 0}",
  split.(%{"prompt_tokens" => "1000"}, %{"tokens_cached" => 400}) == {0, 0}
)

# ── 10. non-map args (defensive) → {0, 0} ────────────────────────────────────
check.(
  "nil usage/router → {0, 0}",
  split.(nil, nil) == {0, 0} and split.(%{"prompt_tokens" => 1000}, nil) == {0, 0}
)

# ── 11. invariant: cached + non_cached == prompt, both ≥ 0 (random-ish fuzz) ─
fuzz_ok =
  Enum.all?([{0, 0}, {10, 0}, {10, 4}, {4, 10}, {1000, 1000}, {1, 0}], fn {p, c} ->
    {cached, non_cached} = split.(%{"prompt_tokens" => p}, %{"tokens_cached" => c})
    cached >= 0 and non_cached >= 0 and cached + non_cached == p
  end)

check.("invariant cached+non_cached==prompt and both ≥ 0 holds across cases", fuzz_ok)

fails = Agent.get(failures, & &1)

if fails == [] do
  IO.puts("\nLLM_PROXY_CACHE_TOKENS: ALL PASS")
else
  IO.puts("\nLLM_PROXY_CACHE_TOKENS: #{length(fails)} FAILED")
  System.halt(1)
end
