# C4 — budget_identity/1 is a PINNED host-facing contract. Standalone.
#
#   mix run checks/llm_proxy_budget_identity_golden_test.exs
#
# Hosts derive a payment beneficiary from budget_identity/1, and from that a
# per-user deposit address. A change to the input list, the NUL join, the
# digest, the encoding, or the "llmb_" prefix silently RE-KEYS every user's
# deposit address: money already sent to the old address lands on an identity
# nothing reads, and every existing credit balance is orphaned. No migration
# recovers a deposit made against a derivation that no longer exists.
#
# So the shape is pinned by a GOLDEN VECTOR on both sides of the composition.
# The host's rev4 composition check (D8) asserts the SAME primary vector; if
# you change either, both fail loudly — which is the point.
#
#     ("default", "dm", "tg:1:0") -> "llmb_xDByWmMCGVabJZ7C9tBC16tKsVUOYlcbah1O0Sz2aNI"
#
# A failure here is NOT a test to update. It means the derivation moved, and
# that is a coordinated MAJOR migration, never a refactor.

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

# ── THE GOLDEN VECTORS — pinned literals, never computed ─────────────────────
primary = "llmb_xDByWmMCGVabJZ7C9tBC16tKsVUOYlcbah1O0Sz2aNI"
secondary = "llmb_IGspOgc2gzFtloNaavuT5FuDRGw8hL2K_8uYnkivxUo"

IO.puts("\n[Golden vectors]")

check.(
  "PRIMARY: (workspace \"default\", kind \"dm\", cid \"tg:1:0\") -> #{primary}",
  Proxy.budget_identity(%{workspace_key: "default", kind: "dm", conversation_id: "tg:1:0"}) ==
    primary
)

check.(
  "SECONDARY: (workspace \"rally\", kind \"group\", cid \"tg:-100200300:7\") -> #{secondary}",
  Proxy.budget_identity(%{
    workspace_key: "rally",
    kind: "group",
    conversation_id: "tg:-100200300:7"
  }) == secondary
)

IO.puts("\n[Pinned coercions — these must NOT change the identity]")

check.(
  "an omitted workspace_key defaults to \"default\" (same identity)",
  Proxy.budget_identity(%{kind: "dm", conversation_id: "tg:1:0"}) == primary
)

check.(
  "atom workspace_key/kind coerce to their binaries (same identity)",
  Proxy.budget_identity(%{workspace_key: :default, kind: :dm, conversation_id: "tg:1:0"}) ==
    primary
)

check.(
  "extra keys in attrs are ignored — only (workspace_key, kind, conversation_id) feed it",
  Proxy.budget_identity(%{
    workspace_key: "default",
    kind: "dm",
    conversation_id: "tg:1:0",
    slot: :agent_1,
    daily_limit_usd: "9.99",
    notify: false
  }) == primary
)

IO.puts("\n[Pinned separations — these MUST change the identity]")

check.(
  "a different workspace_key is a different identity",
  Proxy.budget_identity(%{workspace_key: "other", kind: "dm", conversation_id: "tg:1:0"}) !=
    primary
)

check.(
  "a different kind is a different identity (dm and group never share a budget)",
  Proxy.budget_identity(%{workspace_key: "default", kind: "group", conversation_id: "tg:1:0"}) !=
    primary
)

check.(
  "a different conversation_id is a different identity",
  Proxy.budget_identity(%{workspace_key: "default", kind: "dm", conversation_id: "tg:2:0"}) !=
    primary
)

# The NUL join is what makes the three fields unambiguous: without it,
# ("default","dm","x") and ("default","dmx","") would collide — and a collision
# here means two conversations sharing one deposit address and one balance.
check.(
  "the field join is unambiguous — no boundary-shifting collision",
  Proxy.budget_identity(%{workspace_key: "default", kind: "dm", conversation_id: "x"}) !=
    Proxy.budget_identity(%{workspace_key: "default", kind: "dmx", conversation_id: ""})
)

IO.puts("\n[Pinned shape]")

check.(
  "the identity is \"llmb_\" + 43-char url-safe base64 (unpadded sha256)",
  String.starts_with?(primary, "llmb_") and byte_size(primary) == 5 + 43 and
    match?({:ok, <<_::256>>}, Base.url_decode64(String.trim_leading(primary, "llmb_"), padding: false))
)

check.(
  "budget_identity/1 is PUBLIC (hosts call it — it must never become private)",
  function_exported?(Proxy, :budget_identity, 1)
)

check.(
  "it is deterministic across calls",
  Proxy.budget_identity(%{kind: "dm", conversation_id: "tg:1:0"}) ==
    Proxy.budget_identity(%{kind: "dm", conversation_id: "tg:1:0"})
)

# register_session/2 must derive the SAME identity — the host stamps deposits
# against this value, so a session bound under a different one is unpayable.
{:ok, pid} = Proxy.start_state_link()

{:ok, token} =
  Proxy.register_session(pid, %{
    conversation_id: "tg:1:0",
    slot: :golden_agent,
    kind: :dm,
    workspace_key: "default"
  })

check.(
  "register_session/2 binds the session to the SAME golden identity",
  Proxy.lookup_session(pid, token).budget_identity == primary
)

# ─────────────────────────────────────────────────────────────────────────────
failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_BUDGET_IDENTITY_GOLDEN: ALL PASS")
else
  IO.puts("LLM_PROXY_BUDGET_IDENTITY_GOLDEN: FAILED (#{length(failed)} check(s))")
  IO.puts("  A failure here means the PINNED derivation moved — see the header.")
  failed |> Enum.reverse() |> Enum.each(&IO.puts("  FAIL #{&1}"))
  System.halt(1)
end
