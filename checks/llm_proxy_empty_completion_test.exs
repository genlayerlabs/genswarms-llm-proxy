# Empty-completion retry (ported from the micro-markets proxy). Standalone —
# no network: injected upstream fun counts calls.
#
#   mix run checks/llm_proxy_empty_completion_test.exs
ExUnit.start()

defmodule GenswarmsLlmProxyEmptyCompletionTest do
  use ExUnit.Case, async: false
  alias Genswarms.LlmProxy, as: Proxy

  defp opts(state_pid, upstream_calls, extra) do
    Map.merge(
      %{
        state_pid: state_pid,
        upstream_endpoint: "http://127.0.0.1:9/never",
        upstream_api_key: Genswarms.LlmProxy.Secret.wrap("k"),
        provider: "openai-compatible",
        prices: %{},
        margin_pct: 0,
        store_mod: nil,
        default_daily_limit: Decimal.new("5.00"),
        global_daily_limit: Decimal.new("0"),
        daily_request_limit: 0,
        swarm_name: "check",
        sender: :sender,
        metrics: :metrics,
        deliver_fn: fn _, _, _ -> :ok end,
        upstream: fn _body, _headers, _o ->
          n = Agent.get_and_update(upstream_calls, &{&1 + 1, &1 + 1})

          if n == 1 do
            {:ok, 200, %{"choices" => [%{"message" => %{"content" => "  "}}], "usage" => %{}}}
          else
            {:ok, 200,
             %{"choices" => [%{"message" => %{"content" => "real answer"}}], "usage" => %{}}}
          end
        end
      },
      extra
    )
  end

  defp run_completion(o) do
    {:ok, sp} = Proxy.start_state_link()


    {:ok, token} =
      Proxy.register_session(sp, %{
      slot: :agent_0,
      conversation_id: "chk:1",
      kind: "dm",
      workspace_key: "default",
      budget_identity: "chk:1|dm"
    })

    {:ok, calls} = Agent.start_link(fn -> 0 end)
    o = opts(sp, calls, o)

    conn =
      Plug.Test.conn(:post, "/v1/chat/completions", Jason.encode!(%{"messages" => []}))
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = Genswarms.LlmProxy.Plug.call(conn, Genswarms.LlmProxy.Plug.init(Map.to_list(o)))
    {conn, Agent.get(calls, & &1)}
  end

  test "default (0): an empty completion is returned as-is, one upstream call" do
    {conn, calls} = run_completion(%{})
    assert conn.status == 200
    assert calls == 1
  end

  test "empty_completion_retries: 1 — blank content retried once, real answer returned" do
    {conn, calls} = run_completion(%{empty_completion_retries: 1})
    assert conn.status == 200
    assert calls == 2
    assert Jason.decode!(conn.resp_body)["choices"] |> hd() |> get_in(["message", "content"]) == "real answer"
  end
end
