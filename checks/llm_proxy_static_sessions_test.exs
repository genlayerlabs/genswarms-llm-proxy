# Static (pre-shared token) sessions — for boot-config agents whose definition is
# DATA evaluated before the proxy object starts, so they cannot mint a token at
# lease time the way pooled spawns do. The host generates the token once, hands it
# to the proxy via `static_sessions:` config AND to the agent's config[:api_key].
#   mix run checks/llm_proxy_static_sessions_test.exs
ExUnit.start()

defmodule GenswarmsLlmProxyStaticSessionsTest do
  use ExUnit.Case, async: false
  alias Genswarms.LlmProxy, as: Proxy

  @token "static_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp fresh_state do
    {:ok, sp} =
      Agent.start(fn -> %{sessions: %{}, usage: %{}, notified: MapSet.new(), global: %{}} end)

    sp
  end

  test "register_static_session stores the session under the SUPPLIED token" do
    sp = fresh_state()

    assert {:ok, @token} =
             Proxy.register_static_session(sp, %{
               token: @token,
               conversation_id: "conversation_sample",
               slot: :conversation_sample,
               kind: "sample",
               workspace_key: "default"
             })

    session = Agent.get(sp, & &1.sessions[@token])
    assert session.conversation_id == "conversation_sample"
    assert session.kind == "sample"
    assert session.budget_identity ==
             Proxy.budget_identity(%{
               workspace_key: "default",
               kind: "sample",
               conversation_id: "conversation_sample"
             })
  end

  test "a short token is rejected (never a silently weak credential)" do
    sp = fresh_state()

    assert {:error, :token_too_short} =
             Proxy.register_static_session(sp, %{
               token: "short",
               conversation_id: "x",
               slot: :x,
               kind: "sample"
             })

    assert Agent.get(sp, &map_size(&1.sessions)) == 0
  end

  test "re-registering the same slot+workspace replaces the old entry (respawn parity)" do
    sp = fresh_state()
    attrs = %{token: @token, conversation_id: "c", slot: :s, kind: "sample"}
    {:ok, _} = Proxy.register_static_session(sp, attrs)

    token2 = "static2_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {:ok, _} = Proxy.register_static_session(sp, Map.put(attrs, :token, token2))

    sessions = Agent.get(sp, & &1.sessions)
    assert map_size(sessions) == 1
    assert Map.has_key?(sessions, token2)
  end

  test "init/1 seeds static_sessions from config; malformed entries never crash boot" do
    port = 41_318 + :rand.uniform(500)

    {:ok, state} =
      Proxy.init(%{
        port: port,
        upstream_endpoint: "http://127.0.0.1:9/never",
        upstream_api_key: "k",
        static_sessions: [
          %{
            token: @token,
            conversation_id: "conversation_sample",
            slot: :conversation_sample,
            kind: "sample"
          },
          # short token — rejected, logged, boot continues
          %{token: "nope", conversation_id: "bad", slot: :bad, kind: "sample"},
          # missing required keys — rejected, logged, boot continues
          %{token: "static_" <> String.duplicate("x", 32)},
          # not even a map
          "garbage"
        ]
      })

    sessions = Agent.get(Proxy.State, & &1.sessions)
    assert Map.has_key?(sessions, @token)
    assert map_size(sessions) == 1

    Proxy.terminate(:normal, state)
  end
end
