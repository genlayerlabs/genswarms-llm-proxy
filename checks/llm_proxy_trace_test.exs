ExUnit.start()

defmodule TraceCheck.Sink do
  def record_llm_trace(event) do
    send(self(), {:trace, event})
    if Process.get(:fail_trace) == event.type, do: {:error, :disk_full}, else: :ok
  end
end

defmodule TraceCheck do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias Genswarms.LlmProxy, as: Proxy
  alias Genswarms.LlmProxy.Plug, as: P

  setup do
    {:ok, pid} = Proxy.start_state_link([])
    token = String.duplicate("agent-token", 5)
    {:ok, _} = Proxy.register_static_session(pid, %{token: token, conversation_id: "agent-a", slot: :a, kind: "agent", workspace_key: "run-a"})
    upstream = fn body, _, _ ->
      send(self(), {:called, body})
      {:ok, 200, %{"choices" => [%{"message" => %{"content" => "{}", "reasoning" => "private thought"}}], "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2}}}
    end
    opts = P.init(%{state_pid: pid, trace_store_mod: TraceCheck.Sink, upstream: upstream,
      upstream_api_key: "provider-secret", prices: %{}, prompt_cache: false, max_retries: 0})
    %{opts: opts, token: token}
  end

  defp call(c, body \\ %{"messages" => []}) do
    conn(:post, "/v1/chat/completions", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> c.token)
    |> put_req_header("x-agent-turn-id", "turn-1")
    |> P.call(c.opts)
  end

  test "captures I/O privately, uses authenticated ownership and stable request id", c do
    response = call(c, %{"messages" => [%{"content" => "provider-secret"}], "agent_id" => "agent-b"})
    assert response.status == 200
    assert_receive {:trace, %{type: "request", trace_id: id, identity: identity, data: data}}
    assert identity.conversation_id == "agent-a"
    refute Jason.encode!(data) =~ "provider-secret"
    assert_receive {:trace, %{type: "upstream_request", trace_id: ^id}}
    assert_receive {:called, _}
    assert_receive {:trace, %{type: "upstream_result", trace_id: ^id}}
    assert_receive {:trace, %{type: "response", trace_id: ^id, data: %{body: body}}}
    assert body =~ "private thought"
    assert Jason.decode!(body)["x_router"]["request_id"] == id
    assert get_resp_header(response, "x-llm-trace-status") == ["complete"]
  end

  test "failure before dispatch never spends", c do
    Process.put(:fail_trace, "request")
    assert call(c).status == 503
    refute_receive {:called, _}
  end

  test "failure after provider preserves result and blocks subsequent calls", c do
    Process.put(:fail_trace, "upstream_result")
    first = call(c)
    assert first.status == 200
    assert get_resp_header(first, "x-llm-trace-status") == ["incomplete"]
    assert_receive {:called, _}
    assert call(c).status == 503
    refute_receive {:called, _}
  end

  test "stream is explicitly rejected until event capture supports it", c do
    assert call(c, %{"stream" => true}).status == 422
    refute_receive {:called, _}
  end
end
