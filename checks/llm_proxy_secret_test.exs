# Opaque upstream-key wrapper test for Genswarms.LlmProxy.Secret (defense-in-depth).
# Standalone — NO Postgres, NO network.
#
#   mix run tests/llm_proxy_secret_test.exs
#
# Proves: (a) inspecting any in-memory term that holds the key (plug_opts /
# conn.private / a child-spec / a SASL crash-report shape) NEVER prints the
# cleartext key — the value is stored behind a closure so the default struct
# inspect renders it as `#Function<...>`; (b) the upstream still gets the REAL
# Bearer key because auth_config/scrub_secret reveal/1 the wrapper at the exact
# point of use; (c) reveal/1 is tolerant of a raw string so the ~80 raw-string
# tests stay green; (d) NO String.Chars impl exists, so a stray "#{secret}"
# interpolation fails loudly instead of leaking.
#
# NOTE on mechanism: a `defimpl Inspect` would be IGNORED here — objects are
# has no effect (verified empirically: it leaked the key). The closure makes
# redaction structural and consolidation-independent.

repo_root = Path.expand(Path.join(__DIR__, ".."))


alias Genswarms.LlmProxy.Secret
alias Genswarms.LlmProxy.Plug, as: ProxyPlug

# A trap so a Bandit listener startup crash (port: 0 should never collide, but be safe)
# can't kill this script via the linked listener.
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

sentinel = "real-upstream-key-SENTINEL"

# ── 1. inspect(wrapped) redacts; never prints the key ────────────────────────

inspected = inspect(Secret.wrap(sentinel))

check.(
  "inspect(Secret.wrap(key)) contains no SENTINEL (key redacted)",
  not String.contains?(inspected, "SENTINEL")
)

check.(
  "inspect(Secret.wrap(key)) still names the opaque wrapper type (Secret) + a Function placeholder",
  String.contains?(inspected, "Genswarms.LlmProxy.Secret") and String.contains?(inspected, "#Function")
)

# ── 2. crash-report / conn.private / child-spec shapes never leak ────────────

plug_opts_shape =
  inspect(%{upstream_api_key: Secret.wrap(sentinel), port: 4318, provider: "x"})

check.(
  "inspect of a plug_opts/conn.private map contains no SENTINEL (key redacted)",
  not String.contains?(plug_opts_shape, "SENTINEL") and
    String.contains?(plug_opts_shape, "#Function")
)

child_spec_shape =
  inspect({Genswarms.LlmProxy.Plug, %{upstream_api_key: Secret.wrap(sentinel)}})

check.(
  "inspect of a child-spec tuple {Plug, %{...key...}} contains no SENTINEL",
  not String.contains?(child_spec_shape, "SENTINEL")
)

# ── 3. wrap/reveal contract (idempotent wrap, tolerant reveal, nil) ──────────

check.("reveal(wrap(\"k\")) == \"k\"", Secret.reveal(Secret.wrap("k")) == "k")
check.("reveal(\"k\") == \"k\" (tolerant of raw string)", Secret.reveal("k") == "k")
check.("reveal(nil) == nil", Secret.reveal(nil) == nil)
check.("wrap(nil) == nil", Secret.wrap(nil) == nil)

check.(
  "wrap is idempotent: reveal(wrap(wrap(\"k\"))) == \"k\"",
  Secret.reveal(Secret.wrap(Secret.wrap("k"))) == "k"
)

# ── 4. auth_config still emits the REAL key (curl gets the real bearer) ──────

cfg_wrapped = ProxyPlug.auth_config(Secret.wrap("k"), "sid")
cfg_raw = ProxyPlug.auth_config("k", "sid")

check.(
  "auth_config(Secret.wrap(\"k\"), \"sid\") emits real Bearer + session",
  String.contains?(cfg_wrapped, "Authorization: Bearer k") and
    String.contains?(cfg_wrapped, "x-unhardcoded-session: sid")
)

check.(
  "auth_config raw-string path is identical (reveal tolerance)",
  cfg_raw == cfg_wrapped
)

# And a SENTINEL key reveals fully through auth_config (the production upstream call).
check.(
  "auth_config(Secret.wrap(SENTINEL), sid) yields the full real bearer line",
  String.contains?(
    ProxyPlug.auth_config(Secret.wrap(sentinel), "sid"),
    "Authorization: Bearer #{sentinel}"
  )
)

# ── 5. scrub_secret still scrubs the literal key THROUGH the wrapper ─────────

scrubbed = ProxyPlug.scrub_secret("a #{sentinel} b", Secret.wrap(sentinel))

check.(
  "scrub_secret redacts the literal key passed as a Secret wrapper",
  String.contains?(scrubbed, "[REDACTED]") and not String.contains?(scrubbed, "SENTINEL")
)

# Raw-string scrub still works (the ~80 existing tests' path).
check.(
  "scrub_secret redacts the literal key passed as a raw string (tolerance)",
  ProxyPlug.scrub_secret("a #{sentinel} b", sentinel)
  |> then(&(String.contains?(&1, "[REDACTED]") and not String.contains?(&1, "SENTINEL")))
)

# ── 6. NO String.Chars: a stray "#{secret}" interpolation must fail loudly ───

raised? =
  try do
    _ = to_string(Secret.wrap("k"))
    false
  rescue
    Protocol.UndefinedError -> true
  end

check.(
  "to_string(Secret) raises Protocol.UndefinedError (no silent leak via interpolation)",
  raised?
)

# ── 7. init/1 wraps end-to-end: object state stays clean + wrap reveals real key

# Mirror the production wrap point (init/1 L~62: Secret.wrap(Map.fetch!(config, :upstream_api_key))).
# We assert the EXACT expression init uses produces a redacting-but-revealable Secret, and that a
# real init/1 boot (port: 0 ephemeral) under the SENTINEL key (a) boots without crashing and
# (b) leaves NO cleartext key in the object's returned state (the term :sys.get_state would dump).

config = %{
  upstream_endpoint: "http://127.0.0.1:1/x",
  upstream_api_key: sentinel,
  prices: %{prompt_per_mtok: "0.28", completion_per_mtok: "0.42"},
  port: 0
}

wrapped_at_init = Secret.wrap(Map.fetch!(config, :upstream_api_key))

check.(
  "init wrap-point expression yields a %Secret{} that redacts on inspect",
  is_struct(wrapped_at_init, Secret) and
    not String.contains?(inspect(wrapped_at_init), "SENTINEL")
)

check.(
  "init wrap-point key reveals through auth_config to the REAL bearer (curl works)",
  String.contains?(
    ProxyPlug.auth_config(wrapped_at_init, "sid"),
    "Authorization: Bearer #{sentinel}"
  )
)

case Genswarms.LlmProxy.init(config) do
  {:ok, state} ->
    check.(
      "init/1 boots {:ok, state} under the wrapped SENTINEL key (no crash)",
      is_map(state) and is_pid(state.state_pid)
    )

    check.(
      "init/1 returned object state carries NO cleartext key (sys.get_state-safe)",
      not String.contains?(inspect(state), "SENTINEL")
    )

  other ->
    check.("init/1 boots {:ok, state} under the wrapped SENTINEL key (no crash)", false)
    IO.puts("    init/1 returned: #{inspect(other)}")
end

# ─────────────────────────────────────────────────────────────────────────────

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_SECRET: ALL PASS")
else
  IO.puts("LLM_PROXY_SECRET: FAILED")
  IO.puts("  Failed: #{Enum.join(Enum.reverse(failed), ", ")}")
  System.halt(1)
end
