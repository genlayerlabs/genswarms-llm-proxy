# LLM proxy streaming transport (Task 7). Standalone — NO Postgres.
#
#   mix run tests/llm_proxy_stream_test.exs
#
# Two layers:
#   1. PURE-STRING unit tests for the framing/sniff/status logic that a Bandit
#      stub cannot control (Port read boundaries, split frames, CRLF, BOM, interim
#      1xx) — driven directly against the exposed @doc false helpers.
#   2. REAL-HTTP integration: a Bandit SSE stub (the "upstream") + the REAL proxy
#      as a second Bandit listener, exercised through curl / raw :gen_tcp clients.
#
# Task 7 is TRANSPORT ONLY: passthrough + correct status capture + leak-proof
# resource handling + gating. Cost accounting / budget-exhausted SSE / include_usage
# chunk-strip are Task 8 — finish_stream(:stream) returns the conn with NO accounting.

Application.ensure_all_started(:plug)
Application.ensure_all_started(:bandit)


alias Genswarms.LlmProxy, as: Proxy
alias Genswarms.LlmProxy.Plug, as: ProxyPlug

import Plug.Test
import Plug.Conn, only: [put_req_header: 3]

{:ok, failures} = Agent.start_link(fn -> [] end)

check = fn label, ok ->
  if ok do
    IO.puts("  ok   #{label}")
  else
    IO.puts("  FAIL #{label}")
    Agent.update(failures, &[label | &1])
  end
end

tmp = System.tmp_dir!()
proxy_glob = Path.join(tmp, "wingston-llm-proxy-*")

# Poll until `fun` is truthy or the deadline passes. Returns the final truthiness.
wait_until = fn fun, timeout_ms ->
  deadline = System.monotonic_time(:millisecond) + timeout_ms

  loop = fn loop ->
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(40) && loop.(loop)
    end
  end

  loop.(loop)
end

# A temp file we write the curl header dump to for the dump_header_status units.
write_hdr = fn content ->
  path = Path.join(tmp, "wingston-stream-hdr-#{:erlang.unique_integer([:positive])}.txt")
  File.write!(path, content)
  path
end

# ═══════════════════════════════════════════════════════════════════════════════
# UNIT 1 — dump_header_status/1: FINAL status, 1xx-reject, HTTP/2, missing → 502
# ═══════════════════════════════════════════════════════════════════════════════

h1 = write_hdr.("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n")
check.("dump_header_status: 100-continue then 200 → 200 (final, not the 100)", ProxyPlug.dump_header_status(h1) == 200)
File.rm(h1)

h2 = write_hdr.("HTTP/1.1 103 Early Hints\r\nLink: </s.css>\r\n\r\nHTTP/2 500\r\n")
check.("dump_header_status: 103 early-hints then HTTP/2 500 → 500", ProxyPlug.dump_header_status(h2) == 500)
File.rm(h2)

h3 = write_hdr.("HTTP/1.1 200 Connection established\r\n\r\nHTTP/1.1 502 Bad Gateway\r\n")
check.("dump_header_status: CONNECT 200 then 502 → 502 (final wins, 200 not 1xx but last)", ProxyPlug.dump_header_status(h3) == 502)
File.rm(h3)

h4 = write_hdr.("HTTP/2 429 \r\n")
check.("dump_header_status: HTTP/2 429 (no reason phrase) → 429", ProxyPlug.dump_header_status(h4) == 429)
File.rm(h4)

h5 = write_hdr.("")
check.("dump_header_status: empty file → 502 (never 200)", ProxyPlug.dump_header_status(h5) == 502)
File.rm(h5)

check.(
  "dump_header_status: nonexistent path → 502",
  ProxyPlug.dump_header_status(Path.join(tmp, "no-such-hdr-#{:erlang.unique_integer([:positive])}.txt")) == 502
)

h6 = write_hdr.("HTTP/1.1 99999 X\r\n")
check.("dump_header_status: out-of-range 99999 → clamped to 502", ProxyPlug.dump_header_status(h6) == 502)
File.rm(h6)

h7 = write_hdr.("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early\r\n\r\n")
check.("dump_header_status: only 1xx statuses → 502 (no usable final)", ProxyPlug.dump_header_status(h7) == 502)
File.rm(h7)

# ═══════════════════════════════════════════════════════════════════════════════
# UNIT 2 — sniff_decision/1 + sse_prefix?/1 (mode transition, pure)
# ═══════════════════════════════════════════════════════════════════════════════

check.("sniff: data:-led → :stream", ProxyPlug.sniff_decision("data: {\"choices\":[]}\n\n") == :stream)
check.("sniff: event:-led → :stream", ProxyPlug.sniff_decision("event: message\ndata: {}\n\n") == :stream)
check.("sniff: ': keepalive' comment first → :undecided (does NOT commit)", ProxyPlug.sniff_decision(": keepalive\n\n") == :undecided)
check.("sniff: bare 'id: 5' (no data yet) → :undecided", ProxyPlug.sniff_decision("id: 5\n") == :undecided)
check.("sniff: 'id: 5' then 'data:' → :stream (commits on the data field)", ProxyPlug.sniff_decision("id: 5\ndata: {}\n\n") == :stream)
check.("sniff: 'retry: 1000' then 'data:' → :stream", ProxyPlug.sniff_decision("retry: 1000\ndata: {}\n\n") == :stream)
check.("sniff: leading UTF-8 BOM then 'data:' → :stream (BOM stripped)", ProxyPlug.sniff_decision(<<0xEF, 0xBB, 0xBF>> <> "data: {}\n\n") == :stream)
check.("sniff: leading '{' → :buffer (JSON, non-SSE)", ProxyPlug.sniff_decision("{\"error\":{\"message\":\"x\"}}") == :buffer)
check.("sniff: leading '[' → :buffer", ProxyPlug.sniff_decision("[1,2,3]") == :buffer)
check.("sniff: empty buffer → :undecided", ProxyPlug.sniff_decision("") == :undecided)
check.("sniff: BOM then '{' → :buffer", ProxyPlug.sniff_decision(<<0xEF, 0xBB, 0xBF>> <> "{\"a\":1}") == :buffer)
check.("sniff: non-SSE non-JSON blob → :undecided (stays sniffing)", ProxyPlug.sniff_decision("AAAAAAAAAA") == :undecided)

check.("sse_prefix?: data: → true", ProxyPlug.sse_prefix?("data: {}"))
check.("sse_prefix?: event: → true", ProxyPlug.sse_prefix?("event: ping"))
check.("sse_prefix?: comment ':' → false", not ProxyPlug.sse_prefix?(": hi"))
check.("sse_prefix?: 'database:' is NOT 'data:' (no false positive)", not ProxyPlug.sse_prefix?("database: x"))

# ═══════════════════════════════════════════════════════════════════════════════
# UNIT 3 — bounded_tail/2
# ═══════════════════════════════════════════════════════════════════════════════

check.("bounded_tail(\"0123456789\", 4) == \"6789\"", ProxyPlug.bounded_tail("0123456789", 4) == "6789")
check.("bounded_tail(\"ab\", 4) == \"ab\" (shorter than n, unchanged)", ProxyPlug.bounded_tail("ab", 4) == "ab")
check.("bounded_tail bounds a 200KB blob to exactly 64KB", byte_size(ProxyPlug.bounded_tail(String.duplicate("x", 200_000), 65_536)) == 65_536)

# ═══════════════════════════════════════════════════════════════════════════════
# UNIT 4 — streaming?/1 (tolerant) + ensure_stream_usage/1
# ═══════════════════════════════════════════════════════════════════════════════

check.(
  "streaming?: true / \"true\" / 1 → true; false / nil / \"no\" → false",
  ProxyPlug.streaming?(%{"stream" => true}) and ProxyPlug.streaming?(%{"stream" => "true"}) and
    ProxyPlug.streaming?(%{"stream" => 1}) and not ProxyPlug.streaming?(%{"stream" => false}) and
    not ProxyPlug.streaming?(%{}) and not ProxyPlug.streaming?(%{"stream" => "no"})
)

esu1 = ProxyPlug.ensure_stream_usage(%{"model" => "m"})
esu2 = ProxyPlug.ensure_stream_usage(%{"model" => "m", "stream_options" => %{"foo" => 1}})

check.(
  "ensure_stream_usage: sets include_usage:true, preserving any existing stream_options",
  get_in(esu1, ["stream_options", "include_usage"]) == true and
    get_in(esu2, ["stream_options", "include_usage"]) == true and
    get_in(esu2, ["stream_options", "foo"]) == 1
)

# ═══════════════════════════════════════════════════════════════════════════════
# UNIT 5 — stream_curl_args/5 + default_port_open source (no :stderr_to_stdout)
# ═══════════════════════════════════════════════════════════════════════════════

test_key = "real-upstream-key-SENTINEL"
test_sid = "llms_secret_session_id"
sca = ProxyPlug.stream_curl_args("/tmp/body.json", "https://up.example/v1/chat/completions", "/tmp/cfg.conf", "/tmp/hdr.txt", %{})

adjacent? = fn list, a, b -> list |> Enum.zip(tl(list)) |> Enum.any?(fn {x, y} -> x == a and y == b end) end

check.(
  "stream_curl_args: --config, --dump-header, --data-binary @body, --no-buffer, -H Expect:, endpoint-last, NO -w",
  adjacent?.(sca, "--config", "/tmp/cfg.conf") and
    adjacent?.(sca, "--dump-header", "/tmp/hdr.txt") and
    adjacent?.(sca, "--data-binary", "@/tmp/body.json") and
    "--no-buffer" in sca and
    adjacent?.(sca, "-H", "Expect:") and
    "Content-Type: application/json" in sca and
    List.last(sca) == "https://up.example/v1/chat/completions" and
    not ("-w" in sca)
)

check.(
  "stream_curl_args: respects stream_timeout_s / connect_timeout_s",
  ProxyPlug.stream_curl_args("/b", "http://x", "/c", "/h", %{stream_timeout_s: 77, connect_timeout_s: 9})
  |> then(fn a -> adjacent?.(a, "--max-time", "77") and adjacent?.(a, "--connect-timeout", "9") end)
)

sca_secret = ProxyPlug.stream_curl_args("/tmp/body.json", "https://up.example/v1/chat/completions", "/tmp/cfg.conf", "/tmp/hdr.txt", %{upstream_api_key: test_key})

check.(
  "stream_curl_args: neither the key nor a session id ever appears in argv (only --config carries secrets)",
  not Enum.any?(sca_secret, &String.contains?(to_string(&1), test_key)) and
    not Enum.any?(sca_secret, &String.contains?(to_string(&1), test_sid))
)

proxy_source = File.read!(Path.expand("../lib/genswarms/llm_proxy.ex", __DIR__))

port_open_line =
  proxy_source
  |> String.split("\n")
  |> Enum.find(&String.contains?(&1, "Port.open({:spawn_executable"))

check.(
  "default_port_open: Port.open is invoked WITHOUT :stderr_to_stdout (curl stderr stays off the SSE stream)",
  is_binary(port_open_line) and not String.contains?(port_open_line, ":stderr_to_stdout")
)

check.(
  "handle_stream_data(:stream): rolling acc is bounded via bounded_tail(.., 65_536)",
  String.contains?(proxy_source, "bounded_tail(s.acc <> data, 65_536)")
)

check.(
  "stream_upstream: NEVER routes through call_upstream / call_with_retry",
  not (proxy_source |> String.split("defp stream_upstream") |> Enum.at(1, "") |> String.split("\n  defp ") |> List.first() |> String.contains?("call_upstream"))
)

# ═══════════════════════════════════════════════════════════════════════════════
# Shared seams for the Plug.Test + integration cases
# ═══════════════════════════════════════════════════════════════════════════════

defmodule Genswarms.LlmProxy.StreamFakeStore do
  # Always non-exhausted so every request reaches the dispatch cond's later arms.
  def llm_budget_status(_identity, _day, _session_id, _limit), do: %{spent_usd: Decimal.new("0"), limit_usd: Decimal.new("100")}
  def record_llm_call(_identity, _day, _session_id, _attrs), do: %{}
end

{:ok, metrics_agent} = Agent.start_link(fn -> [] end)
{:ok, state_pid} = Proxy.start_state_link()

session_attrs = %{conversation_id: "tg:stream:0", slot: :stream_agent, kind: :dm, workspace_key: "streamws"}
{:ok, token} = Proxy.register_session(state_pid, session_attrs)

metrics_deliver = fn _sw, _to, :llm_proxy, json ->
  case Jason.decode(json) do
    {:ok, %{"action" => "bump", "key" => key}} -> Agent.update(metrics_agent, &[key | &1])
    _ -> :ok
  end

  :ok
end

base_opts = %{
  state_pid: state_pid,
  upstream_endpoint: "http://127.0.0.1:1/v1/chat/completions",
  upstream_api_key: test_key,
  provider: "stream-unit",
  prices: %{},
  store_mod: Genswarms.LlmProxy.StreamFakeStore,
  clock: fn -> ~U[2026-06-25 12:00:00Z] end,
  swarm_name: "wingston",
  sender: :sender,
  metrics: :test_metrics,
  deliver_fn: metrics_deliver,
  allow_streaming: true
}

# ═══════════════════════════════════════════════════════════════════════════════
# LEAK-PROOF — :port_open seam forced to raise → clean 502, ZERO leftover temp files
# Driven via Plug.Test (no curl is ever spawned) so it isolates stream_upstream's
# try/after/rescue nesting precisely.
# ═══════════════════════════════════════════════════════════════════════════════

before_leak = MapSet.new(Path.wildcard(proxy_glob))

leak_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(%{"model" => "leak", "messages" => [], "stream" => true}))
  |> put_req_header("authorization", "Bearer #{token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.put(base_opts, :port_open, fn _bin, _args -> raise "boom" end)))

leak_body = Jason.decode!(leak_conn.resp_body)
after_leak = MapSet.new(Path.wildcard(proxy_glob))
leaked = MapSet.difference(after_leak, before_leak) |> MapSet.to_list()

check.(
  "leak-proof: port_open raise → clean 502 proxy_internal (not a propagated 500)",
  leak_conn.status == 502 and get_in(leak_body, ["error", "code"]) == "proxy_internal"
)

check.(
  "leak-proof: ZERO leftover wingston-llm-proxy-* temp files (cfg/body/hdr all removed in after blocks)",
  leaked == []
)

check.(
  "leak-proof: the key-bearing .conf never survives — no leftover file contains the SENTINEL key",
  not Enum.any?(MapSet.to_list(after_leak), fn p -> match?({:ok, c} when is_binary(c), File.read(p)) and String.contains?(File.read!(p), test_key) end)
)

# ═══════════════════════════════════════════════════════════════════════════════
# ROUTE — HEAD/GET/OPTIONS on /v1/chat/completions → 404 (never enters streaming)
# ═══════════════════════════════════════════════════════════════════════════════

for method <- [:get, :head, :options] do
  rc = conn(method, "/v1/chat/completions") |> ProxyPlug.call(ProxyPlug.init(base_opts))
  check.("route: #{method} /v1/chat/completions → 404", rc.status == 404)
end

# ═══════════════════════════════════════════════════════════════════════════════
# DISABLED-BY-DEFAULT — allow_streaming:false + stream:true → BUFFERED path,
# forwarded body has stream:false, no SSE content-type, no Port.open.
# ═══════════════════════════════════════════════════════════════════════════════

parent = self()

capture_upstream = fn body, _headers, _opts ->
  send(parent, {:buffered_upstream, body})
  {:ok, 200, %{"id" => "x", "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "buffered"}, "finish_reason" => "stop"}], "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}, "x_router" => %{"provider" => "stream-unit"}}}
end

disabled_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(%{"model" => "gpt", "messages" => [], "stream" => true}))
  |> put_req_header("authorization", "Bearer #{token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(Map.merge(base_opts, %{allow_streaming: false, upstream: capture_upstream})))

forwarded_stream_false? =
  receive do
    {:buffered_upstream, b} -> Map.get(b, "stream") == false
  after
    200 -> false
  end

check.(
  "disabled-by-default: allow_streaming:false + stream:true → buffered path forces stream:false",
  disabled_conn.status == 200 and forwarded_stream_false?
)

check.(
  "disabled-by-default: response is plain JSON (NOT text/event-stream — Port.open never reached)",
  Enum.any?(disabled_conn.resp_headers, fn {k, v} -> k == "content-type" and String.contains?(v, "application/json") end)
)

# ═══════════════════════════════════════════════════════════════════════════════
# REAL-HTTP integration — Bandit SSE stub (upstream) + REAL proxy listener
# ═══════════════════════════════════════════════════════════════════════════════

defmodule Genswarms.LlmProxy.StreamStubProbe do
  def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)
  def put(entry), do: Agent.update(__MODULE__, &[entry | &1])
  def all, do: Agent.get(__MODULE__, &Enum.reverse(&1))
  def last_for(model), do: all() |> Enum.filter(&(&1.model == model)) |> List.last()
end

defmodule Genswarms.LlmProxy.StreamStub do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts
  def frame(map), do: "data: " <> Jason.encode!(map) <> "\n\n"
  @done "data: [DONE]\n\n"

  def call(conn, _opts) do
    {:ok, raw, conn} = read_body(conn, length: 50_000_000)
    body = case Jason.decode(raw) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end

    model = Map.get(body, "model")
    auth = get_req_header(conn, "authorization") |> List.first()
    Genswarms.LlmProxy.StreamStubProbe.put(%{model: model, auth: auth, body: body})

    case model do
      "error500" ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{"error" => %{"message" => "boom upstream", "type" => "server_error", "code" => "server_error"}}))

      "mem-nonsse" ->
        # ~1.3MB of non-SSE, non-JSON content (undecided) — the proxy must abort
        # at the 256KB sniff cap before reading it all.
        conn = send_chunked(conn, 200)
        blk = String.duplicate("A", 64_000)
        stream_blocks(conn, blk, 20)

      "mem-sse" ->
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        big = String.duplicate("x", 32_000)
        frames = for _ <- 1..50, do: frame(%{"choices" => [%{"delta" => %{"content" => big}}]})
        frames = frames ++ [frame(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}], "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 9, "total_tokens" => 10}}), @done]
        stream_frames(conn, frames, 0)

      "crash-final" ->
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        frames = [
          frame(%{"choices" => [%{"delta" => %{"content" => "x"}}]}),
          frame(%{"usage" => "oops", "x_router" => %{"provider" => "stub"}}),
          @done
        ]
        stream_frames(conn, frames, 2)

      "disconnect" ->
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        frames = for _ <- 1..4000, do: frame(%{"choices" => [%{"delta" => %{"content" => "x"}}]})
        stream_frames(conn, frames, 1)

      "disconnect-write" ->
        # Reliably force a chunk-write {:error,_} on the PROXY side: stream LARGE frames with NO
        # inter-frame sleep so the proxy is continuously mid-Plug.Conn.chunk (and the OS send
        # buffer is overflowed) the instant the raw client closes. NO [DONE], no usage frame —
        # so this routes through the genuine write-error stream_disconnected path, NOT the
        # "stub finished + curl exited clean before the proxy noticed" truncation race.
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        big = String.duplicate("x", 8_000)
        frames = for _ <- 1..1500, do: frame(%{"choices" => [%{"delta" => %{"content" => big}}]})
        stream_frames(conn, frames, 0)

      # Task 8 accounting models ───────────────────────────────────────────────
      "split-usage" ->
        # usage in one event, cost (x_router) in a SEPARATE event → must still bill.
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

        frames = [
          frame(%{"choices" => [%{"delta" => %{"content" => "hi"}}]}),
          frame(%{"choices" => [], "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2, "total_tokens" => 3}}),
          frame(%{"choices" => [], "x_router" => %{"provider" => "stub", "cost_usd" => 0.10}}),
          @done
        ]

        stream_frames(conn, frames, 0)

      "standard-usage" ->
        # plain include_usage: usage frame, NO x_router (and the proxy's prices are unset)
        # → cost 0, unmetered.
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

        frames = [
          frame(%{"choices" => [%{"delta" => %{"content" => "hey"}}]}),
          frame(%{"choices" => [], "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 6, "total_tokens" => 10}}),
          @done
        ]

        stream_frames(conn, frames, 0)

      "session-acc-stream" ->
        # per-chunk x_router.cost_usd on the deltas + a FINAL x_router carrying session_acc
        # (cumulative) but NO cost_usd → bill the session_acc (0.05), not the per-chunk sum.
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

        frames = [
          frame(%{"choices" => [%{"delta" => %{"content" => "a"}}], "x_router" => %{"provider" => "stub", "cost_usd" => 0.01}}),
          frame(%{"choices" => [%{"delta" => %{"content" => "b"}}], "x_router" => %{"provider" => "stub", "cost_usd" => 0.01}}),
          frame(%{"choices" => [], "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 2, "total_tokens" => 4}, "x_router" => %{"provider" => "stub", "session_acc" => %{"cost_usd" => 0.05}}}),
          @done
        ]

        stream_frames(conn, frames, 0)

      "truncate" ->
        # content + final usage/cost frame but NO [DONE], then a clean close → curl exits 0
        # with the [DONE] sentinel absent → truncated.
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

        frames = [
          frame(%{"choices" => [%{"delta" => %{"content" => "tr"}}]}),
          frame(%{"choices" => [], "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}, "x_router" => %{"provider" => "stub", "cost_usd" => 0.10}})
        ]

        stream_frames(conn, frames, 0)

      "sse-500" ->
        # SSE-shaped body but a 500 status line → proxy commits a 200 stream, then
        # finish_stream sees the dumped 500 → status mismatch + recorded error, no cost.
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(500)

        frames = [
          frame(%{"choices" => [%{"delta" => %{"content" => "x"}}]}),
          frame(%{"error" => %{"message" => "boom", "type" => "server_error"}}),
          @done
        ]

        stream_frames(conn, frames, 0)

      "strip-usage" ->
        # one content delta + a usage-only chunk (choices:[]) carrying cost + [DONE].
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

        frames = [
          frame(%{"choices" => [%{"delta" => %{"content" => "hello"}}]}),
          frame(%{"choices" => [], "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}, "x_router" => %{"provider" => "stub", "cost_usd" => 0.07}}),
          @done
        ]

        stream_frames(conn, frames, 0)

      _ ->
        # "stream-hello" (default): two content deltas + final usage frame + [DONE]
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        frames = [
          frame(%{"choices" => [%{"delta" => %{"content" => "he"}}]}),
          frame(%{"choices" => [%{"delta" => %{"content" => "llo"}}]}),
          frame(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}], "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2, "total_tokens" => 3}, "x_router" => %{"provider" => "stub", "cost_usd" => 0.10}}),
          @done
        ]
        stream_frames(conn, frames, 2)
    end
  end

  defp stream_frames(conn, frames, sleep_ms) do
    Enum.reduce_while(frames, conn, fn f, c ->
      case chunk(c, f) do
        {:ok, c} -> if sleep_ms > 0, do: Process.sleep(sleep_ms); {:cont, c}
        {:error, _} -> {:halt, c}
      end
    end)
  end

  defp stream_blocks(conn, blk, n) do
    Enum.reduce_while(1..n, conn, fn _, c ->
      case chunk(c, blk) do
        {:ok, c} -> {:cont, c}
        {:error, _} -> {:halt, c}
      end
    end)
  end
end

{:ok, _probe} = Genswarms.LlmProxy.StreamStubProbe.start_link()

stub_port = 25_733
proxy_port = 25_730

{:ok, stub_pid} = Bandit.start_link(plug: Genswarms.LlmProxy.StreamStub, scheme: :http, ip: {127, 0, 0, 1}, port: stub_port)
stub_endpoint = "http://127.0.0.1:#{stub_port}/v1/chat/completions"

proxy_opts =
  Map.merge(base_opts, %{
    upstream_endpoint: stub_endpoint,
    stream_timeout_s: 25,
    connect_timeout_s: 5
  })

{:ok, proxy_pid} = Bandit.start_link(plug: {ProxyPlug, proxy_opts}, scheme: :http, ip: {127, 0, 0, 1}, port: proxy_port)
proxy_endpoint = "http://127.0.0.1:#{proxy_port}/v1/chat/completions"
proxy_healthz = "http://127.0.0.1:#{proxy_port}/healthz"

# curl client → proxy; returns the full `-i` response (status line + headers + body).
client_post = fn body_map ->
  {out, _code} =
    System.cmd(
      "curl",
      ["-sS", "-N", "-i", "-H", "Authorization: Bearer #{token}", "-H", "Content-Type: application/json",
       "--data-binary", Jason.encode!(body_map), "--max-time", "25", proxy_endpoint],
      stderr_to_stdout: false
    )

  out
end

extract_contents = fn body ->
  Regex.scan(~r/"content":"([^"]*)"/, body) |> Enum.map(fn [_, c] -> c end) |> Enum.join()
end

# ── Happy path ────────────────────────────────────────────────────────────────
hello_out = client_post.(%{"model" => "stream-hello", "messages" => [%{"role" => "user", "content" => "hi"}], "stream" => true})

check.(
  "stream happy path: 200 text/event-stream, deltas concat to \"hello\", [DONE] present",
  String.contains?(hello_out, "HTTP/1.1 200") and
    String.contains?(String.downcase(hello_out), "content-type: text/event-stream") and
    extract_contents.(hello_out) == "hello" and
    String.contains?(hello_out, "[DONE]")
)

check.(
  "stream happy path: llm_proxy_stream + llm_proxy_requests metrics bumped",
  Agent.get(metrics_agent, & &1) |> then(fn m -> "llm_proxy_stream" in m and "llm_proxy_requests" in m end)
)

# ── Credential isolation ──────────────────────────────────────────────────────
hello2_out = client_post.(%{"model" => "stream-hello", "messages" => [], "stream" => true})
cap = Genswarms.LlmProxy.StreamStubProbe.last_for("stream-hello")

check.(
  "credential isolation: upstream stub saw 'Authorization: Bearer real-upstream-key-SENTINEL' (NOT the session token)",
  cap != nil and cap.auth == "Bearer #{test_key}" and cap.auth != "Bearer #{token}"
)

check.(
  "credential isolation: the full client SSE bytes NEVER contain the upstream key sentinel",
  not String.contains?(hello2_out, test_key)
)

check.(
  "credential isolation: forwarded body carries the unhardcoded session id (in the body file, not argv)",
  is_map(cap.body) and is_binary(Map.get(cap.body, "session")) and Map.get(cap.body, "stream") == true
)

# ── Non-SSE error 500 → buffered path, status preserved ───────────────────────
err_out = client_post.(%{"model" => "error500", "messages" => [], "stream" => true})

check.(
  "non-SSE upstream 500: proxy buffers + returns JSON 500 (dump_header_status drives the status)",
  String.contains?(err_out, "HTTP/1.1 500") and
    String.contains?(String.downcase(err_out), "content-type: application/json") and
    String.contains?(err_out, "server_error")
)

# ── Memory bound: large SSE completes; non-SSE undecided aborts at 256KB cap ──
mem_out = client_post.(%{"model" => "mem-sse", "messages" => [], "stream" => true})

check.(
  "memory bound (SSE): ~1.6MB stream completes 200 + [DONE]; acc bounded (see bounded_tail units + source)",
  String.contains?(mem_out, "HTTP/1.1 200") and byte_size(mem_out) > 1_000_000 and String.contains?(mem_out, "[DONE]")
)

Agent.update(metrics_agent, fn _ -> [] end)
nonsse_out = client_post.(%{"model" => "mem-nonsse", "messages" => [], "stream" => true})

check.(
  "memory bound (non-SSE undecided): aborts at the 256KB cap → 502 upstream_invalid + llm_proxy_upstream_error",
  String.contains?(nonsse_out, "HTTP/1.1 502") and
    String.contains?(nonsse_out, "upstream_invalid") and
    "llm_proxy_upstream_error" in Agent.get(metrics_agent, & &1)
)

# ── Crash safety: hostile final usage frame must NOT crash the stream ─────────
crash_out = client_post.(%{"model" => "crash-final", "messages" => [], "stream" => true})
crash_healthz = (System.cmd("curl", ["-sS", "-i", "--max-time", "5", proxy_healthz]) |> elem(0))
crash_recover = client_post.(%{"model" => "stream-hello", "messages" => [], "stream" => true})

check.(
  "crash safety: hostile usage:\"oops\" final frame → complete 200 event-stream, no crash",
  String.contains?(crash_out, "HTTP/1.1 200") and
    String.contains?(String.downcase(crash_out), "content-type: text/event-stream") and
    String.contains?(crash_out, "[DONE]")
)

check.(
  "crash safety: /healthz still 200 and a fresh stream still serves \"hello\" afterwards",
  String.contains?(crash_healthz, "HTTP/1.1 200") and extract_contents.(crash_recover) == "hello"
)

# ── Disconnect: raw client reads one chunk, closes → fast teardown (~2s, not 75s) ──
disconnect_started = System.monotonic_time(:millisecond)

{:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", proxy_port, [:binary, active: false, packet: :raw])
dbody = Jason.encode!(%{"model" => "disconnect", "messages" => [], "stream" => true})

dreq =
  "POST /v1/chat/completions HTTP/1.1\r\n" <>
    "Host: 127.0.0.1\r\n" <>
    "Authorization: Bearer #{token}\r\n" <>
    "Content-Type: application/json\r\n" <>
    "Content-Length: #{byte_size(dbody)}\r\n" <>
    "Connection: close\r\n\r\n" <> dbody

:ok = :gen_tcp.send(sock, dreq)
{:ok, _first_chunk} = :gen_tcp.recv(sock, 0, 5000)
:gen_tcp.close(sock)

curl_gone? = fn ->
  {out, _} = System.cmd("pgrep", ["-f", "#{stub_port}/v1/chat"], stderr_to_stdout: false)
  String.trim(out) == ""
end

torn_down? = wait_until.(fn -> Path.wildcard(proxy_glob) == [] and curl_gone?.() end, 2_000)
disconnect_elapsed = System.monotonic_time(:millisecond) - disconnect_started

check.(
  "disconnect: tmp temp files cleared AND the upstream curl OS process is gone within ~2s (NOT ~75s)",
  torn_down? and disconnect_elapsed < 2_000
)

# Listener survived the disconnect: fresh healthz + fresh stream still work.
disc_healthz = (System.cmd("curl", ["-sS", "-i", "--max-time", "5", proxy_healthz]) |> elem(0))
disc_recover = client_post.(%{"model" => "stream-hello", "messages" => [], "stream" => true})

check.(
  "disconnect: proxy listener survives — fresh /healthz 200 and a fresh stream still serves \"hello\"",
  String.contains?(disc_healthz, "HTTP/1.1 200") and extract_contents.(disc_recover) == "hello"
)

# ═══════════════════════════════════════════════════════════════════════════════
# Task 8 — PART A.4: strip_usage? / strip_usage_frames (pure)
# ═══════════════════════════════════════════════════════════════════════════════

check.(
  "strip_usage?: no stream_options OR include_usage:false → true; include_usage true/\"true\"/1 → false",
  ProxyPlug.strip_usage?(%{"model" => "m"}) and
    ProxyPlug.strip_usage?(%{"stream_options" => %{"include_usage" => false}}) and
    ProxyPlug.strip_usage?(%{"stream_options" => %{}}) and
    not ProxyPlug.strip_usage?(%{"stream_options" => %{"include_usage" => true}}) and
    not ProxyPlug.strip_usage?(%{"stream_options" => %{"include_usage" => "true"}}) and
    not ProxyPlug.strip_usage?(%{"stream_options" => %{"include_usage" => 1}})
)

# Drops the usage-only frame, keeps the rest byte-for-byte (delimiters preserved).
{strip_fwd, strip_rem} =
  ProxyPlug.strip_usage_frames(
    "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n" <>
      "data: {\"choices\":[],\"usage\":{\"total_tokens\":3}}\n\n" <>
      "data: [DONE]\n\n"
  )

check.(
  "strip_usage_frames: drops the choices:[] usage frame, keeps content + [DONE] verbatim, no remainder",
  strip_fwd == "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n" and
    strip_rem == ""
)

{kept_fwd, _} =
  ProxyPlug.strip_usage_frames("data: {\"choices\":[{\"delta\":{}}]}\n\ndata: [DONE]\n\n")

check.(
  "strip_usage_frames: a stream with NO usage-only frame is forwarded byte-identical",
  kept_fwd == "data: {\"choices\":[{\"delta\":{}}]}\n\ndata: [DONE]\n\n"
)

{partial_fwd, partial_rem} =
  ProxyPlug.strip_usage_frames("data: {\"choices\":[{\"a\":1}]}\n\ndata: {\"choices\":[")

check.(
  "strip_usage_frames: a trailing partial frame is held in the remainder (forwarded once complete)",
  partial_fwd == "data: {\"choices\":[{\"a\":1}]}\n\n" and partial_rem == "data: {\"choices\":["
)

# ═══════════════════════════════════════════════════════════════════════════════
# Task 8 — PART A: streaming accounting (recording store + 2nd REAL proxy listener)
# ═══════════════════════════════════════════════════════════════════════════════

defmodule Genswarms.LlmProxy.StreamRecStore do
  @name __MODULE__

  def start_link, do: Agent.start_link(fn -> %{daily: %{}, events: []} end, name: @name)
  def reset, do: Agent.update(@name, fn _ -> %{daily: %{}, events: []} end)

  def seed(identity, day, spent, limit) do
    Agent.update(@name, fn st ->
      put_in(st, [:daily, {identity, day}], %{spent_usd: dec(spent), limit_usd: dec(limit), requests: 0})
    end)
  end

  def llm_budget_status(identity, day, _session_id, default_limit) do
    Agent.get(@name, fn st ->
      Map.get(st.daily, {identity, day}) || %{spent_usd: Decimal.new("0"), limit_usd: dec(default_limit)}
    end)
  end

  def record_llm_call(identity, day, _session_id, attrs) do
    Agent.update(@name, fn st ->
      key = {identity, day}
      cost = dec(attrs[:cost_usd] || "0")
      row = Map.get(st.daily, key) || %{spent_usd: Decimal.new("0"), limit_usd: Decimal.new("100"), requests: 0}
      row = %{row | spent_usd: Decimal.add(row.spent_usd, cost), requests: row.requests + 1}
      ev = %{status: attrs[:status], model: attrs[:model], cost_usd: cost, total_tokens: attrs[:total_tokens], provider: attrs[:provider]}
      %{st | daily: Map.put(st.daily, key, row), events: [ev | st.events]}
    end)

    %{}
  end

  def usage(identity, day), do: Agent.get(@name, &Map.get(&1.daily, {identity, day}))
  def events, do: Agent.get(@name, &Enum.reverse(&1.events))

  defp dec(%Decimal{} = v), do: v
  defp dec(v), do: Decimal.new(to_string(v))
end

{:ok, _rec_store} = Genswarms.LlmProxy.StreamRecStore.start_link()

acct_day = ~D[2026-06-25]
acct_attrs = %{conversation_id: "tg:acct:0", slot: :acct_agent, kind: :dm, workspace_key: "acctws"}
acct_identity = Proxy.budget_identity(acct_attrs)
{:ok, acct_token} = Proxy.register_session(state_pid, acct_attrs)

rec_proxy_port = 25_731

rec_opts =
  Map.merge(base_opts, %{
    upstream_endpoint: stub_endpoint,
    store_mod: Genswarms.LlmProxy.StreamRecStore,
    stream_timeout_s: 25,
    connect_timeout_s: 5
  })

{:ok, rec_proxy_pid} =
  Bandit.start_link(plug: {ProxyPlug, rec_opts}, scheme: :http, ip: {127, 0, 0, 1}, port: rec_proxy_port)

rec_endpoint = "http://127.0.0.1:#{rec_proxy_port}/v1/chat/completions"

rec_post = fn body_map ->
  {out, _code} =
    System.cmd(
      "curl",
      ["-sS", "-N", "-i", "-H", "Authorization: Bearer #{acct_token}", "-H", "Content-Type: application/json",
       "--data-binary", Jason.encode!(body_map), "--max-time", "25", rec_endpoint],
      stderr_to_stdout: false
    )

  out
end

wait_events = fn n -> wait_until.(fn -> length(Genswarms.LlmProxy.StreamRecStore.events()) >= n end, 3_000) end
metric_seen? = fn key -> wait_until.(fn -> key in Agent.get(metrics_agent, & &1) end, 3_000) end

# ── Happy accounting: final usage+x_router event → 1 row, cost 0.10, spent 0.10 ──
Genswarms.LlmProxy.StreamRecStore.reset()
Agent.update(metrics_agent, fn _ -> [] end)
_ = rec_post.(%{"model" => "stream-hello", "messages" => [], "stream" => true})
_ = wait_events.(1)
acct_usage = Genswarms.LlmProxy.StreamRecStore.usage(acct_identity, acct_day)
acct_events = Genswarms.LlmProxy.StreamRecStore.events()

check.(
  "stream accounting: final usage+x_router → 1 row cost 0.10, spent_usd 0.10, status ok, NOT unmetered",
  length(acct_events) == 1 and hd(acct_events).status == "ok" and
    Decimal.equal?(hd(acct_events).cost_usd, Decimal.new("0.10")) and
    acct_usage != nil and Decimal.equal?(acct_usage.spent_usd, Decimal.new("0.10")) and
    not ("llm_proxy_stream_unmetered" in Agent.get(metrics_agent, & &1))
)

# ── SPLIT usage/cost across two events → cost still 0.10 ──
Genswarms.LlmProxy.StreamRecStore.reset()
_ = rec_post.(%{"model" => "split-usage", "messages" => [], "stream" => true})
_ = wait_events.(1)

check.(
  "stream accounting: usage and cost SPLIT across two events → cost still 0.10 (resolved independently)",
  Decimal.equal?(Genswarms.LlmProxy.StreamRecStore.usage(acct_identity, acct_day).spent_usd, Decimal.new("0.10"))
)

check.(
  "stream accounting: x_router.provider is carried into the persisted record (migration 017 parity with the buffered path)",
  match?([%{provider: "stub"}], Genswarms.LlmProxy.StreamRecStore.events())
)

# ── STANDARD include_usage (usage, no x_router, prices unset) → cost 0 + unmetered ──
Genswarms.LlmProxy.StreamRecStore.reset()
Agent.update(metrics_agent, fn _ -> [] end)
_ = rec_post.(%{"model" => "standard-usage", "messages" => [], "stream" => true})
_ = wait_events.(1)

check.(
  "stream accounting: standard include_usage (no x_router, prices unset) → cost 0 + llm_proxy_stream_unmetered + row written",
  Decimal.equal?(Genswarms.LlmProxy.StreamRecStore.usage(acct_identity, acct_day).spent_usd, Decimal.new("0")) and
    metric_seen?.("llm_proxy_stream_unmetered") and
    length(Genswarms.LlmProxy.StreamRecStore.events()) == 1
)

# ── per-chunk cost + final session_acc → record the session_acc, not the per-chunk sum ──
Genswarms.LlmProxy.StreamRecStore.reset()
_ = rec_post.(%{"model" => "session-acc-stream", "messages" => [], "stream" => true})
_ = wait_events.(1)

check.(
  "stream accounting: final session_acc.cost_usd recorded (0.05), NOT the per-chunk costs (0.02)",
  length(Genswarms.LlmProxy.StreamRecStore.events()) == 1 and
    Decimal.equal?(Genswarms.LlmProxy.StreamRecStore.usage(acct_identity, acct_day).spent_usd, Decimal.new("0.05"))
)

# ── truncation (clean EOF, no [DONE]) → llm_proxy_stream_truncated + row STILL written ──
Genswarms.LlmProxy.StreamRecStore.reset()
Agent.update(metrics_agent, fn _ -> [] end)
_ = rec_post.(%{"model" => "truncate", "messages" => [], "stream" => true})
trunc_ok = metric_seen?.("llm_proxy_stream_truncated")
_ = wait_events.(1)

check.(
  "stream accounting: truncated stream (no [DONE]) → llm_proxy_stream_truncated + row written + cost 0.10 billed",
  trunc_ok and length(Genswarms.LlmProxy.StreamRecStore.events()) == 1 and
    Decimal.equal?(Genswarms.LlmProxy.StreamRecStore.usage(acct_identity, acct_day).spent_usd, Decimal.new("0.10"))
)

# ── SSE-shaped non-2xx (500) → llm_proxy_stream_status_mismatch + recorded error, no cost ──
Genswarms.LlmProxy.StreamRecStore.reset()
Agent.update(metrics_agent, fn _ -> [] end)
_ = rec_post.(%{"model" => "sse-500", "messages" => [], "stream" => true})
mismatch_ok = metric_seen?.("llm_proxy_stream_status_mismatch")
_ = wait_events.(1)
sse500_events = Genswarms.LlmProxy.StreamRecStore.events()

check.(
  "stream accounting: SSE-shaped 500 → llm_proxy_stream_status_mismatch + recorded status upstream_500, no positive cost",
  mismatch_ok and length(sse500_events) == 1 and hd(sse500_events).status == "upstream_500" and
    Decimal.equal?(Genswarms.LlmProxy.StreamRecStore.usage(acct_identity, acct_day).spent_usd, Decimal.new("0"))
)

# ── disconnect before usage → a row STILL written + llm_proxy_stream_disconnected ──
Genswarms.LlmProxy.StreamRecStore.reset()
Agent.update(metrics_agent, fn _ -> [] end)

{:ok, dsock} = :gen_tcp.connect(~c"127.0.0.1", rec_proxy_port, [:binary, active: false, packet: :raw])
ddbody = Jason.encode!(%{"model" => "disconnect", "messages" => [], "stream" => true})

dreq2 =
  "POST /v1/chat/completions HTTP/1.1\r\n" <>
    "Host: 127.0.0.1\r\n" <>
    "Authorization: Bearer #{acct_token}\r\n" <>
    "Content-Type: application/json\r\n" <>
    "Content-Length: #{byte_size(ddbody)}\r\n" <>
    "Connection: close\r\n\r\n" <> ddbody

:ok = :gen_tcp.send(dsock, dreq2)
{:ok, _} = :gen_tcp.recv(dsock, 0, 5000)
:gen_tcp.close(dsock)

disc_acct_ok = metric_seen?.("llm_proxy_stream_disconnected")
_ = wait_events.(1)
disc_events = Genswarms.LlmProxy.StreamRecStore.events()

check.(
  "stream accounting: client disconnect before usage → row STILL written (status ok, cost 0) + llm_proxy_stream_disconnected",
  disc_acct_ok and length(disc_events) == 1 and hd(disc_events).status == "ok" and
    Decimal.equal?(Genswarms.LlmProxy.StreamRecStore.usage(acct_identity, acct_day).spent_usd, Decimal.new("0"))
)

# ── Item 1: aborted (>256KB non-SSE) stream writes NO budget row + sends exactly ONE 502 ──
# stream_abort now sets a DISTINCT :aborted terminal (not :done), so finish_stream does NO
# accounting after the 502 — no phantom $0 "ok" row, no spurious stream_disconnected /
# stream_status_mismatch. Driven through the RECORDING store so a phantom row is observable.
Genswarms.LlmProxy.StreamRecStore.reset()
Agent.update(metrics_agent, fn _ -> [] end)
nonsse_acct_out = rec_post.(%{"model" => "mem-nonsse", "messages" => [], "stream" => true})
abort_err_seen = metric_seen?.("llm_proxy_upstream_error")
# Give any (erroneous) accounting a chance to land before asserting the row count is zero.
Process.sleep(150)
nonsse_metrics = Agent.get(metrics_agent, & &1)

check.(
  "item1: aborted non-SSE stream → ONE 502 upstream_invalid + llm_proxy_upstream_error, and NO budget row, NO stream_disconnected/stream_status_mismatch (no phantom accounting)",
  String.contains?(nonsse_acct_out, "HTTP/1.1 502") and
    String.contains?(nonsse_acct_out, "upstream_invalid") and
    abort_err_seen and
    length(Genswarms.LlmProxy.StreamRecStore.events()) == 0 and
    not ("llm_proxy_stream_disconnected" in nonsse_metrics) and
    not ("llm_proxy_stream_status_mismatch" in nonsse_metrics)
)

# ── Item 19: forced mid-write disconnect → genuine stream_disconnected (NOT truncated) + row ──
# A stub that streams large frames continuously (no sleep) so the proxy is mid-Plug.Conn.chunk
# when the raw client closes → the chunk write returns {:error,_} → the real disconnect path.
Genswarms.LlmProxy.StreamRecStore.reset()
Agent.update(metrics_agent, fn _ -> [] end)

{:ok, dwsock} = :gen_tcp.connect(~c"127.0.0.1", rec_proxy_port, [:binary, active: false, packet: :raw])
dwbody = Jason.encode!(%{"model" => "disconnect-write", "messages" => [], "stream" => true})

dwreq =
  "POST /v1/chat/completions HTTP/1.1\r\n" <>
    "Host: 127.0.0.1\r\n" <>
    "Authorization: Bearer #{acct_token}\r\n" <>
    "Content-Type: application/json\r\n" <>
    "Content-Length: #{byte_size(dwbody)}\r\n" <>
    "Connection: close\r\n\r\n" <> dwbody

:ok = :gen_tcp.send(dwsock, dwreq)
# Read one chunk so the stream is committed + actively flowing, then vanish.
{:ok, _} = :gen_tcp.recv(dwsock, 0, 5000)
:gen_tcp.close(dwsock)

dw_disc = metric_seen?.("llm_proxy_stream_disconnected")
_ = wait_events.(1)
dw_events = Genswarms.LlmProxy.StreamRecStore.events()
dw_not_trunc = not ("llm_proxy_stream_truncated" in Agent.get(metrics_agent, & &1))

check.(
  "item19: forced mid-write client close → llm_proxy_stream_disconnected (NOT stream_truncated) + a budget row still written (status ok)",
  dw_disc and dw_not_trunc and length(dw_events) == 1 and hd(dw_events).status == "ok"
)

# ── include_usage strip: no stream_options → usage-only chunk STRIPPED from client ──
Genswarms.LlmProxy.StreamRecStore.reset()
strip_out = rec_post.(%{"model" => "strip-usage", "messages" => [], "stream" => true})
_ = wait_events.(1)

check.(
  "include_usage strip: original has NO stream_options → injected usage-only chunk STRIPPED (no \"choices\":[]), content+[DONE] intact, cost 0.07 still billed",
  String.contains?(strip_out, "HTTP/1.1 200") and
    extract_contents.(strip_out) == "hello" and
    String.contains?(strip_out, "[DONE]") and
    not String.contains?(strip_out, "\"choices\":[]") and
    Decimal.equal?(Genswarms.LlmProxy.StreamRecStore.usage(acct_identity, acct_day).spent_usd, Decimal.new("0.07"))
)

# ── include_usage passthrough: explicit include_usage:true → client DOES get the chunk ──
Genswarms.LlmProxy.StreamRecStore.reset()
nostrip_out = rec_post.(%{"model" => "strip-usage", "messages" => [], "stream" => true, "stream_options" => %{"include_usage" => true}})
_ = wait_events.(1)

check.(
  "include_usage passthrough: explicit include_usage:true → client receives the usage-only chunk (\"choices\":[]) verbatim; cost 0.07 still billed",
  String.contains?(nostrip_out, "HTTP/1.1 200") and
    String.contains?(nostrip_out, "\"choices\":[]") and
    String.contains?(nostrip_out, "[DONE]") and
    Decimal.equal?(Genswarms.LlmProxy.StreamRecStore.usage(acct_identity, acct_day).spent_usd, Decimal.new("0.07"))
)

# ── Budget-exhausted STREAMING (A3) — driven via Plug.Test (synthetic, no upstream) ──
# A raising :port_open proves the upstream is NEVER reached: a routing bug that fell
# through to stream_upstream would raise → 502, not the budget SSE body.
ex_attrs = %{conversation_id: "tg:exh:0", slot: :exh_agent, kind: :dm, workspace_key: "exhws"}
ex_identity = Proxy.budget_identity(ex_attrs)
{:ok, ex_token} = Proxy.register_session(state_pid, ex_attrs)

Genswarms.LlmProxy.StreamRecStore.reset()
Genswarms.LlmProxy.StreamRecStore.seed(ex_identity, acct_day, "100", "100")

{:ok, ex_slot} = Agent.start_link(fn -> [] end)

ex_deliver = fn _sw, _to, :llm_proxy, content ->
  case Jason.decode(content) do
    {:ok, %{"action" => "slot_reply"} = m} -> Agent.update(ex_slot, &[m | &1])
    _ -> :ok
  end

  :ok
end

ex_opts =
  Map.merge(base_opts, %{
    store_mod: Genswarms.LlmProxy.StreamRecStore,
    deliver_fn: ex_deliver,
    allow_streaming: true,
    port_open: fn _bin, _args -> raise "upstream must NOT be reached when budget exhausted" end
  })

ex_conn1 =
  conn(:post, "/v1/chat/completions", Jason.encode!(%{"model" => "x", "messages" => [], "stream" => true}))
  |> put_req_header("authorization", "Bearer #{ex_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(ex_opts))

# Second identical request → dedup means NO second slot_reply.
ex_conn2 =
  conn(:post, "/v1/chat/completions", Jason.encode!(%{"model" => "x", "messages" => [], "stream" => true}))
  |> put_req_header("authorization", "Bearer #{ex_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(ex_opts))

ex_body = ex_conn1.resp_body
ex_ctype = Enum.any?(ex_conn1.resp_headers, fn {k, v} -> k == "content-type" and String.contains?(v, "text/event-stream") end)

check.(
  "budget-exhausted streaming: 200 text/event-stream, one chat.completion.chunk model llm-proxy-budget + [DONE], upstream NOT hit, exactly one slot_reply (dedup)",
  ex_conn1.status == 200 and ex_conn2.status == 200 and ex_ctype and
    String.contains?(ex_body, "chat.completion.chunk") and
    String.contains?(ex_body, "llm-proxy-budget") and
    String.contains?(ex_body, "[DONE]") and
    length(Agent.get(ex_slot, & &1)) == 1
)

# ── L7 — receive-timeout while still sniffing (conn never committed) → 502, no ──
# ── phantom usage row — driven via Plug.Test (synthetic, no upstream) ───────────
# `port_open` returns a bare reference: nothing ever sends `{^port, ...}`, so
# stream_loop can only ever reach its `after` arm. `stream_timeout_s` is negative
# so the wait — `(stream_timeout_s + 15) * 1000` — is ~2s, not the real ~315s. With
# zero bytes ever received, mode stays :sniff the whole time (conn never
# send_chunked'd), which is exactly the "conn never committed" timeout case.
l7_attrs = %{conversation_id: "tg:l7:0", slot: :l7_agent, kind: :dm, workspace_key: "l7ws"}
l7_identity = Proxy.budget_identity(l7_attrs)
{:ok, l7_token} = Proxy.register_session(state_pid, l7_attrs)

Genswarms.LlmProxy.StreamRecStore.reset()

l7_opts =
  Map.merge(base_opts, %{
    store_mod: Genswarms.LlmProxy.StreamRecStore,
    stream_timeout_s: -13,
    port_open: fn _bin, _args -> make_ref() end
  })

l7_conn =
  conn(:post, "/v1/chat/completions", Jason.encode!(%{"model" => "x", "messages" => [], "stream" => true}))
  |> put_req_header("authorization", "Bearer #{l7_token}")
  |> put_req_header("content-type", "application/json")
  |> ProxyPlug.call(ProxyPlug.init(l7_opts))

l7_usage = Genswarms.LlmProxy.StreamRecStore.usage(l7_identity, acct_day)

check.(
  "L7: receive-timeout while still sniffing (conn never committed) → 502 sent (not an unset conn), zero usage rows recorded",
  l7_conn.status == 502 and Genswarms.LlmProxy.StreamRecStore.events() == [] and
    (is_nil(l7_usage) or l7_usage.requests == 0)
)

# ─────────────────────────────────────────────────────────────────────────────
GenServer.stop(rec_proxy_pid)
GenServer.stop(proxy_pid)
GenServer.stop(stub_pid)

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_STREAM: ALL PASS")
else
  IO.puts("LLM_PROXY_STREAM: FAILED — #{length(failed)} check(s)")
  Enum.each(Enum.reverse(failed), &IO.puts("  - #{&1}"))
  System.halt(1)
end
