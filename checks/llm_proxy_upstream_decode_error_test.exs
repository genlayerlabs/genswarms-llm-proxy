# The upstream decode-failure error must carry the REAL HTTP status and a
# bounded, scrubbed snippet of the body. Standalone — no network.
#
#   mix run checks/llm_proxy_upstream_decode_error_test.exs
ExUnit.start()

defmodule GenswarmsLlmProxyUpstreamDecodeErrorTest do
  use ExUnit.Case, async: false
  alias Genswarms.LlmProxy.Plug, as: Proxy

  defp message(err), do: get_in(err, ["error", "message"])

  test "a non-JSON body keeps the real upstream status and a snippet of the body" do
    err = Proxy.upstream_decode_error(:non_json, 502, "error code: 502", "sk-secret")

    assert get_in(err, ["error", "code"]) == "upstream_invalid_json"
    assert get_in(err, ["error", "type"]) == "upstream_error"

    msg = message(err)
    # the operator must be able to tell 413 from 502 from 200-with-empty-body
    assert msg =~ "502"
    # and must see what the upstream actually said
    assert msg =~ "error code: 502"
  end

  test "an empty body is reported as empty rather than as an absent reason" do
    msg = message(Proxy.upstream_decode_error(:non_json, 200, "", "sk-secret"))

    assert msg =~ "200"
    assert msg =~ "empty"
  end

  test "the upstream key is never echoed back through the snippet" do
    body = ~s(<html>proxied Authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz</html>)
    msg = message(Proxy.upstream_decode_error(:non_json, 502, body, "sk-abcdefghijklmnopqrstuvwxyz"))

    refute msg =~ "sk-abcdefghijklmnopqrstuvwxyz"
    assert msg =~ "[REDACTED]"
  end

  test "a huge body is bounded and stripped of newlines" do
    msg = message(Proxy.upstream_decode_error(:non_json, 502, String.duplicate("A\nB", 5_000), "k"))

    assert byte_size(msg) < 500
    refute msg =~ "\n"
  end

  test "non-object JSON keeps its own distinct wording" do
    msg = message(Proxy.upstream_decode_error(:non_object_json, 200, "[1,2,3]", "k"))

    assert msg =~ "non-object"
    assert msg =~ "200"
  end
end
