# Display story events (v0.2.3): the proxy emits llm_proxy_block / llm_proxy_degraded
# on ITS OWN configurable telemetry wire so a host events canvas can show quota
# incidents live, not just as counters. Standalone — no Postgres, no upstream.
#
#   mix run checks/llm_proxy_display_events_test.exs
#
# Pins:
#   * emit_display/1 fires on the app's own wire (:genswarms_llm_proxy, :display_wire),
#     honoring a host override and the [:genswarms, :display] default — the proxy never
#     reads another package's app env (dependency constraint);
#   * emit_display/1 swallows handler crashes (must never affect a request);
#   * emit-site source contract: every block/degrade response path carries its display
#     emit next to the metric bump (the regression that motivated this: counters without
#     story events made quota incidents invisible on the canvas).
ExUnit.start()

defmodule Genswarms.LlmProxyDisplayEventsTest do
  use ExUnit.Case

  @source File.read!(Path.join([__DIR__, "..", "lib", "genswarms", "llm_proxy.ex"]))

  test "emit_display fires on the default wire" do
    :telemetry.attach(
      "disp-default",
      [:genswarms, :display],
      fn _wire, _m, meta, _ -> send(self(), {:got, meta}) end,
      nil
    )

    Genswarms.LlmProxy.Plug.emit_display(%{kind: :llm_proxy_block, cid: "tg:1:0", reason: "budget"})
    assert_receive {:got, %{kind: :llm_proxy_block, cid: "tg:1:0", reason: "budget"}}
    :telemetry.detach("disp-default")
  end

  test "emit_display honors the host wire override (own app env, not genswarms_objects')" do
    Application.put_env(:genswarms_llm_proxy, :display_wire, [:host, :display])

    :telemetry.attach(
      "disp-override",
      [:host, :display],
      fn _wire, _m, meta, _ -> send(self(), {:got, meta}) end,
      nil
    )

    Genswarms.LlmProxy.Plug.emit_display(%{kind: :llm_proxy_degraded, cid: "tg:2:0"})
    assert_receive {:got, %{kind: :llm_proxy_degraded}}
    :telemetry.detach("disp-override")
    Application.delete_env(:genswarms_llm_proxy, :display_wire)
  end

  test "a raising handler never escapes emit_display" do
    :telemetry.attach(
      "disp-boom",
      [:genswarms, :display],
      fn _wire, _m, _meta, _ -> raise "boom" end,
      nil
    )

    assert :ok ==
             Genswarms.LlmProxy.Plug.emit_display(%{kind: :llm_proxy_block, cid: "tg:3:0", reason: "x"})

    :telemetry.detach("disp-boom")
  end

  test "emit-site contract: every block metric bump has its display emit beside it" do
    for {bump, reason} <- [
          {"bump_metric(opts, \"llm_proxy_budget_block\")", "reason: \"budget\""},
          {"bump_metric(opts, \"llm_proxy_request_quota_block\")", "reason: \"request_quota\""},
          {"bump_metric(opts, \"llm_proxy_global_block\")", "reason: \"global\""}
        ] do
      [_, after_bump] = String.split(@source, bump, parts: 2)
      window = String.slice(after_bump, 0, 200)

      assert window =~ "emit_display(%{kind: :llm_proxy_block" and window =~ reason,
             "no llm_proxy_block emit within 200 chars after #{bump}"
    end
  end

  test "emit-site contract: both degraded consolidation points emit llm_proxy_degraded" do
    assert length(String.split(@source, "kind: :llm_proxy_degraded")) - 1 == 2
    assert @source =~ "path: \"budget_status\""
    assert @source =~ "path: \"usage_store\""
  end
end
