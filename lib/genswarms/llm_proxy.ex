defmodule Genswarms.LlmProxy.Secret do
  @moduledoc false
  # Opaque wrapper for the upstream API key so accidental inspection
  # (SASL crash reports, :sys.get_state, IO.inspect of plug_opts / conn.private)
  # cannot dump the real key into the host logs. Unwrap explicitly via reveal/1
  # ONLY where the key is actually used (curl auth / log scrub).
  #
  # WHY a closure instead of a `defimpl Inspect`: wingston objects are loaded at
  # runtime via `Code.require_file` (run_live.exs), AFTER the Inspect protocol is
  # consolidated. A `defimpl Inspect` loaded post-consolidation is IGNORED by the
  # consolidated dispatch (Elixir even warns "has no effect"), so the struct would
  # fall back to the default inspect and leak the value. Storing the secret behind
  # a zero-arity closure makes redaction structural and consolidation-independent:
  # the default struct inspect renders the field as `#Function<...>` — Erlang/Elixir
  # never print a fun's captured environment via `inspect`/SASL — so the key is
  # never shown regardless of protocol consolidation.
  #
  # NO String.Chars impl is provided on purpose: a stray "#{secret}" interpolation
  # must fail loudly (Protocol.UndefinedError), never silently leak.
  @enforce_keys [:value]
  defstruct [:value]

  # wrap/1: idempotent; binary -> closure-backed Secret; nil passes through.
  def wrap(%__MODULE__{} = s), do: s
  def wrap(value) when is_binary(value), do: %__MODULE__{value: fn -> value end}
  def wrap(nil), do: nil

  # reveal/1: tolerant — a %Secret{} (production), a raw binary (the ~80 existing
  # tests build opts with a bare string), or nil all unwrap to the underlying value.
  def reveal(%__MODULE__{value: f}) when is_function(f, 0), do: f.()
  def reveal(v) when is_binary(v), do: v
  def reveal(nil), do: nil
end

defmodule Genswarms.LlmProxy do
  @moduledoc """
  Deterministic host-owned LLM proxy and usage accountant.

  Sandboxed agents receive only a loopback OpenAI-compatible endpoint and an
  opaque bearer token. This object maps that token to trusted host identity and
  forwards requests with host-held upstream credentials.

  Extracted from the wingston-rally-bot proxy (itself ported from micro-markets —
  the two ~90%-overlapping implementations this package unifies). Design points:
    * durable accounting is injected via `store_mod` (see `Genswarms.LlmProxy.Store`);
      without one the proxy runs on its in-memory mirror alone (fine for dev, resets
      on restart);
    * upstream call shells out to curl (a bare orchestrator OTP build may have no
      usable `:httpc`, see `Genswarms.LlmProxy.Curl`), keeping the API key +
      identity OUT of argv;
    * in-memory usage mirror is pruned on day-rollover so it can't grow unbounded;
    * Bandit start tolerates `:eaddrinuse`/`:already_started` (log-and-continue);
    * `dm_module` (optional, exports `dm?/1`) classifies a conversation id as
      DM vs group for per-kind budgets — absent, unlabeled sessions are "group".

  Implements the `Genswarms.Objects.ObjectHandler` callbacks by convention (no
  `@behaviour`): genswarms is a peer/runtime dependency, the library compiles
  without the engine (same pattern as genswarms-telegram / genswarms-dashboard).
  """

  require Logger

  @state_name __MODULE__.State
  @bandit_name __MODULE__.Bandit
  @default_port 4318
  @default_daily_limit "0.50"

  @doc false
  def rate_card_complete?(prices) when is_map(prices) do
    rate_card_price?(Map.get(prices, :prompt_per_mtok) || Map.get(prices, "prompt_per_mtok")) and
      rate_card_price?(
        Map.get(prices, :completion_per_mtok) || Map.get(prices, "completion_per_mtok")
      )
  end

  def rate_card_complete?(_), do: false

  @doc false
  def validate_pricing_config!(mode, prices, margin_pct \\ 0)

  def validate_pricing_config!(:cost_plus, prices, margin_pct) do
    cond do
      not rate_card_complete?(prices) ->
        raise ArgumentError,
              "pricing_mode :cost_plus requires a complete non-negative prompt/completion " <>
                "rate card so zero, missing, or invalid provider cost has a fallback"

      not rate_card_price?(margin_pct) ->
        raise ArgumentError,
              "pricing_mode :cost_plus requires a finite non-negative margin_pct"

      true ->
        :ok
    end
  end

  def validate_pricing_config!(_mode, _prices, _margin_pct), do: :ok

  defp rate_card_price?(value) do
    case strict_decimal(value) do
      %Decimal{} = decimal ->
        finite_decimal?(decimal) and Decimal.compare(decimal, Decimal.new(0)) != :lt

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp strict_decimal(%Decimal{} = value), do: value
  defp strict_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp strict_decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp strict_decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp strict_decimal(_), do: nil

  # Shipped health_rules (v1 structured grammar — see the observability plan) for the
  # operator-wide daily spend ceiling. Wire contract for the observer's generic rule
  # evaluator: KEEP byte-identical to the plan's Task 2 Interfaces block. Both rules'
  # "where" has NO "each" — they evaluate against the "llm_proxy_budget" block itself
  # (block-relative paths), guarding on ceiling_usd > 0 so a disabled ceiling
  # (0 = disabled) never false-alarms.
  @health_rules [
    %{
      "id" => "budget_guard_75",
      "severity" => "info",
      "card" => "LLM spend at 75% of the daily ceiling",
      "where" => %{"op" => "gt", "lhs" => %{"path" => "ceiling_usd"}, "rhs" => 0},
      "when" => %{
        "op" => "gte",
        "lhs" => %{"div" => [%{"path" => "spent_usd"}, %{"path" => "ceiling_usd"}]},
        "rhs" => 0.75
      }
    },
    %{
      "id" => "budget_guard_90",
      "severity" => "warn",
      "card" => "LLM spend at 90% of the daily ceiling — agents hard-block at 100%",
      "where" => %{"op" => "gt", "lhs" => %{"path" => "ceiling_usd"}, "rhs" => 0},
      "when" => %{
        "op" => "gte",
        "lhs" => %{"div" => [%{"path" => "spent_usd"}, %{"path" => "ceiling_usd"}]},
        "rhs" => 0.90
      }
    }
  ]

  def init(config) do
    port = Map.get(config, :port, @default_port)
    prices = Map.get(config, :prices, %{})
    margin_pct = Map.get(config, :margin_pct, 0)
    pricing_mode = pricing_mode(Map.get(config, :pricing_mode))
    :ok = validate_pricing_config!(pricing_mode, prices, margin_pct)

    # A concurrent double-boot (or a leftover registered Agent) must NOT crash the object
    # at boot — mirror the Bandit listener guard below: accept an already-started state
    # Agent and log-and-continue rather than MatchError on `{:ok, _} = ...`.
    state_pid =
      case start_state_link(name: @state_name) do
        {:ok, pid} ->
          pid

        {:error, {:already_started, pid}} ->
          Logger.info("llm_proxy: state Agent already started (#{inspect(pid)})")
          pid
      end

    plug_opts = %{
      state_pid: state_pid,
      upstream_endpoint: Map.fetch!(config, :upstream_endpoint),
      upstream_api_key: Genswarms.LlmProxy.Secret.wrap(Map.fetch!(config, :upstream_api_key)),
      provider: Map.get(config, :provider, "openai-compatible"),
      prices: prices,
      margin_pct: margin_pct,
      # :cost_plus (default; :provider_first remains a compatibility alias) |
      # :rate_card_first (the user charge is the operator-SET price even when
      # the upstream call was free; the router's own cost is recorded
      # separately as provider_cost_usd).
      pricing_mode: pricing_mode,
      pricing_version:
        Map.get(config, :pricing_version) ||
          if(pricing_mode == :cost_plus, do: "cost_plus_v1", else: "rate_card_v1"),
      store_mod: module_ref(Map.get(config, :store_mod)),
      default_daily_limit: decimal(Map.get(config, :default_daily_limit, @default_daily_limit)),
      # Operator-wide daily USD ceiling across ALL conversations (0 = disabled). Per-conversation
      # budgets don't bound aggregate spend, so N Sybil conversations = N × the per-conv cap with no
      # cap — this is the global cost-DoS backstop. Enforced via max(PG-SUM, in-memory) so it still
      # holds when Postgres is down (the per-conversation budget fails open on a PG outage).
      global_daily_limit: decimal(Map.get(config, :global_daily_limit, 0)),
      # Per-budget-identity daily operation quota. This is separate from dollar spend
      # and blocks before upstream once reached. 0 = disabled for dev/tests unless
      # the app config opts in.
      daily_request_limit: request_limit(Map.get(config, :daily_request_limit, 0)),
      swarm_name: Map.get(config, :swarm_name, "swarm"),
      sender: Map.get(config, :sender, :sender),
      metrics: Map.get(config, :metrics, :metrics),
      upstream_timeout_s:
        Map.get(config, :upstream_timeout_s) ||
          case Map.get(config, :upstream_timeout_ms) do
            ms when is_integer(ms) and ms > 0 -> max(div(ms, 1000), 1)
            _ -> 120
          end,
      connect_timeout_s: Map.get(config, :connect_timeout_s, 10),
      stream_timeout_s: Map.get(config, :stream_timeout_s, 300),
      allow_streaming: Map.get(config, :allow_streaming, false),
      prompt_cache: Map.get(config, :prompt_cache, true),
      max_retries: min(max(Map.get(config, :max_retries, 1), 0), 3),
      empty_completion_retries: min(max(Map.get(config, :empty_completion_retries, 0), 0), 3)
    }

    if Decimal.compare(plug_opts.default_daily_limit, Decimal.new("0")) != :gt do
      Logger.warning(
        "llm_proxy: default_daily_limit is #{plug_opts.default_daily_limit} (≤ 0) — " <>
          "all agent LLM calls will be blocked by the daily budget"
      )
    end

    # Mirror the ceiling/default-limit config into the state Agent (the same one
    # dashboard_sessions/2 reads) so the read-only dashboard_extension path — which
    # only ever sees `state_pid`, never the object's own `quota:`-carrying state —
    # can publish it. See dashboard_quota/1 below.
    Agent.update(state_pid, fn s ->
      Map.put(s, :quota, %{
        global_daily_limit: plug_opts.global_daily_limit,
        default_daily_limit: plug_opts.default_daily_limit
      })
    end)

    # Static (pre-shared token) sessions: boot-config agents can't mint a token at
    # lease time — the host generated one and put it in both places (here and the
    # agent's config[:api_key]). Per-entry rescue: a malformed entry is an ops
    # mistake worth a warning, never a boot crash.
    config
    |> Map.get(:static_sessions, [])
    |> List.wrap()
    |> Enum.each(fn attrs ->
      result =
        try do
          if is_map(attrs) do
            register_static_session(
              state_pid,
              Map.put_new(attrs, :store_mod, plug_opts.store_mod)
            )
          else
            {:error, :not_a_map}
          end
        rescue
          e -> {:error, Exception.message(e)}
        end

      case result do
        {:ok, _token} ->
          Logger.info(
            "llm_proxy: static session registered for #{inspect(is_map(attrs) && Map.get(attrs, :conversation_id))}"
          )

        {:error, reason} ->
          Logger.warning(
            "llm_proxy: static session REJECTED (#{inspect(reason)}) for #{inspect(is_map(attrs) && Map.get(attrs, :conversation_id))}"
          )
      end
    end)

    # A loopback port race (two boots, or a leftover listener) must NOT crash the
    # object at boot — mirror webhook.ex / run_live's dashboard guard: accept an
    # already-started listener and log-and-continue on any other start error.
    # mm hardening: a NAMED listener + whereis-first — a double init (or a
    # leftover) must reuse the running listener, never bind twice (the second
    # Bandit.start_link would exit-signal the caller through the link).
    bandit =
      case Process.whereis(@bandit_name) do
        running when is_pid(running) ->
          Logger.info("llm_proxy: Bandit listener already running (#{inspect(running)})")
          running

        _ ->
          start_bandit_once(plug_opts, port)
      end

    {:ok,
     %{
       state_pid: state_pid,
       bandit: bandit,
       port: port,
       endpoint: endpoint(port),
       provider: plug_opts.provider,
       quota: %{
         store_mod: plug_opts.store_mod,
         default_daily_limit: plug_opts.default_daily_limit,
         daily_request_limit: plug_opts.daily_request_limit,
         global_daily_limit: plug_opts.global_daily_limit,
         clock: Map.get(config, :clock, fn -> DateTime.utc_now() end),
         dm_module: module_ref(Map.get(config, :dm_module))
       }
     }}
  end

  def interface do
    %{
      usage: %{
        input: ~s({"action":"usage"}),
        output: "per-session token/cost/error totals"
      },
      health: %{input: ~s({"action":"health"}), output: ~s({"ok":true})},
      quota_status: %{
        input:
          ~s({"action":"quota_status","conversation_id":"tg:903489662:0","kind":"dm","workspace_key":"default"}),
        output: "read-only per-identity request quota, spend, and global cap status"
      }
    }
  end

  def handle_message(_from, content, state) do
    case Jason.decode(content) do
      {:ok, %{"action" => "usage"}} ->
        {:reply, Jason.encode!(%{usage: usage_totals(state.state_pid)}), state}

      {:ok, %{"action" => "health"}} ->
        {:reply, Jason.encode!(%{ok: true, endpoint: state.endpoint, provider: state.provider}),
         state}

      {:ok, %{"action" => "quota_status"} = msg} ->
        {:reply, Jason.encode!(quota_status(msg, state)), state}

      _ ->
        {:noreply, state}
    end
  end

  # Config (atom or string, e.g. from JSON IR) → the pricing-mode atom.
  # :provider_first is retained as a compatibility alias for the explicit
  # :cost_plus name; anything unrecognized stays on that safe default.
  @doc false
  def pricing_mode(v) when v in [:rate_card_first, "rate_card_first"], do: :rate_card_first

  def pricing_mode(v) when v in [:cost_plus, "cost_plus", :provider_first, "provider_first"],
    do: :cost_plus

  def pricing_mode(_), do: :cost_plus

  def terminate(_reason, state) do
    if is_pid(state.bandit) and Process.alive?(state.bandit), do: GenServer.stop(state.bandit)
    if Process.alive?(state.state_pid), do: Agent.stop(state.state_pid)
    :ok
  end

  defp start_bandit_once(plug_opts, port) do
    case Bandit.start_link(
           plug: {__MODULE__.Plug, plug_opts},
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: port
         ) do
      {:ok, pid} ->
        try do
          Process.register(pid, @bandit_name)
        rescue
          # register race (another init won): keep OUR pid — both serve the port? No:
          # ours bound the socket; the name is best-effort discovery, not identity.
          ArgumentError -> :ok
        end

        pid

      {:error, {:already_started, pid}} ->
        Logger.info("llm_proxy: Bandit listener already started on port #{port}")
        pid

      {:error, reason} ->
        Logger.warning(
          Genswarms.LlmProxy.Plug.sanitize_log(
            Genswarms.LlmProxy.Plug.scrub_secret(
              "llm_proxy: Bandit listener did not start on port #{port}: #{inspect(reason)} " <>
                "(proxy endpoint unavailable; bot unaffected)",
              plug_opts.upstream_api_key
            )
          )
        )

        nil
    end
  end

  def endpoint(port), do: "http://127.0.0.1:#{port}/v1/chat/completions"

  def start_state_link(opts \\ []) do
    Agent.start_link(
      fn -> %{sessions: %{}, usage: %{}, notified: MapSet.new(), global: %{}} end,
      opts
    )
  end

  @doc """
  Returns true the FIRST time a (budget_identity, day) pair is seen, false after —
  so the budget Telegram notice is delivered at most once per conversation per UTC
  day **per proxy process lifetime**. A proxy restart clears the set and MAY re-notify
  (non-durable by design). Day-keyed: a new UTC day re-notifies. The set is pruned to
  the requested `day` on each call so it cannot grow unbounded.
  """
  def notice_once?(pid \\ @state_name, budget_identity, %Date{} = day) do
    key = {budget_identity, day}

    Agent.get_and_update(pid, fn state ->
      notified = Map.get(state, :notified, MapSet.new())

      if MapSet.member?(notified, key) do
        {false, state}
      else
        pruned = notified |> Enum.filter(fn {_bid, d} -> d == day end) |> MapSet.new()
        # Map.put (not `%{state | ...}`) so a keyless Agent state (e.g. an older boot)
        # cannot KeyError — the read above already falls back via Map.get/3.
        {true, Map.put(state, :notified, MapSet.put(pruned, key))}
      end
    end)
  end

  def register_session(pid \\ @state_name, attrs) when is_map(attrs) do
    put_session(pid, token(), attrs)
  end

  @doc """
  Register a session under a CALLER-SUPPLIED token.

  For static/boot-config agents: their definition is data evaluated before the
  proxy object exists, so they cannot mint a token at lease time the way pooled
  spawns do. The host generates one token, hands it to the proxy here (via the
  object's `static_sessions:` config, which calls this at init) AND to the
  agent's `config[:api_key]`. Tokens under 24 bytes are rejected — a static
  credential must never be silently weak.
  """
  def register_static_session(pid \\ @state_name, attrs) when is_map(attrs) do
    token = attrs |> Map.fetch!(:token) |> to_string()

    if byte_size(token) < 24 do
      {:error, :token_too_short}
    else
      put_session(pid, token, Map.delete(attrs, :token))
    end
  end

  defp put_session(pid, token, attrs) do
    session = %{
      conversation_id: Map.fetch!(attrs, :conversation_id),
      slot: attrs |> Map.fetch!(:slot) |> to_string(),
      kind: attrs |> Map.fetch!(:kind) |> to_string(),
      workspace_key: attrs |> Map.get(:workspace_key, "default") |> to_string(),
      budget_identity: budget_identity(attrs),
      daily_limit_usd: session_daily_limit(attrs)
    }

    persist_budget_origin(Map.get(attrs, :store_mod), session)

    Agent.update(pid, fn state ->
      sessions =
        state.sessions
        |> Enum.reject(fn {_token, existing} ->
          existing.slot == session.slot and existing.workspace_key == session.workspace_key
        end)
        |> Map.new()
        |> Map.put(token, session)

      %{state | sessions: sessions}
    end)

    {:ok, token}
  end

  defp persist_budget_origin(store_mod, session) do
    if is_atom(store_mod) and Code.ensure_loaded?(store_mod) and
         function_exported?(store_mod, :record_llm_budget_origin, 1) do
      store_mod.record_llm_budget_origin(session)
    end
  rescue
    _ -> nil
  end

  def budget_identity(attrs) when is_map(attrs) do
    workspace_key = attrs |> Map.get(:workspace_key, "default") |> to_string()
    kind = attrs |> Map.fetch!(:kind) |> to_string()
    conversation_id = attrs |> Map.fetch!(:conversation_id) |> to_string()

    "llmb_" <> hash([workspace_key, kind, conversation_id])
  end

  def upstream_session_id(budget_identity, %Date{} = day) when is_binary(budget_identity) do
    "llms_" <> hash([budget_identity, Date.to_iso8601(day)])
  end

  def lookup_session(pid \\ @state_name, token) when is_binary(token) do
    Agent.get(pid, &Map.get(&1.sessions, token))
  end

  def session_for_budget(pid \\ @state_name, budget_identity) when is_binary(budget_identity) do
    Agent.get(pid, fn state ->
      state.sessions
      |> Map.values()
      |> Enum.find(&(&1.budget_identity == budget_identity))
    end)
  rescue
    _ -> nil
  end

  def record_usage(pid \\ @state_name, session, day, session_id, attrs) do
    row = %{
      budget_identity: session.budget_identity,
      session_id: session_id,
      day: day,
      model: to_string(Map.get(attrs, :model) || ""),
      status: to_string(Map.get(attrs, :status) || "ok")
    }

    key = {row.budget_identity, row.day, row.session_id, row.model, row.status}
    budget_key = {row.budget_identity, row.day, row.session_id, "_budget", "_daily"}

    Agent.update(pid, fn state ->
      usage =
        Map.update(state.usage, key, Map.merge(row, counters(attrs)), fn old ->
          merge_counters(old, attrs)
        end)

      usage =
        if key != budget_key and Map.has_key?(usage, budget_key) do
          Map.update!(usage, budget_key, &merge_budget_counters(&1, attrs))
        else
          usage
        end

      # Operator-wide running total for `day` (PG-independent global-ceiling backstop):
      # accumulate this call's cost so the ceiling holds even when Postgres is down.
      global =
        state.global
        |> Map.update(
          day,
          decimal(Map.get(attrs, :cost_usd)),
          &Decimal.add(&1, decimal(Map.get(attrs, :cost_usd)))
        )
        |> prune_global(day)

      # Day-rollover prune: the in-memory map is only a store-down fallback and the
      # budget it enforces is per-UTC-day, so rows from any other day are dead weight.
      # Dropping them on every record keeps the map bounded to a single day.
      %{state | usage: prune_usage(usage, day), global: global}
    end)
  end

  @doc "Pure: the in-memory operator-wide spend accumulated for `day` (0 if none / store down)."
  def global_spent_inmem(pid \\ @state_name, %Date{} = day) do
    Agent.get(pid, fn s -> Map.get(s.global, day, Decimal.new("0")) end)
  end

  # Keep only `day` (mirrors prune_usage — the global ceiling is per-UTC-day).
  defp prune_global(global, day) do
    global |> Enum.filter(fn {d, _} -> d == day end) |> Map.new()
  end

  # Keep only the rows for `day` (the request's UTC day). Every value carries a `:day`
  # field (regular rows from `counters/1`, budget rows from `fallback_budget_status/5`).
  defp prune_usage(usage, day) do
    usage
    |> Enum.filter(fn {_key, row} -> row.day == day end)
    |> Map.new()
  end

  def usage_totals(pid \\ @state_name) do
    Agent.get(pid, fn state ->
      state.usage
      |> Map.values()
      |> Enum.sort_by(&{&1.day, &1.budget_identity, &1.model, &1.status})
    end)
  end

  def usage_for_budget_inmem(pid \\ @state_name, budget_identity, %Date{} = day, default_limit)
      when is_binary(budget_identity) do
    rows =
      pid
      |> usage_totals()
      |> Enum.filter(
        &(Map.get(&1, :budget_identity) == budget_identity and same_day?(Map.get(&1, :day), day))
      )

    {budget_rows, call_rows} = Enum.split_with(rows, &budget_row?/1)
    budget = List.first(budget_rows)
    base = budget || List.first(call_rows)

    %{
      budget_identity: budget_identity,
      day: day,
      session_id: (base && Map.get(base, :session_id)) || "",
      spent_usd:
        cond do
          budget -> Map.get(budget, :spent_usd, Decimal.new("0"))
          call_rows != [] -> sum_decimal(call_rows, :cost_usd)
          true -> Decimal.new("0")
        end,
      limit_usd: (budget && Map.get(budget, :limit_usd)) || decimal(default_limit),
      requests:
        if(call_rows == [],
          do: Map.get(budget || %{}, :requests, 0),
          else: sum_int(call_rows, :requests)
        ),
      prompt_tokens: sum_int(call_rows, :prompt_tokens),
      completion_tokens: sum_int(call_rows, :completion_tokens),
      total_tokens: sum_int(call_rows, :total_tokens),
      cached_tokens: sum_int(call_rows, :cached_tokens),
      non_cached_tokens: sum_int(call_rows, :non_cached_tokens)
    }
  rescue
    _ ->
      %{
        budget_identity: budget_identity,
        day: day,
        session_id: "",
        spent_usd: Decimal.new("0"),
        limit_usd: decimal(default_limit),
        requests: 0,
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0,
        cached_tokens: 0,
        non_cached_tokens: 0
      }
  end

  defp quota_status(%{"conversation_id" => cid} = msg, state)
       when is_binary(cid) and cid != "" do
    # Tolerate both host state shapes: everything under :quota (wingston lineage)
    # or store_mod/default_daily_limit at the top level with a *_usd global key
    # (mm lineage). The message may pin an explicit "day" (ISO) — mm's commands do.
    quota =
      state
      |> Map.get(:quota, %{})
      |> Map.put_new(:store_mod, Map.get(state, :store_mod))
      |> Map.put_new(
        :default_daily_limit,
        Map.get(state, :default_daily_limit, @default_daily_limit)
      )
      |> then(fn q ->
        if Map.has_key?(q, :global_daily_limit),
          do: q,
          else:
            Map.put(q, :global_daily_limit, Map.get(q, :global_daily_limit_usd, Decimal.new("0")))
      end)

    clock = Map.get(quota, :clock, fn -> DateTime.utc_now() end)

    day =
      case Date.from_iso8601(to_string(Map.get(msg, "day") || "")) do
        {:ok, d} -> d
        _ -> clock.() |> utc_day()
      end

    kind = Map.get(msg, "kind") || dm_kind(Map.get(quota, :dm_module), cid)
    workspace_key = Map.get(msg, "workspace_key") || "default"

    attrs = %{
      conversation_id: cid,
      kind: kind,
      workspace_key: workspace_key
    }

    budget_identity = budget_identity(attrs)
    state_pid = Map.get(state, :state_pid, @state_name)
    session = session_for_budget(state_pid, budget_identity)
    default_limit = quota_default_limit(quota, session)
    {usage, source} = quota_usage_row(quota, state_pid, budget_identity, day, default_limit)
    global_used = quota_global_spent(quota, state_pid, day)
    global_limit = decimal(Map.get(quota, :global_daily_limit, Decimal.new("0")))
    request_limit = request_limit(Map.get(quota, :daily_request_limit, 0))
    requests_used = max(int(Map.get(usage, :requests, 0)), 0)

    %{
      action: "quota_status",
      ok: true,
      conversation_id: cid,
      day: Date.to_iso8601(day),
      reset_at: "#{Date.to_iso8601(Date.add(day, 1))}T00:00:00Z",
      source: source,
      requests: %{
        used: requests_used,
        limit: request_limit,
        remaining: quota_remaining(requests_used, request_limit),
        pct: pct_int(requests_used, request_limit)
      },
      spend: %{
        used_usd: money(Map.get(usage, :spent_usd, Decimal.new("0"))),
        limit_usd: money(Map.get(usage, :limit_usd, default_limit)),
        pct:
          pct_decimal(
            Map.get(usage, :spent_usd, Decimal.new("0")),
            Map.get(usage, :limit_usd, default_limit)
          )
      },
      global: %{
        used_usd: money(global_used),
        limit_usd: money(global_limit),
        pct: pct_decimal(global_used, global_limit)
      },
      # mm vocabulary: the same numbers nested under "quota" with 2dp money strings
      # and a human reset stamp — both host lineages' consumers keep working.
      quota: %{
        budget: %{
          spent_usd: money2(Map.get(usage, :spent_usd, Decimal.new("0"))),
          limit_usd: money2(Map.get(usage, :limit_usd, default_limit)),
          remaining_usd:
            money2(
              Decimal.max(
                Decimal.sub(
                  Map.get(usage, :limit_usd, default_limit),
                  Map.get(usage, :spent_usd, Decimal.new("0"))
                ),
                Decimal.new("0")
              )
            )
        },
        requests: %{
          used: requests_used,
          limit: request_limit,
          remaining: quota_remaining(requests_used, request_limit)
        },
        global: %{spent_usd: money2(global_used), limit_usd: money2(global_limit)},
        reset_at: "#{Date.to_iso8601(Date.add(day, 1))} 00:00 UTC"
      }
    }
  end

  defp money2(value), do: value |> decimal() |> Decimal.round(2) |> Decimal.to_string(:normal)

  # Metric cards have bounded columns. Keep exact counts in machine payloads and
  # detail tables, but compact large headline values so Tokens cannot collide
  # with the adjacent Cache metric (for example 156,813,030 -> 156.8M).
  defp compact_count(value) when is_integer(value) do
    magnitude = abs(value)

    cond do
      magnitude >= 1_000_000_000 -> compact_count_unit(value, 1_000_000_000, "B")
      magnitude >= 1_000_000 -> compact_count_unit(value, 1_000_000, "M")
      magnitude >= 100_000 -> compact_count_unit(value, 1_000, "K")
      true -> value
    end
  end

  defp compact_count(value), do: value

  defp compact_count_unit(value, divisor, suffix) do
    formatted =
      value
      |> Decimal.new()
      |> Decimal.div(Decimal.new(divisor))
      |> Decimal.round(1)
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)

    formatted <> suffix
  end

  # Dashboard detail remains readable for sub-cent activity without showing six
  # decimals everywhere: cents normally, four decimals only for a non-zero value
  # whose magnitude is below one cent.
  defp money_ui(value) do
    d = decimal(value)

    places =
      if Decimal.compare(d, 0) != :eq and Decimal.compare(Decimal.abs(d), "0.01") == :lt,
        do: 4,
        else: 2

    d |> Decimal.round(places) |> Decimal.to_string(:normal)
  end

  defp quota_status(msg, _state) do
    %{
      action: "quota_status",
      ok: false,
      conversation_id: Map.get(msg, "conversation_id"),
      error: "missing_conversation_id"
    }
  end

  defp quota_default_limit(quota, session) do
    cond do
      is_map(session) and Map.get(session, :daily_limit_usd) ->
        decimal(Map.get(session, :daily_limit_usd))

      true ->
        decimal(Map.get(quota, :default_daily_limit, @default_daily_limit))
    end
  end

  defp quota_usage_row(quota, state_pid, budget_identity, day, default_limit) do
    store_mod = Map.get(quota, :store_mod)

    durable =
      try do
        cond do
          is_atom(store_mod) and Code.ensure_loaded?(store_mod) and
              function_exported?(store_mod, :llm_usage_for_budget, 3) ->
            store_mod.llm_usage_for_budget(budget_identity, day, default_limit)

          is_atom(store_mod) and Code.ensure_loaded?(store_mod) and
              function_exported?(store_mod, :llm_budget_usage, 2) ->
            store_mod.llm_budget_usage(budget_identity, day)

          true ->
            nil
        end
      rescue
        _ -> nil
      end

    if is_map(durable) do
      {durable, "postgres"}
    else
      {usage_for_budget_inmem(state_pid, budget_identity, day, default_limit), "memory"}
    end
  end

  defp quota_global_spent(quota, state_pid, day) do
    store_mod = Map.get(quota, :store_mod)

    durable =
      try do
        if is_atom(store_mod) and Code.ensure_loaded?(store_mod) and
             function_exported?(store_mod, :llm_usage_today, 1) do
          case store_mod.llm_usage_today(day) do
            %{spent_usd: spent} -> decimal(spent)
            _ -> Decimal.new("0")
          end
        else
          Decimal.new("0")
        end
      rescue
        _ -> Decimal.new("0")
      end

    inmem = global_spent_inmem(state_pid, day)
    if Decimal.compare(durable, inmem) == :gt, do: durable, else: inmem
  end

  # kind fallback when a quota_status message carries no "kind": ask the optional
  # dm_module (exports dm?/1) whether the cid is a DM; absent/unknown -> "group".
  defp dm_kind(dm_module, cid) do
    if is_atom(dm_module) and not is_nil(dm_module) and Code.ensure_loaded?(dm_module) and
         function_exported?(dm_module, :dm?, 1) and dm_module.dm?(cid),
       do: "dm",
       else: "group"
  end

  # Module refs arrive as atoms (Elixir swarm defs) or strings (JSON IR). Strings
  # resolve via to_existing_atom - no atom minting; unknown module -> nil (the
  # function_exported? guards downstream treat nil as absent, fail-open to memory).
  def module_ref(nil), do: nil
  def module_ref(mod) when is_atom(mod), do: mod

  def module_ref(name) when is_binary(name) do
    String.to_existing_atom("Elixir." <> String.trim_leading(name, "Elixir."))
  rescue
    ArgumentError -> nil
  end

  defp utc_day(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp utc_day(%NaiveDateTime{} = dt), do: NaiveDateTime.to_date(dt)
  defp utc_day(%Date{} = day), do: day
  defp utc_day(_), do: Date.utc_today()

  defp quota_remaining(_used, limit) when not is_integer(limit) or limit <= 0, do: nil
  defp quota_remaining(used, limit), do: max(limit - used, 0)

  defp pct_int(_used, limit) when not is_integer(limit) or limit <= 0, do: nil
  defp pct_int(used, limit), do: min(round(used * 100 / limit), 999)

  defp pct_decimal(used, limit) do
    limit = decimal(limit)

    if Decimal.compare(limit, Decimal.new("0")) == :gt do
      used
      |> decimal()
      |> Decimal.mult(Decimal.new(100))
      |> Decimal.div(limit)
      |> Decimal.round(0)
      |> Decimal.to_integer()
      |> min(999)
    else
      nil
    end
  end

  @doc """
  Declarative dashboard extension for the read-only upstream dashboard.

  The proxy owns the accounting details; the dashboard only renders the returned
  page grammar. Durable Postgres rows win when available. The in-memory mirror is
  used as a live fallback when the store is disabled/down.
  """
  def dashboard_extension(opts \\ []) do
    day = Keyword.get(opts, :day, Date.utc_today())
    state_pid = Keyword.get(opts, :state_pid, @state_name)
    users_by_cid = Keyword.get(opts, :users_by_cid, %{})
    users_by_budget = Keyword.get(opts, :users_by_budget, %{})
    origins_by_budget = Keyword.get(opts, :origins_by_budget, %{})

    # A dead/absent proxy still renders its DURABLE story (today's spend,
    # per-model breakdown) when a store is provided — a stopped proxy is
    # exactly when the operator needs the page. Only the live-state overlays
    # (in-memory usage fallback, live session mapping) go empty.
    if not proxy_state_alive?(state_pid) and is_nil(Keyword.get(opts, :store_mod)) do
      %{}
    else
      dashboard_extension_for_live_state(
        opts,
        day,
        state_pid,
        users_by_cid,
        users_by_budget,
        origins_by_budget
      )
    end
  end

  defp dashboard_extension_for_live_state(
         opts,
         day,
         state_pid,
         users_by_cid,
         users_by_budget,
         origins_by_budget
       ) do
    store_mod = Keyword.get(opts, :store_mod)
    {usage_rows, source} = dashboard_usage_rows(store_mod, day, state_pid)

    sessions = dashboard_sessions(state_pid)

    rows = dashboard_rows(usage_rows, sessions, users_by_cid, users_by_budget, origins_by_budget)
    totals = dashboard_totals(usage_rows)
    router_today = probe_map(store_mod, :llm_router_cost_today)

    quota = dashboard_quota(state_pid)

    ceiling_usd =
      quota |> Map.get(:global_daily_limit, Decimal.new("0")) |> decimal() |> Decimal.to_float()

    default_daily_limit_usd =
      quota |> Map.get(:default_daily_limit, Decimal.new("0")) |> decimal() |> Decimal.to_float()

    %{
      # mm vocabulary: uncapped budget count + requests at "llm_proxy" (the table
      # below stays capped at 100 rows for display — count and display differ).
      "llm_proxy" => %{
        "budgets" => length(usage_rows),
        "requests" => totals.requests,
        "spent_usd" => money(totals.spent_usd)
      },
      # Machine block (v1) for the observer's generic health_rules evaluator — numeric
      # twins of the "llm_proxy"/"proxy_router" strings above, PLUS the shipped
      # budget_guard rules. Additive only: existing keys above are never touched.
      "llm_proxy_budget" => %{
        "v" => 1,
        "ceiling_usd" => ceiling_usd,
        "spent_usd" => totals.spent_usd |> decimal() |> Decimal.to_float(),
        "default_daily_limit_usd" => default_daily_limit_usd,
        "health_rules" => @health_rules
      },
      "proxy_router" => %{
        "day" => Date.to_iso8601(day),
        "source" => source,
        "users" => length(rows),
        "requests" => totals.requests,
        "total_tokens" => totals.total_tokens,
        "spent_usd" => money(totals.spent_usd)
      },
      "dashboard_pages" => [
        %{
          "id" => "proxy-router",
          "label" => "Proxy router",
          "icon" => "hero-shield-check",
          "meta" => "UTC day " <> Date.to_iso8601(day),
          "sections" =>
            [
              %{
                "type" => "metrics",
                "title" => "Today usage",
                "span" => "half",
                "meta" => source,
                "items" => [
                  %{"label" => "Users", "value" => length(rows)},
                  %{"label" => "Budgets", "value" => length(usage_rows)},
                  %{"label" => "Requests", "value" => totals.requests},
                  %{"label" => "Tokens", "value" => compact_count(totals.total_tokens)},
                  %{
                    "label" => "Cache",
                    "value" => cache_rate(totals.cached_tokens, totals.prompt_tokens)
                  }
                ]
              }
            ] ++
              alltime_sections(store_mod, totals, source, router_today) ++
              [
                users_section(
                  store_mod,
                  rows,
                  sessions,
                  users_by_cid,
                  users_by_budget,
                  origins_by_budget
                )
              ] ++
              List.wrap(model_section(dashboard_model_rows(store_mod, day))) ++
              List.wrap(history_section(dashboard_history_rows(store_mod, 30)))
        }
      ]
    }
  end

  # Per-model breakdown (ported from mm's dashboard-llm-telemetry): durable only —
  # aggregated by the store's llm_usage_by_model/1; nil (section omitted) when the
  # store doesn't export it or has no per-model data.
  defp dashboard_model_rows(store_mod, day) do
    if is_atom(store_mod) and not is_nil(store_mod) and Code.ensure_loaded?(store_mod) and
         function_exported?(store_mod, :llm_usage_by_model, 1) do
      store_mod.llm_usage_by_model(day)
    else
      []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp today_costs_section(totals, source, router_today) do
    %{
      "type" => "metrics",
      "title" => "Today costs",
      "span" => "half",
      "columns" => 2,
      "meta" => today_costs_meta(router_today),
      "items" =>
        [
          %{
            "label" => "User charges",
            "value" => "$" <> money2(totals.spent_usd),
            "sub" =>
              if(source == "postgres", do: "durable proxy ledger", else: "live memory fallback"),
            "title" => "User charges accrued by the proxy today",
            "wrap_sub" => true
          }
        ] ++ List.wrap(router_cost_item(router_today))
    }
  end

  defp today_costs_meta(%{authoritative: false}),
    do: "legacy shared key · not comparable"

  defp today_costs_meta(%{authoritative: true}), do: "same-scope UTC day"
  defp today_costs_meta(%{}), do: "router scope unverified"
  defp today_costs_meta(_), do: "router cost unavailable"

  defp router_cost_item(%{cost_usd: cost} = row) do
    %{
      "label" => "Router cost",
      "value" => "$" <> money2(cost),
      "sub" => router_cost_sub(row),
      "title" => "Router-side cost for today's traffic",
      "wrap_sub" => true
    }
  end

  defp router_cost_item(_), do: nil

  defp router_cost_sub(row) do
    status = if(Map.get(row, :estimated, true), do: "router estimate", else: "exact router total")

    case fetched_at_hhmm(Map.get(row, :fetched_at)) do
      nil -> status
      hhmm -> status <> " · updated " <> hhmm <> " UTC"
    end
  end

  defp fetched_at_hhmm(%DateTime{} = value), do: Calendar.strftime(value, "%H:%M")
  defp fetched_at_hhmm(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%H:%M")
  defp fetched_at_hhmm(_), do: nil

  # Durable day history (newest-first) — probed store contract, host-owned SQL:
  # `store_mod.llm_usage_days/1` returns day aggregates across ALL budgets
  # (%{day, budgets, requests, prompt_tokens, total_tokens, cached_tokens,
  # spent_usd}). Same fail-open discipline as the By-model section: an absent
  # function or a raising store contributes nothing, never a crashed snapshot.
  defp dashboard_history_rows(store_mod, days) do
    if is_atom(store_mod) and not is_nil(store_mod) and Code.ensure_loaded?(store_mod) and
         function_exported?(store_mod, :llm_usage_days, 1) do
      store_mod.llm_usage_days(days)
    else
      []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @today_users_columns [
    %{"key" => "user", "label" => "user"},
    %{"key" => "slot", "label" => "slot", "mono" => true},
    %{"key" => "spent", "label" => "user spent", "align" => "right"},
    %{"key" => "limit", "label" => "limit", "align" => "right"},
    %{"key" => "requests", "label" => "req", "align" => "right"},
    %{"key" => "tokens", "label" => "tokens", "align" => "right"},
    %{"key" => "cache", "label" => "cache", "align" => "right"},
    %{"key" => "status", "label" => "status"},
    %{"key" => "budget", "label" => "budget", "mono" => true}
  ]

  # Multi-day windows have no meaningful daily limit/status; slot stays (a live
  # session's slot is still where that user's traffic runs right now).
  @period_users_columns [
    %{"key" => "user", "label" => "user"},
    %{"key" => "slot", "label" => "slot", "mono" => true},
    %{"key" => "spent", "label" => "user spent", "align" => "right"},
    %{"key" => "requests", "label" => "req", "align" => "right"},
    %{"key" => "tokens", "label" => "tokens", "align" => "right"},
    %{"key" => "cache", "label" => "cache", "align" => "right"},
    %{"key" => "budget", "label" => "budget", "mono" => true}
  ]

  @period_tabs [{"7 days", 7}, {"30 days", 30}, {"All-time", :all}]

  # The Users table, as period tabs when the host store exposes
  # `llm_usage_by_budget_since/2` (days | :all, limit) — Today keeps the live
  # day's limit/status semantics; 7/30/all-time aggregate the durable history.
  # Absent contract or a raising store falls back to the classic flat table
  # (never a crashed snapshot, and never an empty Users panel).
  defp users_section(store_mod, rows, sessions, users_by_cid, users_by_budget, origins_by_budget) do
    if is_atom(store_mod) and not is_nil(store_mod) and Code.ensure_loaded?(store_mod) and
         function_exported?(store_mod, :llm_usage_by_budget_since, 2) do
      period_tabs =
        Enum.map(@period_tabs, fn {label, window} ->
          usage = store_mod.llm_usage_by_budget_since(window, 100)

          %{
            "label" => label,
            "section" =>
              users_table(
                dashboard_rows(usage, sessions, users_by_cid, users_by_budget, origins_by_budget),
                @period_users_columns,
                "user spend at the operator-set price, summed over the window"
              )
          }
        end)

      %{
        "type" => "tabs",
        "title" => "Users",
        "meta" => "unmapped rows come from budget hashes",
        "tabs" => [
          %{
            "label" => "Today",
            "section" =>
              users_table(rows, @today_users_columns, "resets 00:00 UTC — the quota view")
          }
          | period_tabs
        ]
      }
    else
      flat_users_table(rows)
    end
  rescue
    _ -> flat_users_table(rows)
  catch
    _, _ -> flat_users_table(rows)
  end

  defp flat_users_table(rows),
    do: users_table(rows, @today_users_columns, "unmapped rows come from budget hashes")

  defp users_table(rows, columns, meta) do
    %{
      "type" => "table",
      "title" => "Users",
      "meta" => meta,
      "columns" => columns,
      "rows" => rows
    }
  end

  # Usage, current-day cost, historical evidence, and authoritative accounting are
  # deliberately separate sections. Lifetime reconstructed totals must never sit
  # beside a same-scope margin in a way that invites subtracting unlike populations.
  defp alltime_sections(store_mod, totals, source, router_today) do
    today_costs = today_costs_section(totals, source, router_today)

    case probe_map(store_mod, :llm_usage_alltime) do
      %{} = u ->
        case probe_map(store_mod, :llm_financials_alltime) do
          %{} = financials ->
            [alltime_usage_section(u), today_costs] ++ financials_sections(financials)

          _ ->
            [
              alltime_usage_section(u),
              today_costs,
              legacy_lifetime_costs_section(u, probe_map(store_mod, :llm_router_cost_alltime))
            ]
        end

      _ ->
        [today_costs]
    end
  end

  defp legacy_lifetime_costs_section(u, router) do
    repriced? =
      case Map.get(u, :accounting_note) do
        note when is_binary(note) -> String.contains?(String.downcase(note), "reconstruct")
        _ -> false
      end

    %{
      "type" => "metrics",
      "title" => "Lifetime costs",
      "span" => "half",
      "columns" => 2,
      "meta" => "legacy contract · comparability unverified",
      "items" =>
        [
          %{
            "label" => if(repriced?, do: "Repriced user total", else: "Reported user total"),
            "value" => "$" <> money2(Map.get(u, :spent_usd)),
            "sub" => Map.get(u, :spend_sub, "legacy host contract"),
            "wrap_sub" => true
          }
        ] ++ List.wrap(router_alltime_item(router))
    }
  end

  defp alltime_usage_section(u) do
    since =
      case Map.get(u, :since) do
        %Date{} = d -> "since " <> Date.to_iso8601(d) <> " \u00b7 "
        _ -> ""
      end

    %{
      "type" => "metrics",
      "title" => "All-time usage",
      "span" => "half",
      "meta" => since <> "#{Map.get(u, :days, 0)} day(s), durable",
      "items" => [
        %{"label" => "Requests", "value" => Map.get(u, :requests, 0)},
        %{"label" => "Tokens", "value" => compact_count(Map.get(u, :total_tokens, 0))},
        %{
          "label" => "Cache",
          "value" => cache_rate(Map.get(u, :cached_tokens), Map.get(u, :prompt_tokens))
        }
      ]
    }
  end

  defp financials_sections(financials) do
    # Comparability is an accounting assertion, not a compatibility default.
    # Older or partial host contracts stay in historical evidence until they
    # explicitly attest that the populations share an accounting scope.
    authoritative = Map.get(financials, :authoritative, false) == true
    legacy_history? = not authoritative or Map.get(financials, :legacy_router_included, false)

    List.wrap(if(legacy_history?, do: historical_costs_section(financials))) ++
      List.wrap(if(authoritative, do: comparable_costs_section(financials)))
  end

  defp historical_costs_section(financials) do
    user_total =
      Map.get(financials, :lifetime_spent_usd, Map.get(financials, :spent_usd, Decimal.new(0)))

    router_total =
      Map.get(
        financials,
        :lifetime_router_cost_usd,
        Map.get(financials, :router_cost_usd, Decimal.new(0))
      )

    %{
      "type" => "metrics",
      "title" => "Historical evidence",
      "span" => "half",
      "columns" => 2,
      "meta" => "legacy shared key · not comparable",
      "items" => [
        %{
          "label" => "Repriced user total",
          "value" => "$" <> money2(user_total),
          "sub" => "archive-backed replay included",
          "title" => "Reconstructed user ledger total; not a literal pre-proxy charge",
          "wrap_sub" => true
        },
        %{
          "label" => "Router evidence",
          "value" => "$" <> money2(router_total),
          "sub" => "legacy shared-key estimates",
          "title" => "Router total from a different historical population; do not subtract",
          "wrap_sub" => true
        }
      ]
    }
  end

  defp comparable_costs_section(financials) do
    since =
      case Map.get(financials, :since) do
        %Date{} = d -> Date.to_iso8601(d)
        _ -> "the accounting cutover"
      end

    margin_pct =
      financials
      |> Map.get(:gross_margin_pct, Decimal.new(0))
      |> decimal()
      |> Decimal.round(1)
      |> Decimal.to_string(:normal)

    reconciled = financials_reconciled?(financials)

    %{
      "type" => "metrics",
      "title" => "Comparable accounting",
      "span" => "full",
      "columns" => 4,
      "meta" => comparable_meta(financials, since),
      "items" => [
        %{
          "label" => "User charges",
          "value" => "$" <> money2(Map.get(financials, :spent_usd)),
          "sub" => "same-scope proxy ledger",
          "wrap_sub" => true
        },
        %{
          "label" => "Router cost",
          "value" => "$" <> money2(Map.get(financials, :router_cost_usd)),
          "sub" =>
            if(Map.get(financials, :estimated_any, true),
              do: "includes router estimates",
              else: "exact router total"
            ),
          "wrap_sub" => true
        },
        %{
          "label" => "Cost-plus margin",
          "value" =>
            if(reconciled,
              do: "$" <> money2(Map.get(financials, :gross_margin_usd)),
              else: "—"
            ),
          "sub" =>
            if(reconciled,
              do: margin_pct <> "% of router cost",
              else: "withheld until coverage matches"
            ),
          "tone" => margin_tone(financials, reconciled),
          "wrap_sub" => true
        },
        coverage_item(financials, reconciled)
      ]
    }
  end

  defp comparable_meta(financials, since) do
    scope =
      case Map.get(financials, :accounting_scope) do
        value when is_binary(value) and value != "" -> " · scope " <> String.slice(value, 0, 80)
        _ -> ""
      end

    "since #{since} · #{Map.get(financials, :days, 0)} same-scope UTC day(s)" <> scope
  end

  defp coverage_item(financials, reconciled) do
    ledger_requests = Map.get(financials, :ledger_requests)
    router_requests = Map.get(financials, :router_requests)
    ledger_tokens = Map.get(financials, :ledger_tokens)
    router_tokens = Map.get(financials, :router_tokens)

    {sub, title} =
      case {ledger_requests, router_requests, ledger_tokens, router_tokens} do
        {lr, rr, lt, rt}
        when is_integer(lr) and is_integer(rr) and is_integer(lt) and is_integer(rt) ->
          {
            "req #{lr}/#{rr} · tokens #{compact_count(lt)}/#{compact_count(rt)}",
            "Requests #{lr}/#{rr}; tokens #{lt}/#{rt}"
          }

        {lr, rr, _, _} when is_integer(lr) and is_integer(rr) ->
          {"requests #{lr}/#{rr}", "Requests #{lr}/#{rr}; token coverage unavailable"}

        _ ->
          {"request/token coverage unavailable", "Reconciliation coverage unavailable"}
      end

    %{
      "label" => "Coverage",
      "value" => if(reconciled, do: "Reconciled", else: "Mismatch"),
      "sub" => sub,
      "title" => title,
      "tone" => if(reconciled, do: nil, else: "warn"),
      "wrap_sub" => true
    }
  end

  defp margin_tone(_financials, false), do: nil

  defp margin_tone(financials, true) do
    if Decimal.compare(decimal(Map.get(financials, :gross_margin_usd)), 0) == :lt,
      do: "warn",
      else: nil
  end

  defp financials_reconciled?(financials) do
    reported = Map.get(financials, :reconciled)

    observed =
      case {
        Map.get(financials, :ledger_requests),
        Map.get(financials, :router_requests),
        Map.get(financials, :ledger_tokens),
        Map.get(financials, :router_tokens)
      } do
        {lr, rr, lt, rt}
        when is_integer(lr) and is_integer(rr) and is_integer(lt) and is_integer(rt) ->
          lr == rr and lt == rt

        {lr, rr, _, _} when is_integer(lr) and is_integer(rr) ->
          lr == rr

        _ ->
          nil
      end

    case {reported, observed} do
      {false, _} -> false
      {true, false} -> false
      {true, _} -> true
      {_, value} when is_boolean(value) -> value
      _ -> false
    end
  end

  defp router_alltime_item(%{cost_usd: cost} = row) do
    %{
      "label" => "Router evidence",
      "value" => "$" <> money2(cost),
      "sub" =>
        if(Map.get(row, :estimated_any, true),
          do: "includes router estimates",
          else: "exact router total"
        ),
      "wrap_sub" => true
    }
  end

  defp router_alltime_item(_), do: nil

  # Zero-arity probed-contract read with the section-builders' fail-open discipline.
  defp probe_map(store_mod, fun) do
    if is_atom(store_mod) and not is_nil(store_mod) and Code.ensure_loaded?(store_mod) and
         function_exported?(store_mod, fun, 0) do
      apply(store_mod, fun, [])
    else
      nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp history_section([]), do: nil
  defp history_section(rows) when not is_list(rows), do: nil

  defp history_section(day_rows) do
    # Both spends when the host supplies them: "user spent" (operator-set price,
    # summed from per-budget accounting) and "router" (the day estimate the host
    # synced from its router's usage API — optional :router_cost_usd).
    with_router? = Enum.any?(day_rows, &(not is_nil(Map.get(&1, :router_cost_usd))))

    rows =
      Enum.map(day_rows, fn row ->
        base = %{
          "day" => row |> Map.get(:day) |> day_label(),
          "budgets" => Map.get(row, :budgets, 0),
          "req" => Map.get(row, :requests, 0),
          "tokens" => Map.get(row, :total_tokens, 0),
          "cache" => cache_rate(Map.get(row, :cached_tokens), Map.get(row, :prompt_tokens)),
          "spent" => "$" <> money_ui(decimal(Map.get(row, :spent_usd)))
        }

        if with_router? do
          Map.put(
            base,
            "router",
            case Map.get(row, :router_cost_usd) do
              nil -> "—"
              cost -> "$" <> money_ui(decimal(cost))
            end
          )
        else
          base
        end
      end)

    router_col =
      if with_router?,
        do: [%{"key" => "router", "label" => "router", "align" => "right"}],
        else: []

    %{
      "type" => "table",
      "title" => "History · last #{length(rows)} days",
      "meta" => "durable day totals across all budgets — survives restarts",
      "columns" =>
        [
          %{"key" => "day", "label" => "day", "mono" => true},
          %{"key" => "budgets", "label" => "budgets", "align" => "right"},
          %{"key" => "req", "label" => "req", "align" => "right"},
          %{"key" => "tokens", "label" => "tokens", "align" => "right"},
          %{"key" => "cache", "label" => "cache", "align" => "right"},
          %{"key" => "spent", "label" => "user spent", "align" => "right"}
        ] ++ router_col,
      "rows" => rows
    }
  end

  defp day_label(%Date{} = d), do: Date.to_iso8601(d)
  defp day_label(other), do: to_string(other || "")

  defp model_section([]), do: nil

  defp model_section(model_rows) do
    rows =
      Enum.map(model_rows, fn row ->
        %{
          "model" => to_string(Map.get(row, :model) || ""),
          "spent" => "$" <> money_ui(decimal(Map.get(row, :spent_usd))),
          "tokens" => Map.get(row, :total_tokens, 0),
          "cache" => cache_rate(Map.get(row, :cached_tokens), Map.get(row, :prompt_tokens)),
          "calls" => Map.get(row, :calls, 0)
        }
      end)

    %{
      "type" => "table",
      "title" => "By model",
      "meta" => "spend / tokens / cache per served model",
      "columns" => [
        %{"key" => "model", "label" => "model", "mono" => true},
        %{"key" => "spent", "label" => "spent", "align" => "right"},
        %{"key" => "tokens", "label" => "tokens", "align" => "right"},
        %{"key" => "cache", "label" => "cache", "align" => "right"},
        %{"key" => "calls", "label" => "calls", "align" => "right"}
      ],
      "rows" => rows
    }
  end

  def fallback_budget_status(pid \\ @state_name, session, day, session_id, default_limit) do
    Agent.get_and_update(pid, fn state ->
      key = {session.budget_identity, day, session_id, "_budget", "_daily"}

      row =
        Map.get(state.usage, key) ||
          %{
            budget_identity: session.budget_identity,
            session_id: session_id,
            day: day,
            model: "_budget",
            status: "_daily",
            requests: 0,
            prompt_tokens: 0,
            completion_tokens: 0,
            total_tokens: 0,
            cached_tokens: 0,
            non_cached_tokens: 0,
            cost_usd: Decimal.new("0"),
            spent_usd: Decimal.new("0"),
            limit_usd: default_limit
          }

      {row, %{state | usage: Map.put(state.usage, key, row)}}
    end)
  end

  defp dashboard_usage_rows(store_mod, day, state_pid) do
    durable =
      try do
        cond do
          is_atom(store_mod) and Code.ensure_loaded?(store_mod) and
              function_exported?(store_mod, :llm_usage_by_budget, 2) ->
            store_mod.llm_usage_by_budget(day, 500)

          is_atom(store_mod) and Code.ensure_loaded?(store_mod) and
              function_exported?(store_mod, :list_llm_usage, 1) ->
            store_mod.list_llm_usage(500)
            |> Enum.filter(&same_day?(Map.get(&1, :day), day))

          true ->
            []
        end
      rescue
        _ -> []
      end

    if is_list(durable) and durable != [],
      do: {durable, "postgres"},
      else: {dashboard_memory_usage(state_pid, day), "memory"}
  end

  defp dashboard_memory_usage(state_pid, day) do
    state_pid
    |> usage_totals()
    |> Enum.filter(&same_day?(Map.get(&1, :day), day))
    |> collapse_memory_usage()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp collapse_memory_usage(rows) do
    {budget_rows, call_rows} = Enum.split_with(rows, &budget_row?/1)

    limits =
      Map.new(budget_rows, fn row ->
        {row.budget_identity,
         %{
           spent_usd: Map.get(row, :spent_usd, Decimal.new("0")),
           limit_usd: Map.get(row, :limit_usd, Decimal.new("0"))
         }}
      end)

    call_rows
    |> Enum.group_by(& &1.budget_identity)
    |> Enum.map(fn {budget_identity, rows} ->
      base = hd(rows)
      limit = Map.get(limits, budget_identity, %{})
      spent = sum_decimal(rows, :cost_usd)

      %{
        budget_identity: budget_identity,
        day: base.day,
        session_id: base.session_id,
        spent_usd:
          if(Decimal.compare(spent, Decimal.new("0")) == :gt,
            do: spent,
            else: Map.get(limit, :spent_usd, Decimal.new("0"))
          ),
        limit_usd: Map.get(limit, :limit_usd, Decimal.new("0")),
        requests: sum_int(rows, :requests),
        prompt_tokens: sum_int(rows, :prompt_tokens),
        completion_tokens: sum_int(rows, :completion_tokens),
        total_tokens: sum_int(rows, :total_tokens),
        cached_tokens: sum_int(rows, :cached_tokens),
        non_cached_tokens: sum_int(rows, :non_cached_tokens)
      }
    end)
  end

  defp dashboard_sessions(state_pid) do
    Agent.get(state_pid, fn state ->
      state.sessions
      |> Map.values()
      |> Map.new(fn session -> {session.budget_identity, session} end)
    end)
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  # Same liveness/timeout guard as dashboard_sessions/1: a dead proxy (durable-only
  # dashboard path) has nothing live to read, so quota goes empty — the caller
  # treats a missing key as "disabled/unknown" (0.0), never as a false ceiling.
  defp dashboard_quota(state_pid) do
    Agent.get(state_pid, fn state -> Map.get(state, :quota, %{}) end)
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp proxy_state_alive?(pid) when is_pid(pid), do: Process.alive?(pid)

  defp proxy_state_alive?(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp proxy_state_alive?(_), do: false

  defp dashboard_rows(usage_rows, sessions, users_by_cid, users_by_budget, origins_by_budget) do
    usage_rows
    |> Enum.sort_by(&(Decimal.to_float(decimal(Map.get(&1, :spent_usd))) * -1))
    |> Enum.take(100)
    |> Enum.map(fn row ->
      session = Map.get(sessions, row.budget_identity)
      spent = decimal(Map.get(row, :spent_usd))
      limit = decimal(Map.get(row, :limit_usd))

      %{
        "user" => dashboard_user(row, session, users_by_cid, users_by_budget, origins_by_budget),
        "slot" => (session && session.slot) || "—",
        "spent" => "$" <> money_ui(spent),
        "limit" => "$" <> money_ui(limit),
        "requests" => int(Map.get(row, :requests)),
        "tokens" => int(Map.get(row, :total_tokens)),
        "cache" => cache_rate(Map.get(row, :cached_tokens), Map.get(row, :prompt_tokens)),
        "status" => budget_status(spent, limit),
        "budget" => short_budget(row.budget_identity)
      }
      # NOT a column: the conversation id behind this budget, when known (live
      # session, else the persisted origin). Underscore-prefixed row keys are
      # the page grammar's metadata channel — the dashboard renders only
      # declared columns and may use "_cid" to open its conversation inspector.
      |> put_row_cid(session, Map.get(origins_by_budget, row.budget_identity))
    end)
  end

  defp put_row_cid(row, %{conversation_id: cid}, _origin) when is_binary(cid) and cid != "",
    do: Map.put(row, "_cid", cid)

  defp put_row_cid(row, _session, origin) do
    case get_any(origin || %{}, :conversation_id) do
      cid when is_binary(cid) and cid != "" -> Map.put(row, "_cid", cid)
      _ -> row
    end
  end

  defp dashboard_totals(rows) do
    %{
      requests: sum_int(rows, :requests),
      prompt_tokens: sum_int(rows, :prompt_tokens),
      cached_tokens: sum_int(rows, :cached_tokens),
      total_tokens: sum_int(rows, :total_tokens),
      spent_usd: sum_decimal(rows, :spent_usd)
    }
  end

  defp dashboard_user(row, nil, _users_by_cid, users_by_budget, origins_by_budget) do
    user_label(Map.get(users_by_budget, row.budget_identity)) ||
      origin_label(Map.get(origins_by_budget, row.budget_identity)) ||
      "unmapped budget identity"
  end

  defp dashboard_user(row, session, users_by_cid, users_by_budget, origins_by_budget) do
    user =
      Map.get(users_by_cid, session.conversation_id) ||
        Map.get(users_by_budget, row.budget_identity)

    user_label(user) ||
      origin_label(Map.get(origins_by_budget, row.budget_identity)) ||
      live_session_label(session) ||
      "conversation"
  end

  defp live_session_label(%{kind: "group", conversation_id: cid}) when is_binary(cid),
    do: "Telegram group #{cid}"

  defp live_session_label(%{kind: "dm"}), do: "unmapped DM"
  defp live_session_label(%{kind: kind}) when is_binary(kind), do: kind
  defp live_session_label(_), do: nil

  defp origin_label(origin) do
    label = get_any(origin || %{}, :label)

    cond do
      is_binary(label) and label != "" ->
        label

      get_any(origin || %{}, :kind) == "group" and
          is_binary(get_any(origin || %{}, :conversation_id)) ->
        "Telegram group #{get_any(origin, :conversation_id)}"

      get_any(origin || %{}, :kind) == "dm" ->
        "unmapped DM"

      true ->
        nil
    end
  end

  defp user_label(user) do
    handle = get_any(user || %{}, :handle)
    name = get_any(user || %{}, :name)

    cond do
      is_binary(handle) and handle != "" and is_binary(name) and name != "" ->
        "@#{handle} · #{name}"

      is_binary(handle) and handle != "" ->
        "@#{handle}"

      is_binary(name) and name != "" ->
        name

      true ->
        nil
    end
  end

  defp same_day?(%Date{} = value, %Date{} = day), do: Date.compare(value, day) == :eq
  defp same_day?(value, %Date{} = day) when is_binary(value), do: value == Date.to_iso8601(day)
  defp same_day?(_, _), do: false

  defp budget_row?(%{model: "_budget", status: "_daily"}), do: true
  defp budget_row?(_), do: false

  defp budget_status(spent, limit) do
    if Decimal.compare(decimal(spent), decimal(limit)) == :lt, do: "ok", else: "exhausted"
  end

  defp cache_rate(cached, prompt) when is_integer(cached) and is_integer(prompt) and prompt > 0,
    do: "#{round(cached * 100 / prompt)}%"

  defp cache_rate(_, _), do: "0%"

  defp short_budget("llmb_" <> rest), do: "llmb_" <> String.slice(rest, 0, 10)
  defp short_budget(value) when is_binary(value), do: String.slice(value, 0, 15)
  defp short_budget(_), do: "—"

  defp money(%Decimal{} = value), do: value |> Decimal.round(6) |> Decimal.to_string(:normal)
  defp money(value), do: value |> decimal() |> money()

  defp sum_int(rows, key), do: Enum.reduce(rows, 0, &(&2 + int(Map.get(&1, key))))

  defp sum_decimal(rows, key),
    do: Enum.reduce(rows, Decimal.new("0"), &Decimal.add(&2, decimal(Map.get(&1, key))))

  defp get_any(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  # L4 (LENIENT): only a status:"ok" call burns the daily request quota — mirrors
  # the durable store's gate (store.ex record_llm_call: CASE WHEN status = 'ok'
  # THEN 1 ELSE 0). Every OTHER counter (tokens/cost/spent) accrues regardless of
  # status, exactly as before — only `requests` is gated, so the PG-down fallback
  # mirror can't request-quota-block a conversation off failed calls.
  defp request_increment(attrs) do
    if to_string(Map.get(attrs, :status) || "ok") == "ok", do: 1, else: 0
  end

  defp counters(attrs) do
    %{
      requests: request_increment(attrs),
      prompt_tokens: int(attrs[:prompt_tokens]),
      completion_tokens: int(attrs[:completion_tokens]),
      total_tokens: int(attrs[:total_tokens]),
      cached_tokens: int(attrs[:cached_tokens]),
      non_cached_tokens: int(attrs[:non_cached_tokens]),
      cost_usd: decimal(attrs[:cost_usd])
    }
  end

  defp merge_counters(old, attrs) do
    %{
      old
      | requests: old.requests + request_increment(attrs),
        prompt_tokens: old.prompt_tokens + int(attrs[:prompt_tokens]),
        completion_tokens: old.completion_tokens + int(attrs[:completion_tokens]),
        total_tokens: old.total_tokens + int(attrs[:total_tokens]),
        cached_tokens: Map.get(old, :cached_tokens, 0) + int(attrs[:cached_tokens]),
        non_cached_tokens: Map.get(old, :non_cached_tokens, 0) + int(attrs[:non_cached_tokens]),
        cost_usd: Decimal.add(old.cost_usd, decimal(attrs[:cost_usd]))
    }
  end

  defp merge_budget_counters(old, attrs) do
    cost = decimal(attrs[:cost_usd])

    %{
      old
      | requests: old.requests + request_increment(attrs),
        prompt_tokens: old.prompt_tokens + int(attrs[:prompt_tokens]),
        completion_tokens: old.completion_tokens + int(attrs[:completion_tokens]),
        total_tokens: old.total_tokens + int(attrs[:total_tokens]),
        cached_tokens: Map.get(old, :cached_tokens, 0) + int(attrs[:cached_tokens]),
        non_cached_tokens: Map.get(old, :non_cached_tokens, 0) + int(attrs[:non_cached_tokens]),
        cost_usd: Decimal.add(old.cost_usd, cost),
        spent_usd: Decimal.add(old.spent_usd, cost)
    }
  end

  defp int(v) when is_integer(v), do: v
  defp int(_), do: 0

  @doc """
  Cached / non-cached prompt-token split for a call.

  The router carries the canonical per-call prompt-cache READ count on
  `x_router.tokens_cached` (always present on x_router, may be null). The
  OpenAI-shape `usage.prompt_tokens_details.cached_tokens` is the fallback
  (the router only emits it when > 0). Non-cached prompt tokens are never
  reported directly, so they are derived as `prompt_tokens - cached` — the
  same formula the router uses internally. `cached` is clamped into
  `[0, prompt]` so the two halves are always non-negative and sum to
  `prompt_tokens`, even on a hostile/buggy upstream. cache_creation /
  cache-write tokens are not emitted anywhere and are not tracked.
  """
  def cache_split(usage, router) when is_map(usage) and is_map(router) do
    prompt = max(int(usage["prompt_tokens"]), 0)

    cached =
      case int(router["tokens_cached"]) do
        0 -> int(get_in(usage, ["prompt_tokens_details", "cached_tokens"]))
        n -> n
      end
      |> max(0)
      |> min(prompt)

    {cached, prompt - cached}
  end

  def cache_split(_usage, _router), do: {0, 0}

  def decimal(%Decimal{} = value), do: value
  def decimal(value) when is_integer(value), do: Decimal.new(value)
  def decimal(value) when is_float(value), do: Decimal.from_float(value)

  def decimal(value) when is_binary(value) do
    # DRY: delegate parsing to raw_decimal/1, then apply the non-finite hardening here.
    d = raw_decimal(value)
    if finite_decimal?(d), do: d, else: Decimal.new("0")
  end

  def decimal(_), do: Decimal.new("0")

  @doc false
  def request_limit(nil), do: 0
  def request_limit(value) when is_integer(value), do: max(value, 0)

  def request_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> max(n, 0)
      _ -> 0
    end
  end

  def request_limit(value) when is_float(value), do: value |> trunc() |> max(0)
  def request_limit(_), do: 0

  @nineteen_nines Decimal.new("999999999.999999999")

  # Returns `{Decimal.t(), invalid? :: boolean}`.
  # Non-finite (Infinity, NaN) → `{0, true}`.
  # Negative → `{0, false}` (floor, not flagged as invalid).
  # > NUMERIC(18,9) max → `{clamped_max, true}`.
  # Otherwise → `{Decimal.round(value, 9), false}`.
  #
  # NOTE: uses `raw_decimal/1` (not `decimal/1`) so that non-finite string inputs
  # like "Infinity"/"NaN" are detected before the `decimal/1` hardening zeroes them.
  @doc false
  def sanitize_cost(value) do
    d = raw_decimal(value)

    cond do
      not finite_decimal?(d) -> {Decimal.new(0), true}
      Decimal.compare(d, 0) == :lt -> {Decimal.new(0), false}
      Decimal.compare(d, @nineteen_nines) == :gt -> {@nineteen_nines, true}
      # normalize: strip the trailing zeros round-to-9 introduces (0.000123000) so
      # value-equal costs are struct-equal across hosts (mm rows pin this).
      true -> {d |> Decimal.round(9) |> Decimal.normalize(), false}
    end
  end

  # Like `decimal/1` but does NOT reject non-finite results in the binary clause.
  # Used by `sanitize_cost/1`, `decimal/1`, and the streaming/session_acc cost path to
  # distinguish Infinity/NaN from zero before `decimal/1`'s hardening would zero them.
  # Public @doc false so the Plug's cost chokepoint can detect non-finite session_acc costs.
  @doc false
  def raw_decimal(%Decimal{} = value), do: value
  def raw_decimal(value) when is_integer(value), do: Decimal.new(value)
  def raw_decimal(value) when is_float(value), do: Decimal.from_float(value)

  def raw_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {d, ""} -> d
      _ -> Decimal.new("0")
    end
  end

  def raw_decimal(_), do: Decimal.new("0")

  @doc false
  def finite_decimal?(%Decimal{coef: c}) when is_integer(c), do: true
  def finite_decimal?(%Decimal{}), do: false
  def finite_decimal?(_), do: false

  # User-facing cost markup. `base` is the upstream's direct per-call cost
  # (router cost_usd — string/number/%Decimal{}); `rate_card_cost` is the
  # hardcoded token×price cost the operator charges; `margin_pct` is a percentage
  # markup (env `LLM_PROXY_COST_MARGIN_PCT`).
  #
  #   charge = (base if base > 0, else rate_card_cost if base == 0) × (1 + margin_pct/100)
  #
  # An EXACTLY-$0 (free) upstream cost falls back to the rate card so even free models
  # accrue a charge. A NEGATIVE base is anomalous — it is passed through UNCHANGED so
  # `sanitize_cost/1` floors it to 0 (never rate-carded). Operates ONLY on a finite
  # `base`: a non-finite base ("Infinity"/"NaN" from a hostile upstream) also passes
  # through untouched so `sanitize_cost/1` still flags it (llm_proxy_cost_invalid)
  # instead of being silently rate-carded. With margin 0 + no rate card this is a
  # no-op, so the default (unconfigured) cost path is byte-identical to before.
  @doc false
  def markup_cost(base, rate_card_cost, margin_pct) do
    d = raw_decimal(base)

    if finite_decimal?(d) do
      case Decimal.compare(d, Decimal.new(0)) do
        :gt -> apply_margin(d, margin_pct)
        :eq -> apply_margin(rate_card_cost, margin_pct)
        :lt -> base
      end
    else
      base
    end
  end

  # Multiply a finite cost by (1 + margin_pct/100). margin_pct may be a string
  # ("30"), number, nil, or blank; a non-positive/blank/non-finite margin is a no-op.
  @doc false
  def apply_margin(%Decimal{} = cost, margin_pct) do
    case margin_multiplier(margin_pct) do
      nil -> cost
      mult -> Decimal.mult(cost, mult)
    end
  end

  defp margin_multiplier(margin_pct) do
    pct = raw_decimal(margin_pct)

    if finite_decimal?(pct) and Decimal.compare(pct, Decimal.new(0)) == :gt do
      Decimal.add(Decimal.new(1), Decimal.div(pct, Decimal.new(100)))
    else
      nil
    end
  end

  defp session_daily_limit(attrs) do
    case Map.get(attrs, :daily_limit_usd) do
      nil -> nil
      value -> decimal(value)
    end
  end

  defp hash(parts) do
    parts
    |> Enum.map(&to_string/1)
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  def default_daily_limit, do: decimal(@default_daily_limit)

  def decimal_to_json_number(%Decimal{} = value) do
    text =
      value
      |> Decimal.round(9)
      |> Decimal.to_string(:normal)

    case Float.parse(text) do
      {float, ""} -> float
      _ -> 0.0
    end
  end
end

defmodule Genswarms.LlmProxy.Plug do
  @moduledoc false

  use Plug.Router
  require Logger

  alias Genswarms.LlmProxy, as: Proxy

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  get "/healthz" do
    json(conn, 200, %{ok: true})
  end

  post "/v1/chat/completions" do
    opts = conn.private.router_opts

    with {:ok, token} <- bearer(conn),
         session when not is_nil(session) <-
           Proxy.lookup_session(opts.state_pid, token),
         body when is_map(body) <- conn.body_params do
      request_ctx = request_context(session, opts)
      budget = budget_status(opts, session, request_ctx)

      cond do
        global_exhausted?(opts, request_ctx) ->
          # Operator-wide daily ceiling reached — block EVERY conversation (cost-DoS backstop),
          # before the per-conversation check. Same delivery/SSE shape as a per-conv block.
          global_exhausted_response(
            conn,
            session,
            request_ctx,
            opts,
            streaming?(body) and Map.get(opts, :allow_streaming, false)
          )

        request_quota_exhausted?(opts, budget) ->
          # Per-identity operation quota. This blocks before upstream and before
          # dollar-budget checks.
          request_quota_exhausted_response(
            conn,
            session,
            request_ctx,
            budget,
            opts,
            streaming?(body) and Map.get(opts, :allow_streaming, false)
          )

        exhausted?(budget) ->
          # Only render an SSE budget body when streaming was REQUESTED *and* the gate is
          # on; otherwise the buffered JSON body (byte-identical to before).
          budget_exhausted_response(
            conn,
            session,
            request_ctx,
            budget,
            opts,
            streaming?(body) and Map.get(opts, :allow_streaming, false)
          )

        streaming?(body) and Map.get(opts, :allow_streaming, false) ->
          # Gated SSE streaming path (Task 7). Bypasses call_upstream/call_with_retry
          # entirely — a mid-stream retry would double-bill + garble the stream.
          bump_metric(opts, "llm_proxy_requests")
          bump_metric(opts, "llm_proxy_stream")
          stream_upstream(conn, body, opts, request_ctx, %{session: session, budget: budget})

        true ->
          bump_metric(opts, "llm_proxy_requests")

          # Buffered path (Task 3 block) — but if streaming was REQUESTED while the
          # gate is off, force stream:false so proxy and upstream agree on mode, and
          # drop stream_options along with it — OpenAI-strict backends 400 on
          # "stream_options can only be defined when stream is true". A genuine
          # non-stream request gains no stream key and keeps stream_options (if any)
          # untouched; the only other outgoing mutations are call_upstream's "session"
          # put + mark_prompt_cache's breakpoint marking (system + last message) —
          # everything else is forwarded untouched.
          buffered_body =
            if streaming?(body) do
              body |> Map.put("stream", false) |> Map.delete("stream_options")
            else
              body
            end

          try do
            {:ok, upstream_status, upstream_body, latency_ms, discarded_attempts} =
              call_upstream(buffered_body, opts, request_ctx)

            # Discarded blank attempts consumed real tokens: record them (status
            # "empty_retry") and advance the spend BEFORE pricing the final answer.
            spent_after_discards =
              record_discarded_attempts(
                opts,
                session,
                request_ctx,
                conn.body_params,
                budget.spent_usd || Decimal.new("0"),
                discarded_attempts
              )

            budget = Map.put(budget, :spent_usd, spent_after_discards)

            respond_upstream(
              conn,
              upstream_status,
              upstream_body,
              latency_ms,
              session,
              request_ctx,
              budget,
              opts
            )
          rescue
            e ->
              Logger.error(
                sanitize_log(
                  "llm_proxy: internal error handling upstream response: " <>
                    inspect(e.__struct__)
                )
              )

              bump_metric(opts, "llm_proxy_internal_error")

              json(conn, 502, %{
                error: %{
                  message: "proxy internal error",
                  type: "proxy_error",
                  code: "proxy_internal"
                }
              })
          end
      end
    else
      :missing_bearer ->
        json(conn, 401, %{
          error: %{message: "missing bearer token", type: "auth", code: "unauthorized"}
        })

      nil ->
        json(conn, 401, %{
          error: %{message: "unknown bearer token", type: "auth", code: "unauthorized"}
        })

      _ ->
        json(conn, 400, %{
          error: %{
            message: "request body must be a JSON object",
            type: "invalid_request",
            code: "invalid_json"
          }
        })
    end
  end

  post "/v1/compact" do
    # Async context seal (subzeroclaw → router /v1/compact). The seal is a REAL
    # upstream LLM call on the operator's key, so it passes the same three gates as
    # a chat call, and it is priced like one when the upstream response carries the
    # additive "usage"/"x_router" keys (see compact_record/4); a legacy router that
    # returns only {messages, compacted} still records the $0 row (model "compact").
    # Either way the row advances the per-conversation request quota, so a compact
    # loop is never free. The response body passes through verbatim — the agent's
    # splice step reads only "messages", so the extra keys are invisible to it.
    # Block responses are plain JSON (no sender delivery): the agent's splice step
    # finds no "messages" key and simply skips — compaction degrades silently.
    opts = conn.private.router_opts

    with {:ok, token} <- bearer(conn),
         session when not is_nil(session) <-
           Proxy.lookup_session(opts.state_pid, token),
         body when is_map(body) <- conn.body_params do
      request_ctx = request_context(session, opts)
      budget = budget_status(opts, session, request_ctx)

      cond do
        global_exhausted?(opts, request_ctx) ->
          bump_metric(opts, "llm_proxy_compact_block")

          json(conn, 429, %{
            error: %{
              message: "operator daily budget exhausted",
              type: "budget",
              code: "global_budget_exhausted"
            }
          })

        request_quota_exhausted?(opts, budget) ->
          bump_metric(opts, "llm_proxy_compact_block")

          json(conn, 429, %{
            error: %{
              message: "daily request limit reached",
              type: "budget",
              code: "request_quota_exhausted"
            }
          })

        exhausted?(budget) ->
          bump_metric(opts, "llm_proxy_compact_block")

          json(conn, 429, %{
            error: %{
              message: "daily budget exhausted",
              type: "budget",
              code: "budget_exhausted"
            }
          })

        true ->
          bump_metric(opts, "llm_proxy_compact")
          {status, resp} = compact_upstream(body, opts, request_ctx)

          if status not in 200..299 do
            # Distinct from llm_proxy_compact_block: the gates passed but the
            # upstream seal itself failed.
            bump_metric(opts, "llm_proxy_compact_error")
          end

          # status "ok" on success is deliberate: the store's request-quota SQL
          # only counts status='ok' rows (CASE WHEN status = 'ok'), and a seal
          # must burn quota. model "compact" keeps it distinguishable in the
          # ledger; failures record as "compact_error" (visible, quota-free —
          # same treatment as chat upstream errors).
          record_budget_call(opts, session, request_ctx, compact_record(status, resp, budget, opts))

          json(conn, status, resp)
      end
    else
      :missing_bearer ->
        json(conn, 401, %{
          error: %{message: "missing bearer token", type: "auth", code: "unauthorized"}
        })

      nil ->
        json(conn, 401, %{
          error: %{message: "unknown bearer token", type: "auth", code: "unauthorized"}
        })

      _ ->
        json(conn, 400, %{
          error: %{
            message: "request body must be a JSON object",
            type: "invalid_request",
            code: "invalid_json"
          }
        })
    end
  end

  match _ do
    json(conn, 404, %{error: %{message: "not found", type: "not_found", code: "not_found"}})
  end

  @impl Plug
  # Secret-wrap the upstream key HERE too (not only in the object init): a host
  # or test that builds plug opts directly must never leak the raw key through
  # inspect/crash reports (mm hardening; wrap is idempotent).
  def init(opts) do
    opts
    |> Map.new()
    |> Map.update(:upstream_api_key, nil, &Genswarms.LlmProxy.Secret.wrap/1)
    |> normalize_timeout()
  end

  # Accept the mm-lineage :upstream_timeout_ms knob on plug opts too (converted
  # once here; the transport reads seconds).
  defp normalize_timeout(%{upstream_timeout_s: _} = opts), do: opts

  defp normalize_timeout(%{upstream_timeout_ms: ms} = opts) when is_integer(ms) and ms > 0,
    do: Map.put(opts, :upstream_timeout_s, max(div(ms, 1000), 1))

  defp normalize_timeout(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    opts =
      opts
      |> Map.put_new(:store_mod, nil)
      |> Map.put_new(:clock, &DateTime.utc_now/0)
      |> Map.put_new(:default_daily_limit, Proxy.default_daily_limit())
      |> Map.put_new(:swarm_name, "swarm")
      |> Map.put_new(:sender, :sender)
      |> Map.put_new(:deliver_fn, &Genswarms.Objects.ObjectServer.deliver_message/4)
      |> Map.put_new(:metrics, :metrics)
      # :provider + :prices are read on the hot path (respond_upstream / x_router / cost)
      # but only init/1 supplied them — a direct ProxyPlug.call with a bare opts map would
      # otherwise hit a missing-:prices KeyError (masked to 502) or a missing-:provider raise.
      |> Map.put_new(:provider, "openai-compatible")
      |> Map.put_new(:prices, %{})
      |> Map.put_new(:margin_pct, 0)
      |> Map.put_new(:global_daily_limit, Decimal.new("0"))
      |> Map.put_new(:daily_request_limit, 0)
      |> Map.put_new(:upstream_timeout_s, 120)
      |> Map.put_new(:connect_timeout_s, 10)
      |> Map.put_new(:stream_timeout_s, 300)
      |> Map.put_new(:allow_streaming, false)
      |> Map.put_new(:prompt_cache, true)
      |> Map.put_new(:max_retries, 1)
      |> Map.put_new(:empty_completion_retries, 0)
      |> Map.update!(:daily_request_limit, &Proxy.request_limit/1)

    conn
    |> Plug.Conn.put_private(:router_opts, opts)
    |> super(opts)
  end

  # Fire-and-forget metric bump. No-op if opts is missing swarm_name/metrics/deliver_fn.
  # Must never affect a request: swallows both rescue and catch.
  @doc false
  def bump_metric(%{swarm_name: sw, metrics: metrics, deliver_fn: deliver}, key)
      when is_binary(sw) and not is_nil(metrics) and is_function(deliver) do
    try do
      deliver.(sw, metrics, :llm_proxy, Jason.encode!(%{action: "bump", key: key}))
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  def bump_metric(_opts, _key), do: :ok

  # Display story event (host event canvas). The wire is THIS app's OWN config
  # key — the proxy never reads another package's app env (dependency
  # constraint); the default matches the genswarms display convention, so a
  # host that overrides both app envs (or neither) gets one merged stream.
  # Must never affect a request: swallows everything, like bump_metric.
  @doc false
  def emit_display(meta) when is_map(meta) do
    wire = Application.get_env(:genswarms_llm_proxy, :display_wire, [:genswarms, :display])

    try do
      :telemetry.execute(wire, %{}, meta)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  # Structured, durable quota metric (mm contract): if the host store exports
  # bump_metric/3, record the block with tags — coexists with the flat object
  # counter above (wingston stores without bump_metric/3 no-op here).
  defp bump_quota_metric(opts, session, reason) do
    store_mod = Map.get(opts, :store_mod)

    if is_atom(store_mod) and not is_nil(store_mod) and Code.ensure_loaded?(store_mod) and
         function_exported?(store_mod, :bump_metric, 3) do
      store_mod.bump_metric(
        "llm_proxy.quota_blocked",
        %{reason: reason, kind: session.kind, provider: opts.provider},
        1
      )
    end

    :ok
  rescue
    e ->
      Logger.warning("llm_proxy: quota metric store failed: " <> Exception.message(e))
      :ok
  catch
    _, _ -> :ok
  end

  # Replaces the literal `key` (if binary and non-empty) and sk-…/Bearer …-shaped
  # substrings with [REDACTED]. Protects upstream secrets from leaking into logs.
  @doc false
  def scrub_secret(msg, key) when is_binary(msg) do
    # reveal/1 tolerates a %Secret{} (production), a raw binary (tests), or nil,
    # so the literal-key replace below works whether callers pass the wrapper or
    # a bare string. All scrub call sites are therefore unchanged.
    key = Genswarms.LlmProxy.Secret.reveal(key)

    msg
    |> then(fn m ->
      if is_binary(key) and key != "", do: String.replace(m, key, "[REDACTED]"), else: m
    end)
    |> String.replace(~r/(sk-[A-Za-z0-9_-]{20,}|Bearer\s+[A-Za-z0-9._-]{6,})/, "[REDACTED]")
  end

  def scrub_secret(msg, _key), do: inspect(msg)

  # Strips CR/LF/C0 control characters (blocks journal log-forgery, CWE-117)
  # and bounds length to ≤ 220 BYTES (a multibyte line can exceed 220 bytes under a
  # grapheme slice; byte_cap/2 trims to a valid UTF-8 boundary ≤ the byte budget).
  @doc false
  def sanitize_log(msg) when is_binary(msg) do
    msg |> String.replace(~r/[\x00-\x1f\x7f]/, " ") |> byte_cap(220)
  end

  def sanitize_log(msg), do: msg |> inspect() |> sanitize_log()

  # Truncate to at most `max` BYTES, backing off up to 3 bytes so the result never splits
  # a multibyte UTF-8 codepoint (binary_part alone could yield an invalid binary).
  defp byte_cap(bin, max) when is_binary(bin) do
    if byte_size(bin) <= max, do: bin, else: bin |> binary_part(0, max) |> trim_to_valid()
  end

  defp trim_to_valid(bin) do
    if String.valid?(bin) or bin == "",
      do: bin,
      else: trim_to_valid(binary_part(bin, 0, byte_size(bin) - 1))
  end

  defp bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" -> {:ok, token}
      _ -> :missing_bearer
    end
  end

  # Exposed @doc false so retry tests can drive this directly without Plug overhead.
  @doc false
  def call_upstream(body, opts, request_ctx) do
    upstream = Map.get(opts, :upstream, &__MODULE__.http_upstream/3)
    body = Map.put(body, "session", request_ctx.session_id)

    # Kill switch (LLM_PROXY_PROMPT_CACHE=0 → prompt_cache: false): the marking's
    # safety on non-Anthropic routes rests on external-router behavior, so ops
    # must be able to disable injection without a code change / redeploy.
    body = if Map.get(opts, :prompt_cache, true), do: mark_prompt_cache(body), else: body

    # No `authorization` entry: http_upstream/3 builds its own auth (the bearer +
    # x-unhardcoded-session ride a 0600 `--config` via write_auth_config) and only
    # reads `x-unhardcoded-session` from this list. Dropping the dead copy keeps the
    # upstream key from being duplicated in-memory across the retry loop (B4).
    headers = [
      {"content-type", "application/json"},
      {"x-unhardcoded-session", request_ctx.session_id}
    ]

    # started is captured before call_with_retry so latency_ms reflects cumulative
    # wall-clock time across all attempts, including backoff sleeps.
    started = System.monotonic_time(:millisecond)

    {result, discarded} =
      call_with_empty_retry(
        upstream,
        body,
        headers,
        opts,
        min(max(Map.get(opts, :max_retries, 1), 0), 3)
      )

    latency_ms = max(System.monotonic_time(:millisecond) - started, 0)

    case result do
      {:ok, status, resp} ->
        {:ok, status, resp, latency_ms, discarded}

      {:error, status, resp} ->
        {:ok, status, resp, latency_ms, discarded}

      {:error, reason} ->
        # No bump here: this 502 flows to respond_upstream's non-2xx arm, which bumps
        # llm_proxy_upstream_error exactly once. Bumping here too double-counted transport
        # failures (genuine 5xx and transport-502 must each count once).
        {:ok, 502, %{"error" => %{"message" => inspect(reason), "code" => "upstream_error"}},
         latency_ms, discarded}
    end
  end

  # Forward a /v1/compact body upstream. Reuses the chat transport (same secret
  # hygiene: bearer + session in a 0600 --config, body in a 0600 tmp file) but
  # targets the sibling /compact endpoint and skips the chat-only mutations —
  # no body "session" injection (CompactRequest is a strict schema) and no
  # prompt-cache marking (the seal deliberately rewrites the aged middle).
  defp compact_upstream(body, opts, request_ctx) do
    upstream = Map.get(opts, :upstream, &__MODULE__.http_upstream/3)

    headers = [
      {"content-type", "application/json"},
      {"x-unhardcoded-session", request_ctx.session_id}
    ]

    opts = Map.put(opts, :upstream_endpoint, compact_endpoint(opts.upstream_endpoint))

    case call_with_retry(
           upstream,
           body,
           headers,
           opts,
           min(max(Map.get(opts, :max_retries, 1), 0), 3)
         ) do
      {:ok, status, resp} ->
        {status, resp}

      {:error, status, resp} when is_integer(status) and is_map(resp) ->
        {status, resp}

      {:error, reason} ->
        {502, %{"error" => %{"message" => inspect(reason), "code" => "upstream_error"}}}
    end
  end

  # Ledger row for the seal, mirroring respond_upstream/8's cost accounting: a
  # NEW router MAY additively attach OpenAI-shape "usage" and the chat-shaped
  # "x_router" to /v1/compact responses (on every response that followed a
  # billable upstream call, including {"compacted": false}); when present the
  # seal is priced through the same money chokepoint as a chat call
  # (executed_cost_usd — two-spends: user charge + provider cost), so the seal
  # advances the per-conversation budget and the global ceiling. ABSENCE of
  # both keys = legacy router = the same $0 row as before (compat: never crash,
  # never invent cost). model "compact" and the status semantics are preserved:
  # "ok" burns the request quota, "compact_error" stays quota-free — but a
  # compact_error row still records any cost a new router billed for the
  # failed seal.
  defp compact_record(status, resp, budget, opts) do
    usage = normalize_usage_counts(Map.get(resp, "usage") || %{})
    upstream_router = upstream_router(Map.get(resp, "x_router"))

    # Legacy shape (NEITHER additive key present) skips the chokepoint entirely:
    # the $0 row is the contract's expected compat arm, not a missing cost
    # signal. Routing it through executed_cost_usd would bump
    # llm_proxy_provider_cost_unknown once per seal, and that counter's standing
    # meaning is "billable chat call whose router omitted a cost" (it feeds the
    # router-cost-signal investigation). A NEW router that attaches usage or
    # x_router but omits cost_usd still goes through the chokepoint — there the
    # bump is a genuinely missing cost on a priced seal.
    legacy? = not (Map.has_key?(resp, "usage") or Map.has_key?(resp, "x_router"))

    row_status = if(status in 200..299, do: "ok", else: "compact_error")

    if legacy? do
      # The pre-0.2.18 record, byte-identical: a minimal map with NO accounting
      # labels, so durable stores keep stamping their own legacy defaults
      # ('legacy' provider_cost_state etc.) — a $0 seal row from an old router
      # must be indistinguishable from one written by 0.2.17.
      %{request_id: request_id(), model: "compact", status: row_status}
    else
      {cost, invalid?} = executed_cost_usd(usage, opts, upstream_router, budget.spent_usd)
      if invalid?, do: bump_metric(opts, "llm_proxy_cost_invalid")
      {cached_tokens, non_cached_tokens} = Proxy.cache_split(usage, upstream_router)

      %{
        request_id: request_id(),
        model: "compact",
        status: row_status,
        prompt_tokens: usage["prompt_tokens"],
        completion_tokens: usage["completion_tokens"],
        total_tokens: usage["total_tokens"],
        cached_tokens: cached_tokens,
        non_cached_tokens: non_cached_tokens,
        cost_usd: cost,
        provider_cost_usd: provider_cost_usd(upstream_router),
        provider_cost_state: provider_cost_state(upstream_router),
        charge_basis: charge_basis(opts, upstream_router),
        pricing_version: Map.get(opts, :pricing_version, "cost_plus_v1"),
        provider: Map.get(upstream_router, "provider")
      }
    end
  end

  # The upstream /v1/compact URL, derived from the configured chat endpoint —
  # the same derivation subzeroclaw applies to ITS endpoint (compact_url), so
  # the proxy is transparent: agent hits <proxy>/v1/compact, proxy hits
  # <upstream>/v1/compact. Exposed @doc false for tests.
  @doc false
  def compact_endpoint(chat_endpoint) do
    case String.split(chat_endpoint, "/chat/completions", parts: 2) do
      [base, _] -> base <> "/compact"
      [whole] -> String.trim_trailing(whole, "/") <> "/compact"
    end
  end

  # Marks the system message (if any) and the LAST message with an Anthropic
  # `cache_control: {"type":"ephemeral"}` breakpoint before forwarding upstream.
  #
  # Anthropic only caches a prompt prefix when the request carries an explicit
  # breakpoint — unlike OpenAI, which caches automatically. This proxy previously
  # ported only the *measurement* half of caching (migration 015, `cache_split/2`)
  # and never this injection half, so every Anthropic-served call got 0% cache,
  # forfeiting up to ~90% of the cost that call would otherwise have avoided.
  # Ported from the sibling micro-markets project's PR #256, which hit and fixed
  # the identical gap.
  #
  # Safe no-op elsewhere: OpenRouter-style pass-through routers ignore unknown
  # per-block keys for non-Anthropic providers, so this never affects an
  # OpenAI/other-served call's request cost. (It DOES change the content shape:
  # string content becomes a one-block content-parts array — a valid
  # OpenAI-compatible form.) The streaming path is deliberately NOT marked (it
  # is gated OFF in production; see stream_upstream/5).
  # Exposed @doc false so tests can drive the multi-message/guard cases directly.
  @doc false
  def mark_prompt_cache(%{"messages" => messages} = body)
      when is_list(messages) and messages != [] do
    # A cache-aware client that already placed its own breakpoints knows better
    # than the proxy: injecting more could exceed Anthropic's 4-breakpoint limit
    # (400 on a previously-working request). Defer entirely when any are present.
    if client_marked?(messages) do
      body
    else
      last_idx = length(messages) - 1
      sys_idx = Enum.find_index(messages, &(is_map(&1) and Map.get(&1, "role") == "system"))

      marked =
        messages
        |> Enum.with_index()
        |> Enum.map(fn {msg, i} ->
          if i == sys_idx or i == last_idx, do: put_cache_control(msg), else: msg
        end)

      Map.put(body, "messages", marked)
    end
  end

  def mark_prompt_cache(body), do: body

  defp client_marked?(messages) do
    Enum.any?(messages, fn
      %{"content" => blocks} when is_list(blocks) ->
        Enum.any?(blocks, &(is_map(&1) and Map.has_key?(&1, "cache_control")))

      _ ->
        false
    end)
  end

  defp put_cache_control(%{"content" => content} = msg)
       when is_binary(content) and content != "" do
    Map.put(msg, "content", [
      %{"type" => "text", "text" => content, "cache_control" => %{"type" => "ephemeral"}}
    ])
  end

  defp put_cache_control(%{"content" => [_ | _] = blocks} = msg) do
    Map.put(
      msg,
      "content",
      List.update_at(blocks, -1, fn
        # Anthropic rejects cache_control on EMPTY text blocks — mirror the
        # string clause's non-empty guard.
        %{"text" => ""} = block -> block
        block when is_map(block) -> Map.put(block, "cache_control", %{"type" => "ephemeral"})
        block -> block
      end)
    )
  end

  defp put_cache_control(msg), do: msg

  # Retry ONLY connect-phase curl failures (6 = couldn't resolve host, 7 = couldn't
  # connect) — the request never reached the server, so re-sending cannot double-bill.
  # A timeout-after-send (28), recv error (56), or partial transfer (18) is NOT retried
  # (the upstream may have already processed/billed it). Genuine 5xx arrives as
  # {:ok, 5xx, _} and is never retried. Short jittered backoff between attempts.
  # Empty-completion retry (ported from the micro-markets proxy — the mm-only
  # feature the unified package must keep): a 2xx whose assistant message has
  # blank content and NO tool call is retried up to opts.empty_completion_retries
  # times (default 0 — wingston-lineage behavior unchanged unless opted in).
  defp call_with_empty_retry(upstream, body, headers, opts, transport_retries) do
    empties = min(max(Map.get(opts, :empty_completion_retries, 0), 0), 3)
    do_empty_retry(upstream, body, headers, opts, transport_retries, empties, [])
  end

  # Returns {result, discarded}: every blank 2xx we retried past is kept —
  # its tokens were consumed upstream, so the caller RECORDS them (status
  # "empty_retry") against the budget before pricing the final answer.
  defp do_empty_retry(upstream, body, headers, opts, transport_retries, empties_left, discarded) do
    result = call_with_retry(upstream, body, headers, opts, transport_retries)

    case result do
      {:ok, status, resp} when status in 200..299 ->
        if empties_left > 0 and empty_assistant_completion?(resp) do
          bump_metric(opts, "llm_proxy_empty_completion_retry")

          do_empty_retry(upstream, body, headers, opts, transport_retries, empties_left - 1, [
            %{status: status, body: resp} | discarded
          ])
        else
          {result, Enum.reverse(discarded)}
        end

      other ->
        {other, Enum.reverse(discarded)}
    end
  end

  # Ported with the empty-retry feature from micro-markets: every discarded
  # blank attempt is a REAL upstream call — bill it (status "empty_retry").
  defp record_discarded_attempts(_opts, _session, _request_ctx, _request, spent, []), do: spent
  # Hostile/garbage upstream token counts ("many", lists, maps) normalize to 0
  # BEFORE any consumer — cost, x_router, and the durable record all see ints
  # (mm hardening; a poisoned count must never crash a host store).
  defp normalize_usage_counts(usage) when is_map(usage) do
    Map.merge(usage, %{
      "prompt_tokens" => nonneg_int(Map.get(usage, "prompt_tokens")),
      "completion_tokens" => nonneg_int(Map.get(usage, "completion_tokens")),
      "total_tokens" => nonneg_int(Map.get(usage, "total_tokens"))
    })
  end

  defp normalize_usage_counts(_),
    do: %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}

  defp nonneg_int(v) when is_integer(v) and v >= 0, do: v
  defp nonneg_int(_), do: 0

  defp record_discarded_attempts(opts, session, request_ctx, request, spent_before, discarded) do
    Enum.reduce(discarded, spent_before, fn %{body: body}, spent ->
      usage = normalize_usage_counts(Map.get(body, "usage") || %{})
      upstream_router = upstream_router(Map.get(body, "x_router"))
      model = served_model(upstream_router, body, request)
      {cost, _invalid?} = executed_cost_usd(usage, opts, upstream_router, spent)
      {cached_tokens, non_cached_tokens} = Proxy.cache_split(usage, upstream_router)

      record_budget_call(opts, session, request_ctx, %{
        request_id: request_id(),
        model: model,
        status: "empty_retry",
        prompt_tokens: usage["prompt_tokens"],
        completion_tokens: usage["completion_tokens"],
        total_tokens: usage["total_tokens"],
        cached_tokens: cached_tokens,
        non_cached_tokens: non_cached_tokens,
        cost_usd: cost,
        provider_cost_usd: provider_cost_usd(upstream_router),
        provider_cost_state: provider_cost_state(upstream_router),
        charge_basis: charge_basis(opts, upstream_router),
        pricing_version: Map.get(opts, :pricing_version, "cost_plus_v1"),
        provider: Map.get(upstream_router, "provider")
      })

      Decimal.add(spent, cost)
    end)
  end

  defp empty_assistant_completion?(%{"choices" => [first | _]}) when is_map(first) do
    message = Map.get(first, "message")

    is_map(message) and blank_content?(Map.get(message, "content")) and
      not has_tool_call?(message)
  end

  defp empty_assistant_completion?(_), do: false

  defp blank_content?(nil), do: true
  defp blank_content?(content) when is_binary(content), do: String.trim(content) == ""
  defp blank_content?(_), do: false

  defp has_tool_call?(%{"tool_calls" => calls}) when is_list(calls), do: calls != []
  defp has_tool_call?(%{"function_call" => call}) when is_map(call), do: map_size(call) > 0
  defp has_tool_call?(_), do: false

  defp call_with_retry(upstream, body, headers, opts, retries_left) do
    case upstream.(body, headers, opts) do
      {:error, {:curl, code}} when code in [6, 7] and retries_left > 0 ->
        bump_metric(opts, "llm_proxy_upstream_retry")
        Process.sleep(100 + :rand.uniform(150))
        call_with_retry(upstream, body, headers, opts, retries_left - 1)

      other ->
        other
    end
  end

  # Curl-based upstream call. This OTP build has no usable `:httpc` (`:http_util`
  # undefined), so we shell out to curl exactly like `objects/memory.ex` does.
  #
  # Return contract matches the original `:httpc` version that `respond_upstream/8`
  # consumes: `{:ok, status, body_map}` on a decoded JSON object (status is the REAL
  # HTTP code — so a 429/500 with curl exit 0 is NOT mistaken for 200),
  # `{:error, 502, decode_error_map}` when the body isn't a JSON object, and
  # `{:error, reason}` for a transport/parse failure. `respond_upstream` branches on
  # `status in 200..299` and reads the parsed body's `x_router`; it never reads
  # response headers, so we deliberately discard them.
  #
  # Secrets stay OUT of argv (world-readable via `ps`): the Authorization bearer and
  # the unhardcoded-session identity go in a 0600 curl `--config` file; the request
  # body (conversation content) goes in a 0600 tmp file read via `--data-binary @path`.
  # Both files are deleted in `after` blocks, the key-bearing config in the outermost
  # one so it never outlives the call.
  def http_upstream(body, headers, opts) do
    payload = Jason.encode!(body)
    session_id = header_value(headers, "x-unhardcoded-session")
    cfg = write_auth_config(opts.upstream_api_key, session_id)

    try do
      body_path = write_private_tmp("genswarms-llm-proxy-body", payload)

      try do
        args = curl_args(body_path, opts.upstream_endpoint, cfg, opts)

        case System.cmd(Genswarms.LlmProxy.Curl.bin!(), args, stderr_to_stdout: false) do
          {out, 0} ->
            case Genswarms.LlmProxy.Curl.parse_response(out) do
              {:ok, status, resp_body} ->
                case decode_upstream_body(resp_body) do
                  {:ok, decoded} -> {:ok, status, decoded}
                  {:error, reason} -> {:error, 502, upstream_decode_error(reason)}
                end

              {:error, reason} ->
                {:error, reason}
            end

          {_out, code} ->
            {:error, {:curl, code}}
        end
      after
        File.rm(body_path)
      end
    after
      File.rm(cfg)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # curl args with NO secret in argv: `Content-Type` is harmless and stays inline; the
  # Authorization + x-unhardcoded-session headers come from the private `--config` file,
  # the body from the private 0600 file read via `@path`. `--max-time` (default 120s) because
  # an agent turn fans out several calls and Genswarms.LlmProxy.Curl's 10s default is too short. The
  # `-H "Expect:"` suppresses curl's automatic 100-continue handshake (every LLM body is
  # >1KB), keeping `--dump-header` output to a single status line and avoiding a wasted
  # round-trip. `--connect-timeout` (default 10s) fails fast against a dead host.
  # Exposed @doc false so tests can assert neither key nor session_id ever appears in argv.
  @doc false
  def curl_args(body_path, endpoint, cfg_path, opts) do
    [
      "-s",
      "-w",
      "\n%{http_code}",
      "--connect-timeout",
      to_string(Map.get(opts, :connect_timeout_s, 10)),
      "--max-time",
      to_string(Map.get(opts, :upstream_timeout_s, 120)),
      "-H",
      "Expect:",
      "-H",
      "Content-Type: application/json",
      "--config",
      cfg_path,
      "--data-binary",
      "@" <> body_path,
      endpoint
    ]
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, "", fn {k, v} -> if k == name, do: v end)
  end

  # Returns the two curl `header = "..."` lines that carry the bearer token and the
  # unhardcoded-session identity. Pure + exposed @doc false so tests can assert both
  # secrets appear in the config CONTENT and never in argv.
  @doc false
  def auth_config(api_key, session_id) do
    # Unwrap the opaque key here (the one place curl actually needs the real
    # bearer). reveal/1 is tolerant: a %Secret{} (production), a raw binary
    # (tests), or nil all pass through. The 0600 --config file protects it on disk.
    api_key = Genswarms.LlmProxy.Secret.reveal(api_key)

    ~s(header = "Authorization: Bearer #{api_key}"\n) <>
      ~s(header = "x-unhardcoded-session: #{session_id}"\n)
  end

  # Write the bearer header AND the unhardcoded-session header to a fresh 0600 curl
  # config file (curl reads `header = "..."` lines as `-H` options).
  defp write_auth_config(api_key, session_id) do
    write_private_tmp("genswarms-llm-proxy", auth_config(api_key, session_id))
  end

  # Create + chmod 0600 BEFORE writing, so the content is never in a world-readable
  # file even momentarily. Random (not sequential) filename to dodge symlink races.
  # Exposed @doc false so tests can stat the resulting file's mode.
  @doc false
  def write_private_tmp(prefix, content) do
    rand = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{rand}.conf")
    File.touch!(path)
    File.chmod!(path, 0o600)
    File.write!(path, content)
    path
  end

  defp decode_upstream_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:error, :non_object_json}
      {:error, _} -> {:error, :non_json}
    end
  end

  defp upstream_decode_error(:non_object_json) do
    upstream_decode_error("upstream returned non-object JSON")
  end

  defp upstream_decode_error(:non_json) do
    upstream_decode_error("upstream returned non-JSON response")
  end

  defp upstream_decode_error(message) do
    %{
      "error" => %{
        "message" => message,
        "type" => "upstream_error",
        "code" => "upstream_invalid_json"
      }
    }
  end

  defp request_context(session, opts) do
    day = utc_day(opts.clock.())
    session_id = Proxy.upstream_session_id(session.budget_identity, day)

    %{
      day: day,
      session_id: session_id,
      reset_at: "#{Date.to_iso8601(Date.add(day, 1))} 00:00 UTC"
    }
  end

  defp utc_day(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp utc_day(%NaiveDateTime{} = dt), do: NaiveDateTime.to_date(dt)
  defp utc_day(%Date{} = day), do: day

  defp budget_status(opts, session, request_ctx) do
    status =
      try do
        opts.store_mod.llm_budget_status(
          session.budget_identity,
          request_ctx.day,
          request_ctx.session_id,
          session.daily_limit_usd || opts.default_daily_limit
        )
      rescue
        e ->
          Logger.error(
            sanitize_log(
              "llm_proxy: budget status store RAISED: " <>
                scrub_secret(Exception.message(e), opts[:upstream_api_key])
            )
          )

          bump_metric(opts, "llm_proxy_budget_degraded")
          nil
      end

    if is_nil(status) do
      Logger.error(
        "llm_proxy: budget status DOWN (nil return) — failing OPEN to in-memory mirror; spend not durable across restart"
      )

      bump_metric(opts, "llm_proxy_budget_degraded")
      # one display event per incident (the rescue path above also lands here)
      emit_display(%{
        kind: :llm_proxy_degraded,
        cid: session.conversation_id,
        path: "budget_status"
      })
    end

    status ||
      Proxy.fallback_budget_status(
        opts.state_pid,
        session,
        request_ctx.day,
        request_ctx.session_id,
        session.daily_limit_usd || opts.default_daily_limit
      )
  end

  defp exhausted?(%{spent_usd: spent, limit_usd: limit}) do
    Decimal.compare(spent || Decimal.new("0"), limit || Proxy.default_daily_limit()) != :lt
  end

  defp request_quota_exhausted?(opts, budget) do
    limit = request_quota_limit(opts)
    limit > 0 and request_count(Map.get(budget, :requests, 0)) >= limit
  end

  defp request_quota_limit(opts), do: Proxy.request_limit(Map.get(opts, :daily_request_limit, 0))

  defp request_count(value) when is_integer(value), do: max(value, 0)

  defp request_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> max(n, 0)
      _ -> 0
    end
  end

  defp request_count(_), do: 0

  # Operator-wide ceiling: disabled when global_daily_limit <= 0. Otherwise blocks once the
  # day's GLOBAL spend reaches the limit. Spend = max(durable PG SUM, in-memory accumulator)
  # so a Postgres outage (which makes the per-conversation budget fail open) can't lift the
  # global cap below what this process has already metered.
  defp global_exhausted?(opts, request_ctx) do
    limit = Map.get(opts, :global_daily_limit, Decimal.new("0"))

    Decimal.compare(limit, 0) == :gt and
      Decimal.compare(global_spent(opts, request_ctx.day), limit) != :lt
  end

  # mm vocabulary: the global block carries the ceiling's numbers in x_router.global.
  defp global_status(opts, request_ctx) do
    %{
      spent_usd: global_spent(opts, request_ctx.day),
      limit_usd: Map.get(opts, :global_daily_limit, Decimal.new("0"))
    }
  end

  defp global_spent(opts, day) do
    pg = global_spent_pg(opts, day)
    inmem = Proxy.global_spent_inmem(opts.state_pid, day)
    if Decimal.compare(pg, inmem) == :gt, do: pg, else: inmem
  end

  # Durable cross-conversation SUM(spent_usd) for the day; 0 when the store is down/disabled
  # (the in-memory accumulator still enforces within this process).
  defp global_spent_pg(opts, day) do
    case opts.store_mod.llm_usage_today(day) do
      %{spent_usd: %Decimal{} = s} -> s
      _ -> Decimal.new("0")
    end
  rescue
    _ -> Decimal.new("0")
  end

  defp budget_exhausted_response(conn, session, request_ctx, budget, opts, streaming?) do
    bump_quota_metric(opts, session, "budget_exhausted")
    notice = budget_notice(request_ctx, budget)

    msg =
      Jason.encode!(%{
        action: "slot_reply",
        slot: session.slot,
        content: notice
      })

    # Deterministic Telegram delivery + block metrics are mode-independent; only the
    # HTTP response body differs (SSE chunk vs buffered JSON).
    if Proxy.notice_once?(opts.state_pid, session.budget_identity, request_ctx.day) do
      opts.deliver_fn.(opts.swarm_name, opts.sender, :llm_proxy, msg)
      bump_metric(opts, "llm_proxy_budget_block_notified")
    end

    bump_metric(opts, "llm_proxy_budget_block")
    emit_display(%{kind: :llm_proxy_block, cid: session.conversation_id, reason: "budget"})

    if streaming? do
      budget_exhausted_sse(conn, request_ctx)
    else
      budget_exhausted_json(conn, request_ctx, budget, opts)
    end
  end

  defp request_quota_exhausted_response(conn, session, request_ctx, budget, opts, streaming?) do
    bump_quota_metric(opts, session, "request_quota_exhausted")
    limit = request_quota_limit(opts)
    notice = request_quota_notice(request_ctx, limit)

    msg =
      Jason.encode!(%{
        action: "slot_reply",
        slot: session.slot,
        content: notice
      })

    if Proxy.notice_once?(opts.state_pid, session.budget_identity, request_ctx.day) do
      opts.deliver_fn.(opts.swarm_name, opts.sender, :llm_proxy, msg)
    end

    bump_metric(opts, "llm_proxy_request_quota_block")
    emit_display(%{kind: :llm_proxy_block, cid: session.conversation_id, reason: "request_quota"})

    if streaming? do
      request_quota_exhausted_sse(conn, request_ctx, limit)
    else
      request_quota_exhausted_json(conn, request_ctx, budget, opts, limit)
    end
  end

  @global_notice "⏳ The service daily LLM budget is exhausted. Please try again tomorrow at 00:00 UTC. 🪶"

  # Operator-wide ceiling block. Mirrors budget_exhausted_response: deterministic Telegram
  # notice (once per conversation per UTC day), a durable block metric the operator can ALERT
  # on, an error log, and the synthetic SSE/JSON body — but framed as a service-wide cap.
  defp global_exhausted_response(conn, session, request_ctx, opts, streaming?) do
    msg =
      Jason.encode!(%{action: "slot_reply", slot: session.slot, content: @global_notice})

    if Proxy.notice_once?(opts.state_pid, session.budget_identity, request_ctx.day) do
      opts.deliver_fn.(opts.swarm_name, opts.sender, :llm_proxy, msg)
    end

    bump_metric(opts, "llm_proxy_global_block")
    emit_display(%{kind: :llm_proxy_block, cid: session.conversation_id, reason: "global"})
    bump_quota_metric(opts, session, "global_budget_exhausted")

    Logger.error(
      "llm_proxy: GLOBAL daily budget ceiling reached — blocking all conversations until 00:00 UTC"
    )

    if streaming? do
      budget_exhausted_sse(conn, request_ctx)
    else
      global_exhausted_json(conn, request_ctx, opts, global_status(opts, request_ctx))
    end
  end

  defp global_exhausted_json(conn, request_ctx, opts, global) do
    request_id = request_id()

    json(conn, 200, %{
      "id" => "chatcmpl-#{request_id}",
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => "llm-proxy-budget",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" =>
              "The service-wide daily LLM budget was reached. A deterministic Telegram notice was sent; do not send a separate user reply."
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0},
      "x_router" => %{
        "provider" => opts.provider,
        "served_model" => "llm-proxy-budget",
        "request_id" => request_id,
        "session_id" => request_ctx.session_id,
        "budget_exhausted" => true,
        "global_budget_exhausted" => true,
        "global" => %{
          "spent_usd" => Proxy.decimal_to_json_number(global.spent_usd),
          "limit_usd" => Proxy.decimal_to_json_number(global.limit_usd),
          "reset_at" => request_ctx.reset_at
        },
        "reset_at" => request_ctx.reset_at
      }
    })
  end

  # A streaming caller hit the daily limit: emit a single well-formed
  # `chat.completion.chunk` (model "llm-proxy-budget") then `[DONE]` over a chunked
  # text/event-stream — never the upstream, never a positive cost. A chunk write failure
  # (client already gone) just returns the conn.
  defp budget_exhausted_sse(conn, request_ctx) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    chunk =
      "data: " <>
        Jason.encode!(%{
          "id" => "chatcmpl-#{request_id()}",
          "object" => "chat.completion.chunk",
          "created" => System.system_time(:second),
          "model" => "llm-proxy-budget",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "role" => "assistant",
                "content" =>
                  "The daily LLM limit for this conversation was reached. A deterministic Telegram notice was sent; do not send a separate user reply."
              },
              "finish_reason" => "stop"
            }
          ],
          "x_router" => %{
            "served_model" => "llm-proxy-budget",
            "session_id" => request_ctx.session_id,
            "budget_exhausted" => true
          }
        }) <> "\n\n"

    with {:ok, conn} <- Plug.Conn.chunk(conn, chunk),
         {:ok, conn} <- Plug.Conn.chunk(conn, "data: [DONE]\n\n") do
      conn
    else
      _ -> conn
    end
  end

  defp request_quota_exhausted_sse(conn, request_ctx, limit) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    chunk =
      "data: " <>
        Jason.encode!(%{
          "id" => "chatcmpl-#{request_id()}",
          "object" => "chat.completion.chunk",
          "created" => System.system_time(:second),
          "model" => "llm-proxy-budget",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "role" => "assistant",
                "content" =>
                  "This chat reached today's AI usage limit. A deterministic Telegram notice was sent; do not send a separate user reply."
              },
              "finish_reason" => "stop"
            }
          ],
          "x_router" => %{
            "served_model" => "llm-proxy-budget",
            "session_id" => request_ctx.session_id,
            "request_quota_exhausted" => true,
            "request_limit" => limit
          }
        }) <> "\n\n"

    with {:ok, conn} <- Plug.Conn.chunk(conn, chunk),
         {:ok, conn} <- Plug.Conn.chunk(conn, "data: [DONE]\n\n") do
      conn
    else
      _ -> conn
    end
  end

  defp budget_exhausted_json(conn, request_ctx, budget, opts) do
    request_id = request_id()

    json(conn, 200, %{
      "id" => "chatcmpl-#{request_id}",
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => "llm-proxy-budget",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" =>
              "The daily LLM limit for this conversation was reached. A deterministic Telegram notice was sent; do not send a separate user reply."
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0},
      "x_router" => %{
        "provider" => opts.provider,
        "served_model" => "llm-proxy-budget",
        "request_id" => request_id,
        "session_id" => request_ctx.session_id,
        "budget_exhausted" => true,
        "budget" => %{
          "spent_usd" => Proxy.decimal_to_json_number(budget.spent_usd),
          "limit_usd" => Proxy.decimal_to_json_number(budget.limit_usd),
          "reset_at" => request_ctx.reset_at
        }
      }
    })
  end

  defp request_quota_exhausted_json(conn, request_ctx, budget, opts, limit) do
    request_id = request_id()

    json(conn, 200, %{
      "id" => "chatcmpl-#{request_id}",
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => "llm-proxy-budget",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" =>
              "This chat reached today's AI usage limit. A deterministic Telegram notice was sent; do not send a separate user reply."
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0},
      "x_router" => %{
        "provider" => opts.provider,
        "served_model" => "llm-proxy-budget",
        "request_id" => request_id,
        "session_id" => request_ctx.session_id,
        "request_quota_exhausted" => true,
        "requests" => request_count(Map.get(budget, :requests, 0)),
        "request_quota" => %{
          "requests" => request_count(Map.get(budget, :requests, 0)),
          "limit" => limit,
          "reset_at" => request_ctx.reset_at
        },
        "request_limit" => limit,
        "reset_at" => request_ctx.reset_at
      }
    })
  end

  defp budget_notice(request_ctx, _budget) do
    reset_date = request_ctx.day |> Date.add(1) |> Date.to_iso8601()
    "⏳ This chat reached its daily LLM limit. Try again tomorrow at 00:00 UTC (#{reset_date})."
  end

  defp request_quota_notice(request_ctx, _limit) do
    reset_date = request_ctx.day |> Date.add(1) |> Date.to_iso8601()

    "⏳ This chat reached today's daily LLM request limit. Try again tomorrow at 00:00 UTC (#{reset_date})."
  end

  defp record_budget_call(opts, session, request_ctx, record) do
    store_row =
      try do
        record_llm_call(
          opts.store_mod,
          session.budget_identity,
          request_ctx.day,
          request_ctx.session_id,
          record,
          session.daily_limit_usd || opts.default_daily_limit
        )
      rescue
        e ->
          Logger.warning(
            sanitize_log(
              "llm_proxy: budget event store RAISED: " <>
                scrub_secret(Exception.message(e), opts[:upstream_api_key])
            )
          )

          bump_metric(opts, "llm_proxy_budget_degraded")
          nil
      end

    if is_nil(store_row) do
      Logger.error(
        "llm_proxy: budget event store DOWN (nil return) — usage not persisted to PG (in-memory mirror only)"
      )

      bump_metric(opts, "llm_proxy_budget_degraded")
      # one display event per incident (the rescue path above also lands here)
      emit_display(%{
        kind: :llm_proxy_degraded,
        cid: session.conversation_id,
        path: "usage_store"
      })
    end

    Proxy.record_usage(opts.state_pid, session, request_ctx.day, request_ctx.session_id, record)
    store_row
  end

  defp record_llm_call(store_mod, budget_identity, day, session_id, record, default_limit) do
    if function_exported?(store_mod, :record_llm_call, 5) do
      store_mod.record_llm_call(budget_identity, day, session_id, record, default_limit)
    else
      store_mod.record_llm_call(budget_identity, day, session_id, record)
    end
  end

  defp respond_upstream(conn, status, body, latency_ms, session, request_ctx, budget, opts)
       when status in 200..299 do
    usage = normalize_usage_counts(Map.get(body, "usage") || %{})
    upstream_router = upstream_router(Map.get(body, "x_router"))
    model = served_model(upstream_router, body, conn.body_params)

    {cost, invalid?} =
      executed_cost_usd(usage, opts, upstream_router, budget.spent_usd)

    if invalid?, do: bump_metric(opts, "llm_proxy_cost_invalid")
    request_id = request_id()
    {cached_tokens, non_cached_tokens} = Proxy.cache_split(usage, upstream_router)

    record = %{
      request_id: request_id,
      model: model,
      status: "ok",
      prompt_tokens: usage["prompt_tokens"],
      completion_tokens: usage["completion_tokens"],
      total_tokens: usage["total_tokens"],
      cached_tokens: cached_tokens,
      non_cached_tokens: non_cached_tokens,
      cost_usd: cost,
      provider_cost_usd: provider_cost_usd(upstream_router),
      provider_cost_state: provider_cost_state(upstream_router),
      charge_basis: charge_basis(opts, upstream_router),
      pricing_version: Map.get(opts, :pricing_version, "cost_plus_v1"),
      provider: Map.get(upstream_router, "provider")
    }

    record_budget_call(opts, session, request_ctx, record)

    json(
      conn,
      status,
      Map.put(
        body,
        "x_router",
        x_router(
          opts,
          request_ctx,
          request_id,
          model,
          usage,
          latency_ms,
          cost,
          nil,
          upstream_router
        )
      )
    )
  end

  defp respond_upstream(conn, status, body, latency_ms, session, request_ctx, budget, opts) do
    bump_metric(opts, "llm_proxy_upstream_error")
    err = Map.get(body, "error") || %{}
    code = Map.get(err, "code") || "upstream_error"
    message = scrub_secret(Map.get(err, "message") || "upstream error", opts.upstream_api_key)
    upstream_router = upstream_router(Map.get(body, "x_router"))
    model = served_model(upstream_router, %{}, conn.body_params)
    request_id = request_id()

    # Money the router billed is never invisible — the same invariant
    # compact_record/4 holds for failed seals. A router can bill a partial call
    # and still answer non-2xx; when the error body PROVES a billed call
    # (OpenAI-shape "usage", or a known x_router cost) the row is priced through
    # the executed_cost_usd chokepoint and carries the two-spends accounting, so
    # SUM(cost_usd) never undercounts real spend. Status stays the error code
    # (the request quota is not burned), only the dollar budget advances. A bare
    # error body — the overwhelmingly common 5xx — keeps the minimal legacy row:
    # no invented cost, and no llm_proxy_provider_cost_unknown noise (that
    # counter means "billable call missing router cost", not "upstream errored").
    billed? =
      Map.has_key?(body, "usage") or
        match?({:known, _}, provider_cost_result(upstream_router))

    base_record = %{
      request_id: request_id,
      model: model,
      status: code,
      provider: Map.get(upstream_router, "provider")
    }

    {record, usage, cost} =
      if billed? do
        usage = normalize_usage_counts(Map.get(body, "usage") || %{})
        {cost, invalid?} = executed_cost_usd(usage, opts, upstream_router, budget.spent_usd)
        if invalid?, do: bump_metric(opts, "llm_proxy_cost_invalid")
        {cached_tokens, non_cached_tokens} = Proxy.cache_split(usage, upstream_router)

        record =
          Map.merge(base_record, %{
            prompt_tokens: usage["prompt_tokens"],
            completion_tokens: usage["completion_tokens"],
            total_tokens: usage["total_tokens"],
            cached_tokens: cached_tokens,
            non_cached_tokens: non_cached_tokens,
            cost_usd: cost,
            provider_cost_usd: provider_cost_usd(upstream_router),
            provider_cost_state: provider_cost_state(upstream_router),
            charge_basis: charge_basis(opts, upstream_router),
            pricing_version: Map.get(opts, :pricing_version, "cost_plus_v1")
          })

        {record, usage, cost}
      else
        {base_record, %{}, nil}
      end

    record_budget_call(opts, session, request_ctx, record)

    json(conn, status, %{
      error: %{
        message: bounded(message, 220),
        type: Map.get(err, "type") || "upstream_error",
        code: code
      },
      x_router:
        x_router(
          opts,
          request_ctx,
          request_id,
          model,
          usage,
          latency_ms,
          cost,
          message,
          upstream_router
        )
    })
  end

  defp upstream_router(router) when is_map(router) do
    Map.take(router, [
      "provider",
      "model_family",
      "served_model_id",
      "price_in",
      "price_out",
      "cost_usd",
      "tokens_cached",
      "session_acc",
      "policy_fingerprint",
      "decision_trace",
      "compact"
    ])
  end

  defp upstream_router(_router), do: %{}

  defp served_model(upstream_router, body, request) do
    Map.get(upstream_router, "served_model_id") ||
      Map.get(upstream_router, "served_model") ||
      Map.get(body, "model") ||
      Map.get(request, "model") ||
      ""
  end

  # Returns `{Decimal.t(), invalid? :: boolean}`. The cost chokepoint: every cost the
  # ledger ever sees flows through `Proxy.sanitize_cost/1` here. In :cost_plus mode a
  # valid per-call provider cost is authoritative and receives the configured margin;
  # a known zero, missing, or invalid provider cost falls back to the complete rate
  # card. A cumulative `session_acc.cost_usd` is deliberately NOT used as a per-call
  # basis: subtracting the user's already-marked-up spend mixes units and can silently
  # turn a real provider cost into zero.
  @doc false
  # Public for the two-spends check: this is the money chokepoint.
  def executed_cost_usd(usage, opts, upstream_router, _spent_before) do
    prices = Map.get(opts, :prices) || %{}
    margin_pct = Map.get(opts, :margin_pct, 0)
    rate_card_cost = cost_usd(usage, prices)
    provider_cost = provider_cost_result(upstream_router)

    track_provider_cost(opts, provider_cost)

    raw =
      cond do
        Proxy.pricing_mode(Map.get(opts, :pricing_mode)) == :rate_card_first and
            Proxy.rate_card_complete?(prices) ->
          rate_card_cost

        match?({:known, _}, provider_cost) ->
          {:known, cost} = provider_cost
          cost

        true ->
          rate_card_cost
      end

    raw
    |> Proxy.markup_cost(rate_card_cost, margin_pct)
    |> Proxy.sanitize_cost()
  end

  # A rate card counts as "set" ONLY when BOTH per-Mtok prices are present
  # (0.2.10, micromarkets#450 review). With `or`, a half-configured card —
  # one price env silently dropped by a host's parser — counted as
  # configured: rate_card_first then billed the missing leg at $0 while
  # IGNORING the real router cost (systematic undercharge, ≈$0 on
  # completion-heavy calls). A half card now falls through to the router
  # cost, which never underbills; hosts should additionally reject half
  # cards at boot (wingston#132 does).
  # Preserve provider-cost knownness internally. The current durable schema still
  # stores a Decimal only, so provider_cost_usd/1 maps unknown/invalid to zero for
  # compatibility while explicit metrics retain the distinction. The v4 envelope
  # can migrate this result directly to its planned knownness fields.
  @doc false
  def provider_cost_result(upstream_router) when is_map(upstream_router) do
    case Map.fetch(upstream_router, "cost_usd") do
      :error -> :unknown
      {:ok, nil} -> :unknown
      {:ok, raw} -> classify_provider_cost(raw)
    end
  end

  def provider_cost_result(_), do: :unknown

  defp classify_provider_cost(raw)
       when is_integer(raw) or is_float(raw) or is_binary(raw) or is_struct(raw, Decimal) do
    parsed =
      cond do
        is_struct(raw, Decimal) ->
          {:ok, raw}

        is_integer(raw) ->
          {:ok, Decimal.new(raw)}

        is_float(raw) ->
          {:ok, Decimal.from_float(raw)}

        is_binary(raw) ->
          case Decimal.parse(raw) do
            {value, ""} -> {:ok, value}
            _ -> :error
          end
      end

    case parsed do
      {:ok, value} ->
        cond do
          not Proxy.finite_decimal?(value) ->
            :invalid

          Decimal.compare(value, 0) == :lt ->
            :invalid

          true ->
            case Proxy.sanitize_cost(value) do
              {_cost, true} -> :invalid
              {cost, false} -> {:known, cost}
            end
        end

      :error ->
        :invalid
    end
  rescue
    _ -> :invalid
  end

  defp classify_provider_cost(_), do: :invalid

  @doc false
  def provider_cost_usd(upstream_router) do
    case provider_cost_result(upstream_router) do
      {:known, cost} -> cost
      _ -> Decimal.new(0)
    end
  end

  @doc false
  def provider_cost_state(upstream_router) do
    case provider_cost_result(upstream_router) do
      {:known, cost} -> if Decimal.compare(cost, 0) == :eq, do: "zero", else: "known"
      :unknown -> "missing"
      :invalid -> "invalid"
    end
  end

  @doc false
  def charge_basis(opts, upstream_router) do
    prices = Map.get(opts, :prices) || %{}

    if Proxy.pricing_mode(Map.get(opts, :pricing_mode)) == :rate_card_first and
         Proxy.rate_card_complete?(prices) do
      "rate_card"
    else
      case provider_cost_result(upstream_router) do
        {:known, cost} ->
          if Decimal.compare(cost, 0) == :gt, do: "provider_cost", else: "rate_card"

        _ ->
          "rate_card"
      end
    end
  end

  defp track_provider_cost(_opts, {:known, _cost}), do: :ok

  defp track_provider_cost(opts, :unknown) do
    bump_metric(opts, "llm_proxy_provider_cost_unknown")
  end

  defp track_provider_cost(opts, :invalid) do
    bump_metric(opts, "llm_proxy_provider_cost_invalid")
    bump_metric(opts, "llm_proxy_cost_invalid")
  end

  defp x_router(
         opts,
         request_ctx,
         request_id,
         model,
         usage,
         latency_ms,
         cost,
         error,
         upstream_router
       ) do
    provider_cost =
      case provider_cost_result(upstream_router) do
        {:known, value} -> Proxy.decimal_to_json_number(value)
        _ -> nil
      end

    user_charge = if(cost, do: Proxy.decimal_to_json_number(cost), else: nil)

    Map.merge(upstream_router, %{
      "provider" => Map.get(upstream_router, "provider") || opts.provider,
      "served_model" => model,
      "latency_ms" => latency_ms,
      "prompt_tokens" => usage["prompt_tokens"],
      "completion_tokens" => usage["completion_tokens"],
      "total_tokens" => usage["total_tokens"],
      # cost_usd remains the compatibility user-charge field. The explicit pair
      # prevents consumers from mixing the marked-up charge with provider cost.
      "cost_usd" => user_charge,
      "user_charge_usd" => user_charge,
      "provider_cost_usd" => provider_cost,
      "provider_cost_state" => provider_cost_state(upstream_router),
      "charge_basis" => charge_basis(opts, upstream_router),
      "pricing_version" => Map.get(opts, :pricing_version, "cost_plus_v1"),
      "request_id" => request_id,
      "session_id" => request_ctx.session_id,
      "error" => if(error, do: bounded(error, 220), else: nil)
    })
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Rate-card cost from token counts. The token counts come straight off the upstream
  # `usage` block, so a hostile/malformed upstream can make them a string, float, map, or
  # negative — `Decimal.new/1` RAISES on a non-integer (e.g. "abc" or a float), which would
  # crash the cost path and mask the real response as a 502. `Proxy.decimal/1` coerces every
  # shape safely (integer/float/numeric-string → value, garbage → 0); negatives are floored
  # downstream by `sanitize_cost/1`.
  @doc false
  def cost_usd(usage, prices) do
    prompt = usage["prompt_tokens"]
    completion = usage["completion_tokens"]
    pin = Map.get(prices, :prompt_per_mtok) || Map.get(prices, "prompt_per_mtok") || 0
    pout = Map.get(prices, :completion_per_mtok) || Map.get(prices, "completion_per_mtok") || 0

    prompt_cost =
      prompt
      |> Proxy.decimal()
      |> Decimal.mult(Proxy.decimal(pin))
      |> Decimal.div(Decimal.new(1_000_000))

    completion_cost =
      completion
      |> Proxy.decimal()
      |> Decimal.mult(Proxy.decimal(pout))
      |> Decimal.div(Decimal.new(1_000_000))

    Decimal.add(prompt_cost, completion_cost)
  end

  defp bounded(value, max) do
    value |> to_string() |> String.slice(0, max)
  end

  # ── Streaming transport (Task 7) ─────────────────────────────────────────────
  #
  # Gated OFF by default (`allow_streaming`). When enabled, an SSE `stream:true`
  # request is passed through verbatim via a curl Port (NOT call_upstream — a
  # mid-stream retry would double-bill + garble the stream). Leak-proof: the 0600
  # `--config` carrying the REAL upstream key is removed in the OUTERMOST `after`
  # on EVERY exit; the curl Port is `safe_close`d in an `after`; an outer `rescue`
  # returns a clean 502. Task 8 adds cost accounting / budget-exhausted SSE /
  # include_usage chunk-stripping; Task 7 is transport only.

  # Tolerant: an agent (or a future client) may send stream as a JSON bool, the
  # string "true", or 1. Anything else is treated as non-streaming.
  @doc false
  def streaming?(body), do: Map.get(body, "stream") in [true, "true", 1]

  # Force stream_options.include_usage so the upstream emits a final usage frame
  # (Task 8 bills from it). Preserves any other stream_options the caller set.
  @doc false
  def ensure_stream_usage(body) do
    so =
      case Map.get(body, "stream_options") do
        m when is_map(m) -> m
        _ -> %{}
      end

    Map.put(body, "stream_options", Map.put(so, "include_usage", true))
  end

  defp stream_upstream(conn, body, opts, request_ctx, ctx) do
    forward =
      body
      |> Map.put("session", request_ctx.session_id)
      |> Map.put("stream", true)
      |> ensure_stream_usage()

    # The OUTER try owns the rescue. `cfg` (the REAL upstream key) is written INSIDE it so a
    # raise in write_auth_config itself is caught (clean 502) instead of escaping. cfg is then
    # removed in the immediately-nested `after` — which CAN see cfg (it is bound earlier in the
    # SAME do-block). Note: a `cfg = nil` before the try + `after if cfg` would NOT work — an
    # assignment inside a try's do-block is not visible to that try's own `after` in Elixir.
    try do
      cfg = write_auth_config(opts.upstream_api_key, request_ctx.session_id)

      try do
        body_path = write_private_tmp("genswarms-llm-proxy-body", Jason.encode!(forward))
        hdr_path = write_private_tmp("genswarms-llm-proxy-hdr", "")

        try do
          # `:port_open` seam: tests force a raise to prove leak-proofness.
          port_open = Map.get(opts, :port_open, &default_port_open/2)

          port =
            port_open.(
              Genswarms.LlmProxy.Curl.bin!(),
              stream_curl_args(body_path, opts.upstream_endpoint, cfg, hdr_path, opts)
            )

          try do
            stream_loop(%{
              mode: :sniff,
              buf: "",
              acc: "",
              conn: conn,
              port: port,
              hdr_path: hdr_path,
              opts: opts,
              request_ctx: request_ctx,
              session: ctx.session,
              budget: ctx.budget,
              started: System.monotonic_time(:millisecond),
              exit_code: nil,
              req_body: body,
              # A4: the proxy forces include_usage:true (ensure_stream_usage) for accounting.
              # If the ORIGINAL caller did not explicitly opt in, the injected usage-only
              # chunk is stripped from the CLIENT bytes (still folded into acc). `fwd_rem`
              # holds the trailing partial SSE frame between Port reads when stripping.
              strip_usage?: strip_usage?(body),
              fwd_rem: ""
            })
          after
            safe_close(port)
          end
        after
          File.rm(body_path)
          File.rm(hdr_path)
        end
      after
        # cfg is bound above in this do-block → visible here; removed on EVERY exit.
        File.rm(cfg)
      end
    rescue
      e ->
        Logger.error(sanitize_log("llm_proxy: streaming setup error: " <> inspect(e.__struct__)))
        bump_metric(opts, "llm_proxy_internal_error")

        # Totality: a post-commit finish_stream raise leaves the underlying socket already
        # chunked/sent — re-sending raises AlreadySentError. Skip the send if the conn is
        # already committed, and wrap it so this rescue can NEVER itself raise (the original
        # `conn` is :unset, but the socket may already be sent — the inner rescue covers that).
        if conn.state in [:chunked, :sent, :set_chunked] do
          conn
        else
          try do
            json(conn, 502, %{
              error: %{
                message: "proxy internal error",
                type: "proxy_error",
                code: "proxy_internal"
              }
            })
          rescue
            _ -> conn
          end
        end
    end
  end

  # Port.open WITHOUT :stderr_to_stdout — keeps curl's stderr (progress/errors)
  # OFF the SSE byte stream the client consumes.
  @doc false
  def default_port_open(bin, args) do
    Port.open({:spawn_executable, bin}, [:binary, :exit_status, {:args, args}])
  end

  # Streaming curl args. NO `-w` (status comes from the --dump-header file). Secrets
  # only in `--config` (never argv). `--no-buffer` flushes SSE frames immediately.
  @doc false
  def stream_curl_args(body_path, endpoint, cfg_path, hdr_path, opts) do
    [
      "-sS",
      "--no-buffer",
      "--dump-header",
      hdr_path,
      "--connect-timeout",
      to_string(Map.get(opts, :connect_timeout_s, 10)),
      "--max-time",
      to_string(Map.get(opts, :stream_timeout_s, 300)),
      "-H",
      "Expect:",
      "-H",
      "Content-Type: application/json",
      "--config",
      cfg_path,
      "--data-binary",
      "@" <> body_path,
      endpoint
    ]
  end

  # Terminating clauses ABOVE the receive — a client disconnect (:done) or a sniff/buffer
  # cap abort (:aborted) tears down IMMEDIATELY (no ~75s hang). :aborted is DISTINCT from
  # :done so finish_stream does NOT re-run accounting after stream_abort already sent its 502.
  defp stream_loop(%{mode: :done} = s), do: finish_stream(s)
  defp stream_loop(%{mode: :aborted} = s), do: finish_stream(s)

  defp stream_loop(%{port: port} = s) do
    receive do
      {^port, {:data, data}} ->
        s |> handle_stream_data(data) |> stream_loop()

      {^port, {:exit_status, code}} ->
        finish_stream(%{s | exit_code: code})
    after
      (Map.get(s.opts, :stream_timeout_s, 300) + 15) * 1000 ->
        safe_close(port)

        if s.conn.state in [:chunked, :sent, :set_chunked] do
          finish_stream(%{s | mode: :timeout})
        else
          # Timed out before the conn was ever committed (still :sniff/:buffer — no
          # bytes decided the mode yet). finish_stream's :stream/:done/:timeout clause
          # assumes a chunked/sent conn: routing an unsent one through it returns the
          # conn untouched (Bandit raises Plug.Conn.NotSentError) AND records a phantom
          # usage row via its status/truncated accounting branches. Nothing was ever
          # delivered, so send the 502 directly here and skip accounting entirely.
          bump_metric(s.opts, "llm_proxy_upstream_error")
          json(s.conn, 502, upstream_no_usable_response())
        end
    end
  end

  # ── per-mode data handling ──
  # Terminal modes: ignore any late data.
  defp handle_stream_data(%{mode: mode} = s, _data) when mode in [:done, :timeout, :aborted],
    do: s

  defp handle_stream_data(%{mode: :sniff} = s, data) do
    # Strip a leading UTF-8 BOM on the very first byte so it never reaches the
    # client or the buffer-decode path.
    data = if s.buf == "", do: strip_bom(data), else: data
    buf = s.buf <> data

    cond do
      byte_size(buf) > 262_144 ->
        stream_abort(s)

      true ->
        case sniff_decision(buf) do
          :stream -> commit_stream(s, buf)
          :buffer -> %{s | mode: :buffer, buf: buf}
          :undecided -> %{s | buf: buf}
        end
    end
  end

  # A4 strip path: when the caller did not opt into include_usage, drop the proxy-injected
  # usage-only chunk (`choices == []`) from the forwarded bytes. RAW bytes always go into
  # acc (so accounting still sees the stripped usage/x_router frames); only complete
  # `\r?\n\r?\n`-delimited frames are forwarded, the trailing partial held in `fwd_rem`.
  # Reassembly preserves the original delimiters byte-for-byte, so a stream with NO
  # usage-only frame is forwarded identically to the verbatim path.
  defp handle_stream_data(%{mode: :stream, strip_usage?: true} = s, data) do
    acc = bounded_tail(s.acc <> data, 65_536)
    {forward, rem} = strip_usage_frames(s.fwd_rem <> data)

    cond do
      forward == "" ->
        # Never chunk an empty binary (a zero-length chunk terminates the response).
        %{s | acc: acc, fwd_rem: rem}

      true ->
        case Plug.Conn.chunk(s.conn, forward) do
          {:ok, conn} ->
            %{s | conn: conn, acc: acc, fwd_rem: rem}

          {:error, _} ->
            safe_close(s.port)
            %{s | mode: :done, acc: acc}
        end
    end
  end

  defp handle_stream_data(%{mode: :stream} = s, data) do
    case Plug.Conn.chunk(s.conn, data) do
      {:ok, conn} ->
        %{s | conn: conn, acc: bounded_tail(s.acc <> data, 65_536)}

      {:error, _} ->
        # Client disconnected — tear down now, PRESERVE acc (Task 8 bills from it). Fold the
        # in-flight `data` into acc (symmetry with the strip arm) so a disconnect ON the final
        # usage frame is still billed.
        safe_close(s.port)
        %{s | mode: :done, acc: bounded_tail(s.acc <> data, 65_536)}
    end
  end

  defp handle_stream_data(%{mode: :buffer} = s, data) do
    buf = s.buf <> data
    if byte_size(buf) > 262_144, do: stream_abort(s), else: %{s | buf: buf}
  end

  # Commit to the streamed path: open a chunked 200 text/event-stream response and
  # flush the accumulated (BOM-free) sniff buffer as the first chunk.
  defp commit_stream(s, buf) do
    conn =
      s.conn
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    acc = bounded_tail(buf, 65_536)
    # A4: a fast small stream can arrive entirely in the sniff buffer, so the strip MUST
    # also apply to the committed first flush (not just later chunks). raw bytes seed acc.
    {flush, rem} = if s.strip_usage?, do: strip_usage_frames(buf), else: {buf, ""}
    result = if flush == "", do: {:ok, conn}, else: Plug.Conn.chunk(conn, flush)

    case result do
      {:ok, conn} ->
        %{s | mode: :stream, conn: conn, buf: "", acc: acc, fwd_rem: rem}

      {:error, _} ->
        safe_close(s.port)
        %{s | mode: :done, conn: conn, acc: acc, fwd_rem: rem}
    end
  end

  # Undecided / oversized non-SSE body → close curl, send ONE 502, count it. Sets a DISTINCT
  # :aborted terminal (NOT :done): finish_stream(:aborted) does NO accounting and NO metric, so
  # the 502 is not followed by a phantom $0 budget row / spurious stream_disconnected/mismatch.
  defp stream_abort(s) do
    safe_close(s.port)
    bump_metric(s.opts, "llm_proxy_upstream_error")
    %{s | mode: :aborted, conn: json(s.conn, 502, upstream_no_usable_response())}
  end

  # Task 8: status-aware streaming accounting. A committed / disconnected / timed-out
  # stream is billed from the bounded `acc` tail (the upstream's last usage + x_router
  # frames). The upstream's REAL status is read from the dumped headers FIRST — a proxy
  # that committed a 200 chunked body while the upstream was a 5xx is flagged
  # (`llm_proxy_stream_status_mismatch`) and recorded as an error with NO positive cost.
  #
  # NOTE: `acc` is only the last 64KB. For a normal stream the usage/[DONE] tail IS in
  # acc, so billing is exact. If a giant stream scrolled the usage frame out of the 64KB
  # window, usage is missing → cost 0 → `llm_proxy_stream_unmetered` fires (loud + correct,
  # never a silent free call).
  # A sniff/buffer-cap abort already sent its single 502 in stream_abort — finish here is a
  # pure teardown no-op: NO accounting, NO metric, NO second response.
  defp finish_stream(%{mode: :aborted} = s), do: s.conn

  defp finish_stream(%{mode: mode} = s) when mode in [:stream, :done, :timeout] do
    status = dump_header_status(s.hdr_path)

    usage =
      case stream_last(s.acc, "usage") do
        m when is_map(m) -> m
        _ -> %{}
      end

    router = upstream_router(stream_last(s.acc, "x_router"))
    # req_body fallback (NOT %{}) so the model resolves even when the upstream omits it.
    model = served_model(router, %{"usage" => usage}, s.req_body)

    {cost, invalid?} =
      executed_cost_usd(usage, s.opts, router, s.budget.spent_usd)

    if invalid?, do: bump_metric(s.opts, "llm_proxy_cost_invalid")

    cond do
      status not in 200..299 ->
        bump_metric(s.opts, "llm_proxy_stream_status_mismatch")
        Logger.error(sanitize_log("llm_proxy: streamed upstream returned status #{status}"))

        record_budget_call(s.opts, s.session, s.request_ctx, %{
          request_id: request_id(),
          model: model,
          status: "upstream_#{status}",
          provider: Map.get(router, "provider")
        })

      mode == :done ->
        bump_metric(s.opts, "llm_proxy_stream_disconnected")
        record_stream(s, model, usage, cost, router)

      s.exit_code not in [0, nil] or not done_sentinel?(s.acc) ->
        bump_metric(s.opts, "llm_proxy_stream_truncated")

        Logger.warning(
          sanitize_log("llm_proxy: streamed response truncated (exit #{inspect(s.exit_code)})")
        )

        record_stream(s, model, usage, cost, router)

      true ->
        if Decimal.compare(cost, 0) != :gt, do: bump_metric(s.opts, "llm_proxy_stream_unmetered")
        record_stream(s, model, usage, cost, router)
    end

    s.conn
  end

  defp finish_stream(%{mode: mode} = s) when mode in [:buffer, :sniff] do
    status = dump_header_status(s.hdr_path)
    latency = max(System.monotonic_time(:millisecond) - s.started, 0)

    case decode_upstream_body(s.buf) do
      {:ok, decoded} ->
        respond_upstream(
          s.conn,
          status,
          decoded,
          latency,
          s.session,
          s.request_ctx,
          s.budget,
          s.opts
        )

      {:error, _} ->
        bump_metric(s.opts, "llm_proxy_upstream_error")
        json(s.conn, 502, upstream_no_usable_response())
    end
  end

  defp record_stream(s, model, usage, cost, router) do
    {cached_tokens, non_cached_tokens} = Proxy.cache_split(usage, router)

    record_budget_call(s.opts, s.session, s.request_ctx, %{
      request_id: request_id(),
      model: model,
      status: "ok",
      prompt_tokens: usage["prompt_tokens"],
      completion_tokens: usage["completion_tokens"],
      total_tokens: usage["total_tokens"],
      cached_tokens: cached_tokens,
      non_cached_tokens: non_cached_tokens,
      cost_usd: cost,
      provider_cost_usd: provider_cost_usd(router),
      provider_cost_state: provider_cost_state(router),
      charge_basis: charge_basis(s.opts, router),
      pricing_version: Map.get(s.opts, :pricing_version, "cost_plus_v1"),
      provider: Map.get(router, "provider")
    })
  end

  # True iff the bounded acc tail contains the SSE terminator as a whole frame — a trimmed
  # `data: [DONE]` line. Matching the frame (same split logic as stream_last) instead of
  # `String.contains?(acc, "[DONE]")` so delta content that merely embeds the literal
  # "[DONE]" cannot mask a genuine truncation.
  defp done_sentinel?(acc) when is_binary(acc) do
    acc
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.any?(fn line -> String.trim_leading(line) == "data: [DONE]" end)
  end

  defp done_sentinel?(_), do: false

  # Scan the WHOLE acc (bounded 64KB tail) for the LAST `data:` event whose `key` is a
  # map, returning that key's VALUE (usage map / x_router map), or `%{}` if none. Usage
  # and x_router are resolved INDEPENDENTLY so a router that splits usage and cost across
  # two separate SSE events is still billed (never $0 just because they didn't co-occur).
  defp stream_last(acc, key) when is_binary(acc) do
    acc
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.flat_map(fn line ->
      case String.trim_leading(line) do
        "data: [DONE]" ->
          []

        "data:" <> rest ->
          case Jason.decode(String.trim(rest)) do
            {:ok, m} when is_map(m) -> [m]
            _ -> []
          end

        _ ->
          []
      end
    end)
    |> Enum.reverse()
    |> Enum.find_value(%{}, fn ev -> if is_map(ev[key]), do: ev[key] end)
  end

  defp upstream_no_usable_response do
    %{
      error: %{
        message: "upstream returned no usable response",
        type: "upstream_error",
        code: "upstream_invalid"
      }
    }
  end

  # ── pure SSE sniff / framing helpers (unit-tested directly) ──

  # Decide what an undecided byte buffer is: a streamed SSE response (`data:`/
  # `event:` field seen), a buffered JSON body (leading `{`/`[`), or not-yet-known.
  # Leading BOM stripped; comment (`:`), `id:`, `retry:`, and blank lines are
  # skipped (they do NOT commit the stream).
  @doc false
  def sniff_decision(buf) do
    buf = strip_bom(buf)

    cond do
      buf == "" -> :undecided
      json_lead?(buf) -> :buffer
      true -> sse_scan(buf)
    end
  end

  defp json_lead?(buf) do
    case String.trim_leading(buf) do
      "{" <> _ -> true
      "[" <> _ -> true
      _ -> false
    end
  end

  defp sse_scan(buf) do
    buf
    |> String.split("\n")
    |> Enum.reduce_while(:undecided, fn raw, _acc ->
      line = String.trim_trailing(raw, "\r")

      cond do
        sse_prefix?(line) -> {:halt, :stream}
        line == "" -> {:cont, :undecided}
        String.starts_with?(line, ":") -> {:cont, :undecided}
        String.starts_with?(line, "id:") -> {:cont, :undecided}
        String.starts_with?(line, "retry:") -> {:cont, :undecided}
        true -> {:cont, :undecided}
      end
    end)
  end

  @doc false
  def sse_prefix?(t), do: String.starts_with?(t, "data:") or String.starts_with?(t, "event:")

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(bin), do: bin

  # Keep only the last `n` bytes — bounds the rolling acc (Task 8) and the first
  # flushed chunk's acc seed.
  @doc false
  def bounded_tail(bin, n) do
    if byte_size(bin) <= n, do: bin, else: binary_part(bin, byte_size(bin) - n, n)
  end

  # A4: strip the proxy-injected usage chunk unless the ORIGINAL caller explicitly opted
  # into include_usage (true / "true" / 1). No stream_options, or include_usage:false,
  # both mean "caller did not ask for usage" → strip.
  @doc false
  def strip_usage?(req_body) do
    get_in(req_body, ["stream_options", "include_usage"]) not in [true, "true", 1]
  end

  # Split `buf` into complete SSE frames (delimited by a blank line) + a trailing partial
  # remainder. Drop any complete frame that decodes to a `chat.completion.chunk` with an
  # empty `choices` list (the include_usage-injected usage-only chunk). Delimiters are
  # captured and re-emitted verbatim, so frames that are NOT dropped are byte-identical to
  # the input. Returns `{forwardable_bytes, remainder}`.
  @doc false
  def strip_usage_frames(buf) do
    parts = Regex.split(~r/\r?\n\r?\n/, buf, include_captures: true)

    {remainder, pairs} =
      case Enum.reverse(parts) do
        [rem | rest] -> {rem, Enum.reverse(rest)}
        [] -> {"", []}
      end

    forward =
      pairs
      |> Enum.chunk_every(2)
      |> Enum.reject(fn
        [frame, _delim] -> usage_only_frame?(frame)
        _ -> false
      end)
      |> Enum.map(&Enum.join/1)
      |> Enum.join()

    {forward, remainder}
  end

  # True iff this SSE frame is a `data:` line whose JSON object has `choices == []` — the
  # usage-only chunk. `data: [DONE]` and any non-decoding / non-data frame → false (kept).
  defp usage_only_frame?(frame) do
    case String.trim_leading(frame) do
      "data:" <> rest ->
        case Jason.decode(String.trim(rest)) do
          {:ok, m} when is_map(m) -> Map.get(m, "choices") == []
          _ -> false
        end

      _ ->
        false
    end
  end

  # Resolve the FINAL HTTP status from curl's --dump-header file. Filters ALL
  # `HTTP/` lines, REJECTS 1xx (100-continue / 103 early-hints / a CONNECT 200),
  # takes the last remaining status, clamps to 100..599, and returns 502 (NOT 200)
  # on missing / empty / unparseable / only-1xx — so a header read failure can
  # never be mistaken for success.
  @doc false
  def dump_header_status(path) do
    case File.read(path) do
      {:ok, content} ->
        finals =
          content
          |> String.split(~r/\r?\n/)
          |> Enum.filter(&String.starts_with?(&1, "HTTP/"))
          |> Enum.flat_map(&parse_status_line/1)
          |> Enum.reject(&(&1 in 100..199))

        case finals do
          [] -> 502
          list -> list |> List.last() |> clamp_status()
        end

      {:error, _} ->
        502
    end
  end

  # Handles both `HTTP/1.1 200 OK` and `HTTP/2 200` (no reason phrase).
  defp parse_status_line(line) do
    case String.split(line, " ", parts: 3) do
      [_proto, code | _] ->
        case Integer.parse(code) do
          {n, _} -> [n]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp clamp_status(n) when n in 100..599, do: n
  defp clamp_status(_), do: 502

  # Idempotent + total: closes the curl Port iff it's still open. Never raises.
  defp safe_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp request_id do
    "llmr_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
