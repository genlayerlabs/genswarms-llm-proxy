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
    * blocked requests deliver a deterministic Telegram notice, rate-limited per
      {budget_identity, cap type, UTC day} (default: repeat every 4h, see
      `notice_repeat_ms`; the state is day-pruned and per process lifetime). The
      synthetic 200 completion tells the agent what THIS request did — notice
      sent, user already notified earlier, or (for `notify: false` background
      sessions) that no user notice is sent by this path;
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
  @payments_stuck_limit 200

  # (R4-P4-I5) Rows the `stuck_payments` operator read will render. The store
  # caps its own answer (the contract requires it); this is the second bound,
  # and the surface says plainly when the view is truncated.
  @stuck_read_limit 100

  # (R4-P4-I3) Second bound on the DURABLE hold read. The contract requires the
  # store to cap it server-side, because it sits on a per-request path over a
  # table a third party can grow (permissionless deposit addresses × a
  # saturated issuance window). This is the belt to that store-side braces: a
  # host that forgets still cannot make the notice path unbounded, and the
  # truncation is logged rather than silent.
  @held_read_limit 50
  # Bounded in-memory mirror of hub-quarantined ("held") settlements, per the
  # same FIFO/eviction-logged stance as the stuck queue. It is a NOTICE mirror,
  # never a money record: it credits nothing and the hub's operator queue is
  # authoritative.
  @payments_held_limit 200
  @payments_poll_max_fetch 500
  # Minimum interval between repeated block notices for the same
  # {budget_identity, reason, day}: 4 hours. Overridable per proxy via the
  # `notice_repeat_ms` config/opt; 0 or nil = legacy once-per-day.
  @default_notice_repeat_ms 4 * 60 * 60 * 1000

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

  @doc false
  # (D9) CREDITS IMPLY PRICING. A user who pays USDC into a proxy that then
  # charges $0.00 per call has bought nothing: the credit is never consumed,
  # the balance never moves, and the books say the liability is still
  # outstanding forever — an accounting fiction, and the most expensive kind of
  # silent failure on the money path. So: with credits ON (payments_source
  # configured, the same strict derivation `credits_enabled?/1` uses), the
  # operator rate card must be able to VALUE a call.
  #
  # "Cannot value a call" is deliberately mode-independent. In
  # `:rate_card_first` the card IS the charge; in `:cost_plus` the card is the
  # fallback whenever provider cost is zero/missing/invalid (that is why
  # `validate_pricing_config!/3` already demands a complete card there) — in
  # BOTH modes an all-zero or incomplete card is the $0.00-per-call mode. A
  # complete card with at least one positive per-Mtok price is the bar.
  #
  # A 0/0 card remains perfectly legal with credits OFF (a genuine free tier);
  # this gate never fires on an install that configures no payments source, so
  # the prime invariant holds.
  def validate_credits_pricing!(config, pricing_mode, prices) do
    if credits_enabled?(config) and not prices_can_value_call?(prices) do
      raise ArgumentError,
            "credits are enabled (payments_source is configured) but pricing_mode " <>
              "#{inspect(pricing_mode)} cannot value a call: prices must be a COMPLETE " <>
              "non-negative prompt/completion rate card with at least one positive " <>
              "per-Mtok price, got: #{inspect(prices)} — otherwise every call costs " <>
              "$0.00, paid-in credit is never consumed, and the balance is an " <>
              "accounting fiction"
    end

    :ok
  end

  # (R4-M3) "At least one positive" deliberately admits a partly-zero card,
  # e.g. prompt 0 / completion 0.42: a call returning an EMPTY completion (a
  # real case — see checks/llm_proxy_empty_completion_test.exs) is then valued
  # at $0.00 and consumes no credit. That is accepted, not overlooked: with
  # only two prices, "at least one positive" means either every call with input
  # tokens is priced or every call with output is, and a deliberately
  # prompt-free (or completion-free) card is a legitimate operator choice. The
  # gate's purpose is rejecting the all-zero and INCOMPLETE cards that make
  # paid-in credit permanently unconsumable, and it serves that exactly.
  defp prices_can_value_call?(prices) when is_map(prices) do
    rate_card_complete?(prices) and
      (positive_price?(Map.get(prices, :prompt_per_mtok) || Map.get(prices, "prompt_per_mtok")) or
         positive_price?(
           Map.get(prices, :completion_per_mtok) || Map.get(prices, "completion_per_mtok")
         ))
  end

  defp prices_can_value_call?(_prices), do: false

  defp positive_price?(value) do
    case strict_decimal(value) do
      %Decimal{} = d -> finite_decimal?(d) and Decimal.compare(d, Decimal.new(0)) == :gt
      _ -> false
    end
  rescue
    _ -> false
  end

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
    :ok = validate_credits_pricing!(config, pricing_mode, prices)
    poll_config = validate_poll_config!(config)

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
      empty_completion_retries: min(max(Map.get(config, :empty_completion_retries, 0), 0), 3),
      # Minimum interval between repeated block notices to the SAME conversation
      # for the SAME cap type on the same UTC day (default 4h). 0 or nil = legacy
      # once-per-day.
      notice_repeat_ms: Map.get(config, :notice_repeat_ms, @default_notice_repeat_ms),
      # Optional seam (nil | (budget_identity -> nil | String.t())): when set, its
      # non-empty return value is appended as an extra line on a `:budget` block
      # notice (e.g. a top-up instruction). Absent/raising/non-binary -> no hint,
      # never crashes the block path (see budget_notice/4).
      topup_hint_fun: Map.get(config, :topup_hint_fun),
      # (B2) Feature gate for the prepaid credit path (credit_exhausted?/2,
      # maybe_debit_credit/4): on iff payments_source is configured — same
      # derivation the object-side payments_source gate below uses, so a host
      # that never configures payments can never accrue mirror debits nor
      # have the block gate consult a credit balance at all.
      credits_enabled: credits_enabled?(config)
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
         notice_repeat_ms: plug_opts.notice_repeat_ms,
         clock: Map.get(config, :clock, fn -> DateTime.utc_now() end),
         dm_module: module_ref(Map.get(config, :dm_module))
       },
       # Payment-agnostic credit top-up (see handle_payment_confirmed/3):
       # payments_source nil/"" keeps the feature OFF; the object that IS the
       # payments_source is the only trusted sender of {"action":"payment_confirmed"}.
       payments_source: Map.get(config, :payments_source),
       credit_namespace: Map.get(config, :credit_namespace, "default"),
       credit_per_usd: validate_credit_per_usd!(Map.get(config, :credit_per_usd, "1.0")),
       # Durable outbox consumer. `settlements_fn: nil` and `poll_sources: []`
       # keep polling fully off; both defaults are deliberately inert.
       settlements_fn: poll_config.settlements_fn,
       payments_consumer: Map.get(config, :payments_consumer, "llm_proxy") |> to_string(),
       poll_lag: poll_config.poll_lag,
       poll_limit: poll_config.poll_limit,
       poll_sources: poll_config.poll_sources,
       # (R4-P4-I5) Who may drive the OPERATOR actions on the stuck queue
       # (`stuck_payments`, `retry_stuck`). Gated by the same allowlist
       # mechanism as `poll_payments` and DEFAULTS TO THE EMPTY LIST: an
       # operator surface nobody configured is an operator surface nobody has.
       # Deliberately a SECOND list rather than a reuse of poll_sources —
       # granting the operator verbs must not also grant the ability to drive
       # the credit poll, and vice versa.
       operator_sources: poll_config.operator_sources,
       # (B2) Same derivation as plug_opts.credits_enabled above — kept
       # alongside payments_source on the object-side state too, one
       # resolution point for "are credits on" regardless of which side asks.
       credits_enabled: credits_enabled?(config),
       # Credit-notice delivery seam (0.4.0): the SAME swarm_name/sender/
       # deliver_fn triple the Plug reads into plug_opts (see `call/2` below),
       # read here too so the object side — which is what actually applies a
       # payment_confirmed/poll/retry_stuck credit — can push a "payment
       # received" notice through the exact seam the block notice already
       # uses (`slot_reply` -> `sender`), with no separate wiring for a host.
       # `credit_notice_enabled` (default true) is the one operator toggle;
       # `sender` absent/unreachable degrades to no notice either way, same
       # as the block path degrades (see send_credit_notice/4).
       swarm_name: Map.get(config, :swarm_name, "swarm"),
       sender: Map.get(config, :sender, :sender),
       # Function.capture/3 (not a `&M.f/4` literal) so this default resolves
       # at RUNTIME — genswarms is a peer/runtime dependency this package
       # never compiles against (see mix.exs), and a compile-time capture
       # would add a second instance of the pre-existing "module not
       # available" warning the Plug's own default already carries.
       deliver_fn:
         Map.get(config, :deliver_fn) ||
           Function.capture(Genswarms.Objects.ObjectServer, :deliver_message, 4),
       credit_notice_enabled: Map.get(config, :credit_notice_enabled, true) != false,
       # OPTIONAL: a host that wants to present the credit ITSELF passes a
       # 1-arity function here and this package composes no user-facing text
       # and delivers nothing. Absent (the default) keeps the built-in notice
       # exactly as before, so no consumer has to do anything.
       #
       # Presentation is a consumer concern. This package hardcodes one
       # English sentence with an emoji, which is fine as a default and wrong
       # as the only option: a host that shows a top-up as a card the user
       # watches progress needs the credit to be the card's LAST STATE, not a
       # separate message under it — and it is the host, not this package,
       # that knows the card exists.
       credit_notice_fn: credit_notice_fn(config)
     }}
  end

  # (B2, X5a) credits_enabled? = payments_source configured and non-empty.
  # Derived once, at boot, from the same config read that feeds
  # payments_source on both the plug_opts (credit_exhausted?/
  # maybe_debit_credit) and the object-side state (handle_payment_confirmed)
  # — a host that never sets payments_source gets the feature off on both
  # sides, with no retro-charge if it's turned on later (see
  # maybe_debit_credit/4). ON only for a non-empty binary (the common case —
  # an object name string) or an atom that is neither `nil` nor `false` (a
  # source given as an atom, e.g. an object-name atom): `payments_source:
  # false` must be OFF everywhere — the prior wildcard `_ -> true` treated an
  # explicit `false` as "on" (it is neither `nil` nor `""`), the opposite of
  # what setting it to `false` means.
  defp credits_enabled?(config) do
    case Map.get(config, :payments_source) do
      v when is_binary(v) and v != "" -> true
      v when is_atom(v) and v not in [nil, false] -> true
      _ -> false
    end
  end

  defp validate_poll_config!(config) do
    settlements_fn = Map.get(config, :settlements_fn)
    poll_lag = Map.get(config, :poll_lag, 100)
    poll_limit = Map.get(config, :poll_limit, 100)
    poll_sources = Map.get(config, :poll_sources, [])
    operator_sources = Map.get(config, :operator_sources, [])

    unless is_list(operator_sources) do
      raise ArgumentError, "operator_sources must be a list, got: #{inspect(operator_sources)}"
    end

    unless is_nil(settlements_fn) or is_function(settlements_fn, 2) do
      raise ArgumentError,
            "settlements_fn must be nil or a two-arity function, got: #{inspect(settlements_fn)}"
    end

    unless is_integer(poll_lag) and poll_lag >= 0 do
      raise ArgumentError,
            "poll_lag must be a non-negative integer, got: #{inspect(poll_lag)}"
    end

    unless is_integer(poll_limit) and poll_limit > 0 do
      raise ArgumentError,
            "poll_limit must be a positive integer, got: #{inspect(poll_limit)}"
    end

    unless is_list(poll_sources) do
      raise ArgumentError, "poll_sources must be a list, got: #{inspect(poll_sources)}"
    end

    if poll_lag + poll_limit > @payments_poll_max_fetch do
      raise ArgumentError,
            "poll_lag + poll_limit must be <= #{@payments_poll_max_fetch} " <>
              "(the settlements hub fetch cap), got: #{poll_lag} + #{poll_limit}"
    end

    %{
      settlements_fn: settlements_fn,
      poll_lag: poll_lag,
      poll_limit: poll_limit,
      poll_sources: poll_sources,
      operator_sources: operator_sources
    }
  end

  # (M3) Boot-reject a garbage credit_per_usd the same way a bad pricing
  # config is boot-rejected (validate_pricing_config!/3): the tolerant
  # decimal/1 maps unparseable strings to Decimal 0, so a typo'd
  # `credit_per_usd: "1,0"` would otherwise ack EVERY payment
  # `ok:true, credited_usd:"0.00"` — accepted and discarded, and the hub
  # (correctly) never retries an acked confirmation. The default "1.0"
  # always passes; only an explicitly configured non-parseable, non-finite,
  # or non-positive value refuses boot.
  defp validate_credit_per_usd!(value) do
    with %Decimal{} = d <- strict_decimal(value),
         true <- finite_decimal?(d) and Decimal.compare(d, Decimal.new(0)) == :gt do
      d
    else
      _ ->
        raise ArgumentError,
              "credit_per_usd must be a positive finite decimal (a string like \"1.0\"), " <>
                "got: #{inspect(value)} — a tolerant parse would silently zero every payment"
    end
  end

  def interface do
    %{
      usage: %{
        input: ~s({"action":"usage"}),
        output: "per-session token/cost/error totals"
      },
      health: %{input: ~s({"action":"health"}), output: ~s({"ok":true})},
      quota_status: %{
        # (R4-M5) CONSCIOUS CARRY-FORWARD: this action is answered to ANY
        # sender — no arm gates on `from` — and as of 0.4.0 its payments_poll
        # block also carries the asked identity's hold refs and amounts. The
        # held list is correctly identity-scoped (entries omit `beneficiary`,
        # held_for_identity/2 filters on budget_identity, no conversation_id
        # yields []), but any object that can NAME a conversation_id can read
        # that conversation's holds. This is the same pre-existing
        # authorization class as the balances and spend the call already
        # returns, not a regression — the swarm's object topology is the
        # access control. Gate on `from` here if that ever stops being true.
        input:
          ~s({"action":"quota_status","conversation_id":"tg:903489662:0","kind":"dm","workspace_key":"default"}),
        output: "read-only per-identity request quota, spend, and global cap status"
      },
      payment_confirmed: %{
        # (X5d) namespace here is "default" — the actual credit_namespace default
        # (see init/1's `credit_namespace: Map.get(config, :credit_namespace,
        # "default")`), not an arbitrary example value. This MUST match whatever
        # `credit_namespace` the host actually configures — a confirmation whose
        # "namespace" differs from the configured value is silently ignored
        # (see handle_payment_confirmed/3), so a hub copying this example
        # verbatim against a host that overrides credit_namespace would have
        # every payment silently dropped.
        input:
          ~s({"action":"payment_confirmed","beneficiary":"w:default|k:dm|c:tg:9:0","amount_usd":"5.00","method":"card","ref":"txn_0","namespace":"default"}),
        output:
          "credits the beneficiary's prepaid balance once per (method, ref) — only from the configured payments_source, only for the configured credit_namespace",
        note:
          "\"namespace\" must equal the host's configured credit_namespace (default " <>
            "\"default\") — a mismatched namespace is silently ignored, not an error. " <>
            "\"amount_usd\" is a STRING by contract, never a JSON number (see README)."
      },
      payment_held: %{
        input:
          ~s({"action":"payment_held","beneficiary":"llmb_...","amount_usd":"5.00","method":"8453","ref":"0xabc:0","namespace":"llm_quota","at":"2026-07-25T09:00:00Z","reason":"max_payment"}),
        output:
          "records + meters a hub-quarantined settlement and surfaces it to the user on " <>
            "the next budget-block notice — it NEVER credits; only from the configured " <>
            "payments_source",
        note:
          "the current hub sends \"method\", \"namespace\" and \"at\" (genswarms-payments " <>
            ">= 01ab1dd); all three stay OPTIONAL for redeliveries from older hubs. A " <>
            "PRESENT \"namespace\" must equal the host's credit_namespace or the notice " <>
            "is refused; a present-but-unusable \"method\" (empty, non-string, or " <>
            "containing \":\") is refused like it is on the credit path. The hold is " <>
            "cleared by a later payment_confirmed for the SAME beneficiary and " <>
            "method/ref — the phase-4 operator release path."
      }
    }
  end

  def handle_message(from, content, state) do
    case Jason.decode(content) do
      {:ok, %{"action" => "usage"}} ->
        {:reply, Jason.encode!(%{usage: usage_totals(state.state_pid)}), state}

      {:ok, %{"action" => "health"}} ->
        {:reply, Jason.encode!(%{ok: true, endpoint: state.endpoint, provider: state.provider}),
         state}

      {:ok, %{"action" => "quota_status"} = msg} ->
        {:reply, Jason.encode!(quota_status(msg, state)), state}

      {:ok, %{"action" => "poll_payments"}} ->
        handle_poll_payments(from, state)

      {:ok, %{"action" => "stuck_payments"} = msg} ->
        handle_stuck_payments(from, msg, state)

      {:ok, %{"action" => "retry_stuck"} = msg} ->
        handle_retry_stuck(from, msg, state)

      {:ok, %{"action" => "payment_confirmed"} = msg} ->
        handle_payment_confirmed(from, msg, state)

      {:ok, %{"action" => "payment_held"} = msg} ->
        handle_payment_held(from, msg, state)

      _ ->
        {:noreply, state}
    end
  end

  # (X5c) Single store_mod resolution point shared by credit_payment/2 and
  # quota_status/2 — both tolerate the same two host state shapes (a
  # top-level :store_mod, test/mm lineage; one nested under :quota, the
  # production init/1 assembly path), but previously resolved them in
  # OPPOSITE directions: credit_payment/2 took the top-level key first
  # (falling back to the nested one only when the top-level was nil/false),
  # while quota_status/2 takes the nested key first via `Map.put_new`
  # (falling back to top-level only when :quota carries no :store_mod key at
  # all) — a split-brain risk if a host ever assembled state with two
  # different store_mod values in the two places (credits would durably
  # write through one store while quota_status's dashboard reads the other).
  # This is quota_status/2's existing direction — nested wins whenever
  # present, matching the "production init/1 assembly path nests it" comment
  # above; picked here rather than top-level-first because init/1 is the
  # shape every real boot actually produces.
  defp resolve_store_mod(state) do
    state
    |> Map.get(:quota, %{})
    |> Map.put_new(:store_mod, Map.get(state, :store_mod))
    |> Map.get(:store_mod)
  end

  # Payment-agnostic credit top-up. Trust = the configured payments_source
  # object name; confirmations for a foreign namespace are IGNORED per the
  # settlement-hub contract (multiple consumers share one hub, each only
  # cares about its own namespace — a foreign one is neither an error nor
  # ours to warn about). Idempotency key "<method>:<ref>" — a re-delivered
  # confirmation credits once (see Proxy.apply_credit_entry/3, Task 1).
  defp handle_payment_confirmed(from, msg, state) do
    source = Map.get(state, :payments_source)
    namespace = Map.get(state, :credit_namespace, "default")

    cond do
      # (M2) Gate on the SAME strict credits_enabled derivation the plug side
      # uses (init/1 stores it next to payments_source; false/nil = feature
      # off = reject). Gating on raw payments_source alone let
      # `payments_source: false` — OFF everywhere else per X5a — pass the
      # to_string/1 trust compare for a sender literally named "false" and
      # mint a mirror balance invisible to the (correctly off) gate.
      not Map.get(state, :credits_enabled, false) ->
        {:noreply, state}

      is_nil(source) or source == "" ->
        {:noreply, state}

      to_string(from) != to_string(source) ->
        Logger.warning(
          "llm_proxy: payment_confirmed from untrusted source #{inspect(from)} — ignored"
        )

        {:noreply, state}

      normalize_namespace(Map.get(msg, "namespace")) != normalize_namespace(namespace) ->
        {:noreply, state}

      true ->
        credit_payment(msg, state)
    end
  end

  # (M5b) Same to_string/1 normalization the source compare above applies: a
  # host configuring `credit_namespace` as an atom (`:default`, e.g. from
  # keyword/IR config) must not silently drop every payment against the
  # JSON-decoded binary "default". Only stringable scalars are normalized —
  # a hostile non-scalar JSON "namespace" (map/list) stays as-is and simply
  # mismatches (ignored), never raising out of the handler.
  defp normalize_namespace(v) when is_binary(v) or is_atom(v) or is_number(v), do: to_string(v)
  defp normalize_namespace(v), do: v

  # ── payment_held (C1 consumer side) ───────────────────────────────────────
  #
  # The settlement hub QUARANTINES a settlement that trips its issuance caps:
  # the row is durable, deduped, alarmed, and NEVER creditable until an
  # operator releases it. On quarantine the hub casts `payment_held` to its
  # targets, ONE-SHOT and best-effort — the hub's operator queue, not this
  # message, is the authoritative record. Two consequences pinned here:
  #
  #   * this handler NEVER credits. It records (bounded mirror + optional
  #     durable callback), meters, and makes the hold VISIBLE to the user via
  #     the existing block-notice machinery (see `budget_notice/4`). A silent
  #     hold on money the user watched leave their wallet is a support
  #     incident by design;
  #   * a LOST notice must not corrupt state. Nothing downstream reads the
  #     held mirror as truth about money: it only adds one honest sentence to
  #     a notice and one operator block to `quota_status`. The release path
  #     (phase 4) re-emits `payment_confirmed` for the same method:ref, and
  #     THAT is what both credits and clears the hold.
  #
  # Trust is the same gate a forged `payment_confirmed` faces: credits must be
  # enabled AND the sender must be the configured payments_source. An
  # untrusted sender could otherwise paint "your payment is held" onto any
  # conversation's block notice.
  #
  # KNOWN LIMITATION (R4-M1): the ONLY thing that clears a hold is a
  # payment_confirmed matching the same beneficiary + key/ref. A hold that is
  # VOIDED or REFUNDED rather than released never produces a credit, and a
  # phase-4 manual credit minted under a synthetic ref ("manual:op-1") will not
  # match — in both cases "An operator has to release it." persists for the
  # life of this BEAM process, indefinitely and untruthfully. The DESIGNED
  # release path does clear correctly (release = settle the SAME row and mint a
  # fresh outbox_seq, hence the same method/ref), so this is a forward-compat
  # hazard, not a present bug. It must be closed — a `payment_voided` action or
  # a bounded hold TTL — BEFORE phase 4's operator affordances land.
  defp handle_payment_held(from, msg, state) do
    source = Map.get(state, :payments_source)

    cond do
      not Map.get(state, :credits_enabled, false) ->
        {:noreply, state}

      is_nil(source) or source == "" ->
        {:noreply, state}

      to_string(from) != to_string(source) ->
        Logger.warning(
          "llm_proxy: payment_held from untrusted source #{inspect(from)} — ignored"
        )

        {:noreply, state}

      not held_namespace_match?(msg, state) ->
        # Silent-but-metered refusal, exactly like a foreign-namespace
        # confirmation: multiple consumers share one hub and a foreign
        # namespace is neither an error nor ours to warn about — but unlike a
        # credit, a dropped user-visible notice is worth a counter.
        bump_store_metric(
          resolve_store_mod(state),
          "llm_payments_held_refused",
          %{reason: "namespace_mismatch", idempotency_key: held_refusal_key(msg)},
          1
        )

        {:noreply, state}

      true ->
        record_held_payment(msg, state)
    end
  end

  # The hub's `payment_held` payload (verified against the emit site in
  # genswarms-payments' `finish_recorded_settlement/6`, "quarantined" arm, at
  # `01ab1dd`) carries: action, beneficiary, amount_usd, method, ref,
  # namespace, at, reason — the same shape `payment_confirmed` carries. So the
  # namespace check below is the LIVE path on every current hub delivery, not a
  # dormant forward-compat branch.
  #
  # `method`, `namespace` and `at` nonetheless stay OPTIONAL: hubs older than
  # `01ab1dd` omit all three, and a redelivery of a quarantine recorded before
  # that commit still carries the old shape. Hence:
  #
  #   * an ABSENT "namespace" is accepted (there is nothing to compare against,
  #     and the hub scopes delivery by its configured targets anyway);
  #   * a PRESENT "namespace" MUST match — one hub serves several consumers and
  #     must not be able to cross-post another namespace's holds into this one.
  #     Because the field is now always sent, a host whose `credit_namespace`
  #     diverges from the hub's settlement namespace loses EVERY hold notice
  #     (metered `namespace_mismatch`, no user sentence) — coherent with
  #     `payment_confirmed`, and covered by the namespace-coherence boot gate.
  defp held_namespace_match?(msg, state) do
    case Map.fetch(msg, "namespace") do
      :error -> true
      {:ok, nil} -> true
      {:ok, ns} -> normalize_namespace(ns) == normalize_namespace(held_namespace(state))
    end
  end

  defp held_namespace(state), do: Map.get(state, :credit_namespace, "default")

  defp record_held_payment(msg, state) do
    with beneficiary when is_binary(beneficiary) and beneficiary != "" <-
           Map.get(msg, "beneficiary"),
         ref when is_binary(ref) and ref != "" <- Map.get(msg, "ref"),
         {:ok, method} <- held_method(msg),
         {:ok, amount} <- parse_money(Map.get(msg, "amount_usd")),
         true <- Decimal.compare(amount, Decimal.new(0)) == :gt do
      key = held_key(method, ref)

      record = %{
        budget_identity: beneficiary,
        beneficiary: beneficiary,
        idempotency_key: key,
        method: method,
        ref: ref,
        amount_usd: amount,
        reason: to_string(Map.get(msg, "reason") || "unknown"),
        namespace: normalize_namespace(Map.get(msg, "namespace") || held_namespace(state)),
        at: held_at(msg)
      }

      case remember_held_payment(state, record) do
        :already_present ->
          {:reply, Jason.encode!(%{ok: true, held: true, duplicate: true}), state}

        :recorded ->
          store_mod = resolve_store_mod(state)
          durable_held_payment(store_mod, record, key)

          bump_store_metric(
            store_mod,
            "llm_payments_held",
            %{idempotency_key: key, reason: record.reason},
            1
          )

          Logger.warning(
            "llm_proxy: payment HELD (#{record.reason}) — #{Decimal.to_string(amount, :normal)} " <>
              "USD for #{inspect(beneficiary)} recorded, NOT credited; key=#{key}"
          )

          {:reply, Jason.encode!(%{ok: true, held: true, duplicate: false}), state}
      end
    else
      _ ->
        bump_store_metric(
          resolve_store_mod(state),
          "llm_payments_held_refused",
          %{reason: "bad_payment_held", idempotency_key: held_refusal_key(msg)},
          1
        )

        {:reply, Jason.encode!(%{ok: false, error: "bad_payment_held"}), state}
    end
  end

  # The current hub sends "method"; hubs older than 01ab1dd omit it. Keep the
  # credit path's "<method>:<ref>" key WHEN a method is present (so a hold and
  # its later release share one key), and fall back to the bare ref when it is
  # absent — clear_held_payment/4 matches on ref too, so a method-less hold is
  # still cleared by the release that credits it.
  #
  # (R4-M4) A PRESENT-but-unusable method is REFUSED, not silently downgraded
  # to nil. `apply_validated_payment/3` refuses a colon-bearing method for the
  # credit path (the "<method>:<ref>" join would be ambiguous); the hold path
  # now says the same thing. Downgrading instead would key the hold on the bare
  # ref, which (a) widens the shared keyspace the per-identity dedup exists to
  # close and (b) leaves a hold that can never key-match its own release.
  #   :error       -> bad_payment_held (present, but empty / non-binary / has ":")
  #   {:ok, nil}   -> absent or JSON null (legacy hub) -> key on the bare ref
  #   {:ok, m}     -> usable -> key on "<method>:<ref>"
  defp held_method(msg) do
    case Map.fetch(msg, "method") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, m} when is_binary(m) and m != "" ->
        if String.contains?(m, ":"), do: :error, else: {:ok, m}

      {:ok, _other} ->
        :error
    end
  end

  defp held_key(nil, ref), do: ref
  defp held_key(method, ref), do: "#{method}:#{ref}"

  # A refusal must still be diagnosable. payment_key/1 needs BOTH method and
  # ref (the credit wire always carries both); a hold usually carries only the
  # ref, so it gets its own tolerant derivation — ref-only, or nil when even
  # that is missing.
  defp held_refusal_key(msg) do
    case Map.get(msg, "ref") do
      ref when is_binary(ref) and ref != "" ->
        case held_method(msg) do
          {:ok, method} -> held_key(method, ref)
          # An unusable method is itself the refusal reason (R4-M4): the join
          # would be ambiguous, so name the ref alone rather than mint a key
          # that cannot be trusted to identify anything.
          :error -> ref
        end

      _ ->
        Map.get(msg, "idempotency_key")
    end
  end

  defp held_at(msg) do
    with at when is_binary(at) <- Map.get(msg, "at"),
         {:ok, dt, _offset} <- DateTime.from_iso8601(at) do
      dt
    else
      _ -> DateTime.utc_now()
    end
  end

  # Bounded FIFO mirror, same shape and stance as the stuck-payment mirror:
  # deduped on the held key, capped at @payments_held_limit, and every
  # eviction is logged (a silently truncated hold queue is how a user's held
  # money stops being visible).
  #
  # (R4-I2) The dedup is scoped to `(budget_identity, key)`, NEVER the key
  # alone. The mirror is multi-tenant and the key shapes share a keyspace: the
  # hub's `ref` legitimately contains a colon (`tx_hash:log_index`), so a
  # method-less hold keyed on the bare ref `"8453:0xaa"` collides with a
  # method-bearing hold keyed `"8453" <> ":" <> "0xaa"` belonging to somebody
  # else. A global dedup swallows the second identity's hold as a "duplicate":
  # no mirror row, no durable record, no metric, no user sentence — and the hub
  # is acked `ok:true`, so nothing anywhere flags the loss.
  defp remember_held_payment(state, record) do
    state_pid = Map.get(state, :state_pid, @state_name)
    key = record.idempotency_key
    identity = record.budget_identity

    {status, evicted} =
      Agent.get_and_update(state_pid, fn mirror ->
        held = Map.get(mirror, :held_payments, [])

        if Enum.any?(
             held,
             &(Map.get(&1, :budget_identity) == identity and
                 Map.get(&1, :idempotency_key) == key)
           ) do
          {{:already_present, []}, mirror}
        else
          appended = held ++ [record]
          overflow = max(length(appended) - @payments_held_limit, 0)

          {{:recorded, Enum.take(appended, overflow)},
           Map.put(mirror, :held_payments, Enum.drop(appended, overflow))}
        end
      end)

    Enum.each(evicted, fn old ->
      Logger.warning(
        "llm_proxy: evicting oldest in-memory HELD payment mirror entry; " <>
          "idempotency_key=#{inspect(Map.get(old, :idempotency_key))} — the user-visible " <>
          "hold notice for it is gone; the hub's operator queue remains authoritative"
      )
    end)

    status
  end

  defp durable_held_payment(store_mod, record, key) do
    if store_callback?(store_mod, :record_llm_held_payment, 1) do
      case safe_store_call(store_mod, :record_llm_held_payment, [record]) do
        :ok ->
          :ok

        other ->
          # Never fatal: the mirror already carries the user-visible hold and
          # the hub owns the authoritative record.
          Logger.error(
            "llm_proxy: durable held-payment record failed for #{inspect(key)}: #{inspect(other)}"
          )

          bump_store_metric(
            store_mod,
            "llm_payments_held_store_failed",
            %{idempotency_key: key},
            1
          )
      end
    end

    :ok
  end

  # A credit that lands for the same money RESOLVES the hold: the phase-4
  # release re-emits `payment_confirmed` with the same method+ref, so both the
  # exact "<method>:<ref>" key and the bare ref (a method-less hold, the
  # pre-01ab1dd hub shape) are matched. `:duplicate` clears too — it also means
  # "this key is credited", just not by this delivery.
  #
  # (R4-I1) The match is scoped to the CREDITED BENEFICIARY. Money is
  # per-identity: a settlement for beneficiary B must never clear beneficiary
  # A's hold. Without the scope, two settlements sharing a `ref` across
  # beneficiaries let one user's credit silently erase another user's hold —
  # the victim's money stays quarantined at the hub while their block notice
  # reverts to the base text and their `quota_status` row vanishes, which is
  # exactly the silence C1 exists to prevent.
  defp clear_held_payment(state, key, ref, beneficiary) do
    state_pid = Map.get(state, :state_pid, @state_name)

    cleared =
      Agent.get_and_update(state_pid, fn mirror ->
        held = Map.get(mirror, :held_payments, [])

        {matched, kept} =
          Enum.split_with(held, fn row ->
            Map.get(row, :budget_identity) == beneficiary and
              (Map.get(row, :idempotency_key) == key or
                 (is_binary(ref) and ref != "" and Map.get(row, :ref) == ref))
          end)

        {matched, Map.put(mirror, :held_payments, kept)}
      end)

    # (C1) The durable clear is NOT conditional on the mirror having matched.
    # The instance that credits a released payment is frequently NOT the one
    # that recorded the hold (a deploy in between, or a second orchestrator),
    # and its mirror is empty by construction — clearing only what the mirror
    # knows would leave the durable row behind, and the next restart would
    # resurrect a "held for review" notice for money that is already credited.
    durable_cleared = durable_clear_held_payment(state, key, ref, beneficiary)

    if cleared != [] or durable_cleared > 0 do
      Logger.info(
        "llm_proxy: hold cleared by a credit for #{inspect(beneficiary)} key=#{key} " <>
          "(#{length(cleared)} mirror, #{durable_cleared} durable)"
      )

      bump_store_metric(
        resolve_store_mod(state),
        "llm_payments_held_cleared",
        %{idempotency_key: key, entries: length(cleared), durable: durable_cleared},
        1
      )
    end

    :ok
  end

  # Best-effort by design and never fatal: a credit that landed must not be
  # undone because the notice bookkeeping failed. A failure here is loud
  # (log + counter) and self-healing — `list_llm_held_payments/1` also excludes
  # rows whose key is already in the credit ledger, so the stale notice does not
  # outlive the next read even if this write never succeeds.
  defp durable_clear_held_payment(state, key, ref, beneficiary) do
    store_mod = resolve_store_mod(state)

    if store_callback?(store_mod, :clear_llm_held_payment, 3) do
      case safe_store_call(store_mod, :clear_llm_held_payment, [beneficiary, key, ref]) do
        {:ok, count} when is_integer(count) and count >= 0 ->
          count

        :ok ->
          0

        other ->
          Logger.error(
            "llm_proxy: durable held-payment CLEAR failed for #{inspect(key)}: #{inspect(other)}"
          )

          bump_store_metric(
            store_mod,
            "llm_payments_held_clear_failed",
            %{idempotency_key: key},
            1
          )

          0
      end
    else
      0
    end
  end

  @doc """
  Unresolved held (hub-quarantined) payments for ONE budget identity, oldest
  first, from the in-memory mirror ONLY. Read-only, never raises. Only ever
  consulted behind a `credits_enabled` gate, so a feature-off install never
  touches it.

  Prefer `held_payments/3`: the mirror is bounded and process-local, so this
  answer is erased by every restart.
  """
  @doc since: "0.4.0"
  def held_payments(pid \\ @state_name, budget_identity) do
    mirror_held_payments(pid, budget_identity)
  end

  @doc """
  Unresolved held payments for ONE budget identity — DURABLE-FIRST, with the
  same shape `credit_balance/3` uses.

  (C1) A hold is money the user watched leave their wallet and did not get
  credited. The only thing that tells them so is a sentence built from this
  list, and until 0.4.0 that list lived exclusively in a bounded in-process
  mirror: one deploy and the user was blocked, already paid, being told to pay
  again, with `quota_status` asserting there was no hold. So when the store
  exports `list_llm_held_payments/1` it is AUTHORITATIVE — including when it
  answers an empty list, which means "resolved", not "unknown". The mirror is
  the fallback for a store that does not export it (behaviour identical to
  0.3.0) or that fails, where a stale sentence beats a lost one.

  Never raises.
  """
  @doc since: "0.4.0"
  def held_payments(pid, store_mod, budget_identity) do
    case durable_held_payments(store_mod, budget_identity) do
      rows when is_list(rows) -> rows
      nil -> mirror_held_payments(pid, budget_identity)
    end
  end

  defp mirror_held_payments(pid, budget_identity) do
    Agent.get(pid, fn mirror ->
      mirror
      |> Map.get(:held_payments, [])
      |> Enum.filter(&(Map.get(&1, :budget_identity) == budget_identity))
    end)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp durable_held_payments(store_mod, budget_identity) do
    if store_callback?(store_mod, :list_llm_held_payments, 1) and is_binary(budget_identity) do
      case safe_store_call(store_mod, :list_llm_held_payments, [budget_identity]) do
        {:ok, rows} when is_list(rows) ->
          if length(rows) > @held_read_limit do
            Logger.warning(
              "llm_proxy: durable held-payment read for #{inspect(budget_identity)} returned " <>
                "#{length(rows)} rows — truncating to #{@held_read_limit}; the held total the " <>
                "user is shown is a PARTIAL sum (the store is expected to cap this read)"
            )
          end

          rows
          |> Enum.take(@held_read_limit)
          |> Enum.map(&normalize_held_row(&1, budget_identity))

        other ->
          Logger.warning(
            "llm_proxy: durable held-payment read failed for #{inspect(budget_identity)}: #{inspect(other)} — falling back to the in-memory mirror"
          )

          nil
      end
    end
  end

  # The durable rows come from a host schema, so they are normalized to the
  # mirror's own shape before any surface reads them: `amount_usd` MUST be a
  # Decimal (the notice sums it) and `budget_identity` must be present (the
  # surfaces filter on it).
  defp normalize_held_row(row, budget_identity) when is_map(row) do
    row
    |> Map.put_new(:budget_identity, budget_identity)
    |> Map.put(:amount_usd, decimal(Map.get(row, :amount_usd, Map.get(row, "amount_usd", 0))))
  end

  defp normalize_held_row(_row, budget_identity),
    do: %{budget_identity: budget_identity, amount_usd: Decimal.new("0")}

  defp held_for_identity(state_pid, store_mod, budget_identity),
    do: held_payments(state_pid, store_mod, budget_identity)

  @doc """
  The single user-visible sentence appended to a budget-block notice when the
  identity has unresolved held payments — `nil` when it has none.

  (C1) A hold means money the user watched leave their wallet arrived and was
  deliberately NOT credited. Saying nothing while blocking them is a support
  incident by design, so this rides the existing block notice (same dedup and
  `notice_repeat_ms` rate limit). All holds for the identity are summed into
  ONE sentence — the line is appended at most once per notice.
  """
  @doc since: "0.4.0"
  def held_notice_line(pid \\ @state_name, budget_identity)

  def held_notice_line(pid, budget_identity), do: held_notice_line(pid, nil, budget_identity)

  @doc """
  The same sentence, built DURABLE-FIRST (see `held_payments/3`). This is the
  arity the block notice uses: the notice is the user's only signal that their
  money is held, so it must not be erased by a deploy.
  """
  @doc since: "0.4.0"
  def held_notice_line(pid, store_mod, budget_identity) when is_binary(budget_identity) do
    case held_payments(pid, store_mod, budget_identity) do
      [] ->
        nil

      held ->
        total =
          Enum.reduce(held, Decimal.new("0"), fn row, acc ->
            Decimal.add(acc, decimal(Map.get(row, :amount_usd, 0)))
          end)

        "Payment received but held for review: $#{money2(total)} — not credited yet. " <>
          "An operator has to release it."
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  def held_notice_line(_pid, _store_mod, _budget_identity), do: nil

  defp credit_payment(msg, state) do
    case apply_payment(msg, state, "push") do
      {:duplicate, _key} ->
        {:reply, Jason.encode!(%{ok: true, duplicate: true}), state}

      {:applied, credited, balance, _key} ->
        {:reply,
         Jason.encode!(%{ok: true, credited_usd: money2(credited), balance_usd: money2(balance)}),
         state}

      {:transient, key} ->
        # (X4) Fail CLOSED per spec: apply_credit_entry/3 has released its
        # seen-mark, so the exact key remains retryable.
        Logger.error(
          "llm_proxy: credit entry store write FAILED — credit NOT applied (fails " <>
            "closed per spec; retryable, key not consumed); key=#{key}"
        )

        store_mod = resolve_store_mod(state)
        bump_credit_degraded_metric(store_mod)

        {:reply,
         Jason.encode!(%{
           ok: false,
           error: "store_unavailable",
           retryable: true
         }), state}

      {:permanent, "reserved_method", _key} ->
        {:reply, Jason.encode!(%{ok: false, error: "reserved_method"}), state}

      {:permanent, _reason, _key} ->
        {:reply, Jason.encode!(%{ok: false, error: "bad_payment_confirmed"}), state}
    end
  end

  # One validating payment-to-credit path for both push and poll. The push
  # handler retains its existing trust/namespace behavior; the poll consumer
  # uses the same guards and classifies their failures as permanent rows.
  defp apply_payment(msg, state, source) do
    cond do
      not payment_namespace_match?(msg, state) ->
        {:permanent, "namespace_mismatch", payment_key(msg)}

      Map.get(msg, "method") == "debit" ->
        # "debit:<request_id>" is the ledger's reserved internal keyspace.
        {:permanent, "reserved_method", payment_key(msg)}

      true ->
        apply_validated_payment(msg, state, source)
    end
  end

  defp apply_validated_payment(msg, state, source) do
    with {:ok, amount} <- parse_money(Map.get(msg, "amount_usd")),
         true <- Decimal.compare(amount, Decimal.new(0)) == :gt,
         beneficiary when is_binary(beneficiary) and beneficiary != "" <-
           Map.get(msg, "beneficiary"),
         method when is_binary(method) and method != "" <- Map.get(msg, "method"),
         # The idempotency key is the plain "#{method}:#{ref}" join. A colon
         # in method makes distinct component pairs collide; ref may contain
         # colons freely.
         false <- String.contains?(method, ":"),
         ref when is_binary(ref) and ref != "" <- Map.get(msg, "ref") do
      per_usd = decimal(Map.get(state, :credit_per_usd, Decimal.new("1.0")))
      credited = Decimal.mult(amount, per_usd)
      key = "#{method}:#{ref}"
      meta = payment_credit_meta(msg, per_usd, source, method, ref)

      entry = %{
        idempotency_key: key,
        budget_identity: beneficiary,
        amount_usd: credited,
        kind: "credit",
        at: DateTime.utc_now(),
        meta: meta
      }

      state_pid = Map.get(state, :state_pid, @state_name)
      store_mod = resolve_store_mod(state)

      case apply_credit_entry(state_pid, store_mod, entry) do
        :duplicate ->
          clear_held_payment(state, key, ref, beneficiary)
          {:duplicate, key}

        {:ok, balance} ->
          clear_held_payment(state, key, ref, beneficiary)
          # (0.4.0) A GENUINELY NEW credit — apply_credit_entry/3 only reaches
          # this branch once per idempotency key; a re-delivered/re-polled
          # settlement resolves :duplicate above and never reaches here. Best
          # effort, money-first: the credit above already stands regardless
          # of what happens next.
          #
          # An operator "retry" credits SILENTLY (product decision,
          # 2026-07-27): the operator is fixing plumbing, and a surprise
          # "payment received" minutes or days after the payment reads as a
          # second charge. Push and poll — the two organic routes — notify.
          if source != "retry" do
            send_credit_notice(state, beneficiary, credited, balance, %{
              method: method,
              ref: ref,
              idempotency_key: key
            })
          end

          {:applied, credited, balance, key}

        {:error, :store_unavailable} ->
          {:transient, key}
      end
    else
      _ -> {:permanent, "bad_payment_confirmed", payment_key(msg)}
    end
  end

  # ── payment-received notice (0.4.0) ────────────────────────────────────────
  #
  # Mirrors the block notice's delivery seam (deliver_fn -> :sender via
  # `slot_reply`) but fires on the OPPOSITE event: a credit was just applied,
  # not blocked. Called from exactly one place — `apply_validated_payment/3`'s
  # `{:ok, balance}` branch — which is itself reachable ONLY from the already
  # trust-gated `handle_payment_confirmed/3` (payments_source), the
  # `poll_payments` consumer (poll_sources), and the operator `retry_stuck`
  # action (operator_sources). There is no route from an ordinary agent
  # request into this function, so an untrusted sender can never paint a
  # "payment received" message onto any conversation.
  #
  # Best-effort, money-first: this runs strictly AFTER the credit is durably
  # applied (apply_credit_entry/3 already returned `{:ok, _}`), and nothing
  # here can revert it. Every failure mode — the toggle is off, no session is
  # bound to this budget identity yet, or delivery itself raises/exits — is
  # swallowed with a counter bump on the last one, never a crash and never a
  # second attempt (the ledger entry is already the single source of truth
  # for "credited"; this is only the user-visible echo of it).
  # Two routes, tried in this order, because they answer in different places:
  #
  #   1. A live notifiable session — the notice lands in the conversation
  #      thread the user is already in, exactly like a block notice.
  #   2. The DURABLE origin recorded when that identity was last bound.
  #
  # Route 2 is not a fallback for a rare case: it is the NORMAL case. A credit
  # lands when the chain confirms, which is minutes after the user asked to
  # top up and often after a restart, and a top-up is a command — it opens no
  # LLM session at all. A first live run of the payments lane credited the
  # user and announced nothing, because route 1 was the only route. Whichever
  # route answers, the money was already credited before we got here.
  defp send_credit_notice(state, budget_identity, credited, balance, payment) do
    if credit_notice_enabled?(state) do
      case Map.get(state, :credit_notice_fn) do
        fun when is_function(fun, 1) ->
          # The payment's own identifiers travel with it: a host presenting
          # this credit as the last state of something it started (an order,
          # a card, an invoice) needs to know WHICH payment landed, and
          # nothing else here can tell it.
          fun.(
            Map.merge(payment, %{
              budget_identity: budget_identity,
              credited: credited,
              balance: balance
            })
          )

        _ ->
          route_credit_notice(state, budget_identity, credited, balance)
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp route_credit_notice(state, budget_identity, credited, balance) do
    case state
         |> Map.get(:state_pid, @state_name)
         |> notifiable_session_for_budget(budget_identity) do
      nil ->
        state
        |> budget_origin_conversation(budget_identity)
        |> deliver_credit_notice_to_conversation(state, budget_identity, credited, balance)

      session ->
        deliver_credit_notice(session, state, credited, balance)
    end
  end

  # The conversation this budget identity was last bound to, or nil when the
  # host keeps no origin record (the callback is optional) or never bound it.
  defp budget_origin_conversation(state, budget_identity) do
    store_mod = resolve_store_mod(state)

    if is_atom(store_mod) and not is_nil(store_mod) and Code.ensure_loaded?(store_mod) and
         function_exported?(store_mod, :llm_budget_origin, 1) do
      case store_mod.llm_budget_origin(budget_identity) do
        {:ok, origin} when is_map(origin) ->
          case Map.get(origin, :conversation_id) || Map.get(origin, "conversation_id") do
            cid when is_binary(cid) and cid != "" -> cid
            _ -> nil
          end

        _ ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp credit_notice_enabled?(state), do: Map.get(state, :credit_notice_enabled, true) != false

  defp credit_notice_fn(config) do
    case Map.get(config, :credit_notice_fn) do
      fun when is_function(fun, 1) -> fun
      _ -> nil
    end
  end

  # The FIRST session bound to this budget identity that is not itself a
  # background (notify: false) slot — a background summarizer sharing the
  # conversation's budget identity must never become the notice's target any
  # more than it becomes a block notice's target (see `session_notify?/1`).
  # `nil` (no session ever bound for this identity — e.g. a deposit made
  # before the user's first request) means there is no route and the notice
  # is silently skipped, same stance as every other best-effort seam here.
  defp notifiable_session_for_budget(pid, budget_identity) do
    Agent.get(pid, fn mirror ->
      mirror
      |> Map.get(:sessions, %{})
      |> Map.values()
      |> Enum.find(fn session ->
        session.budget_identity == budget_identity and Map.get(session, :notify, true) != false
      end)
    end)
  rescue
    _ -> nil
  end

  defp deliver_credit_notice(nil, _state, _credited, _balance), do: :ok

  defp deliver_credit_notice(session, state, credited, balance) do
    swarm_name = Map.get(state, :swarm_name, "swarm")
    sender = Map.get(state, :sender, :sender)
    deliver_fn = Map.get(state, :deliver_fn)

    if is_binary(swarm_name) and not is_nil(sender) and is_function(deliver_fn, 4) do
      msg =
        Jason.encode!(%{
          action: "slot_reply",
          slot: session.slot,
          content: credit_notice_text(credited, balance)
        })

      deliver_fn.(swarm_name, sender, :llm_proxy, msg)
    end

    :ok
  rescue
    e ->
      Logger.warning("llm_proxy: credit notice delivery raised: #{Exception.message(e)}")
      bump_credit_notice_failed_metric(state, session.budget_identity)
  catch
    kind, reason ->
      Logger.warning("llm_proxy: credit notice delivery #{kind}: #{inspect(reason)}")
      bump_credit_notice_failed_metric(state, session.budget_identity)
  end

  defp deliver_credit_notice_to_conversation(nil, _state, _budget_identity, _credited, _balance),
    do: :ok

  defp deliver_credit_notice_to_conversation(
         conversation_id,
         state,
         budget_identity,
         credited,
         balance
       ) do
    swarm_name = Map.get(state, :swarm_name, "swarm")
    sender = Map.get(state, :sender, :sender)
    deliver_fn = Map.get(state, :deliver_fn)

    if is_binary(swarm_name) and not is_nil(sender) and is_function(deliver_fn, 4) do
      # "send" rather than "slot_reply": there is no slot to reply into. The
      # target is never invented here — it is read back from the origin the
      # proxy itself recorded when a session bound this identity.
      msg =
        Jason.encode!(%{
          action: "send",
          conversation_id: conversation_id,
          content: credit_notice_text(credited, balance)
        })

      deliver_fn.(swarm_name, sender, :llm_proxy, msg)
    end

    :ok
  rescue
    e ->
      Logger.warning("llm_proxy: credit notice delivery raised: #{Exception.message(e)}")
      bump_credit_notice_failed_metric(state, budget_identity)
  catch
    kind, reason ->
      Logger.warning("llm_proxy: credit notice delivery #{kind}: #{inspect(reason)}")
      bump_credit_notice_failed_metric(state, budget_identity)
  end

  defp bump_credit_notice_failed_metric(state, budget_identity) do
    bump_store_metric(
      resolve_store_mod(state),
      "llm_payments_credit_notice_failed",
      %{budget_identity: budget_identity},
      1
    )
  end

  defp credit_notice_text(credited, balance) do
    "💳 Payment received — $#{money2(credited)} credited. Prepaid balance: $#{money2(balance)}."
  end

  defp payment_namespace_match?(msg, state) do
    normalize_namespace(Map.get(msg, "namespace")) ==
      normalize_namespace(Map.get(state, :credit_namespace, "default"))
  end

  defp payment_key(msg) do
    case {Map.get(msg, "method"), Map.get(msg, "ref")} do
      {method, ref} when is_binary(method) and is_binary(ref) -> "#{method}:#{ref}"
      _ -> Map.get(msg, "idempotency_key")
    end
  end

  defp payment_credit_meta(msg, per_usd, source, method, ref) do
    existing =
      case Map.fetch(msg, "meta") do
        {:ok, nil} ->
          %{}

        :error ->
          %{}

        {:ok, meta} when is_map(meta) ->
          meta

        {:ok, _meta} ->
          Logger.warning(
            "llm_proxy: dropping non-map hub payment meta; " <>
              "source=#{source}"
          )

          %{}
      end

    stamped = %{
      "method" => method,
      "ref" => ref,
      "credit_per_usd" => Decimal.to_string(per_usd, :normal),
      "source" => source
    }

    stamped =
      case Map.get(msg, "outbox_seq") do
        seq when is_integer(seq) and seq >= 0 -> Map.put(stamped, "outbox_seq", seq)
        _ -> stamped
      end

    Map.merge(existing, stamped)
  end

  # Durable outbox consumer. Every refusal is an explicit reply because cron
  # ticks must be diagnosable; push remains the unchanged low-latency path.
  defp handle_poll_payments(from, state) do
    cond do
      not poll_source_allowed?(from, Map.get(state, :poll_sources, [])) ->
        poll_error(state, "untrusted_poll_source")

      not is_function(Map.get(state, :settlements_fn), 2) ->
        poll_error(state, "settlements_fn_not_configured")

      not Map.get(state, :credits_enabled, false) ->
        poll_error(state, "credits_disabled")

      true ->
        poll_payments(state)
    end
  end

  defp poll_error(state, error) do
    {:reply,
     Jason.encode!(%{
       action: "poll_payments",
       ok: false,
       error: error
     }), state}
  end

  defp poll_source_allowed?(from, sources) when is_list(sources) do
    with {:ok, stamped} <- scalar_string(from) do
      Enum.any?(sources, fn configured ->
        case scalar_string(configured) do
          {:ok, source} -> source == stamped
          :error -> false
        end
      end)
    else
      :error -> false
    end
  end

  defp poll_source_allowed?(_from, _sources), do: false

  defp scalar_string(value) when is_binary(value) or is_atom(value) or is_number(value),
    do: {:ok, to_string(value)}

  defp scalar_string(_value), do: :error

  # ── (R4-P4-I5) the stuck queue: READ it, and RETRY it ──────────────────────
  #
  # A settled row this proxy classifies `{:permanent, _}` is recorded as stuck
  # and the poll cursor ADVANCES PAST IT. Money that arrived, was not credited,
  # and is then unreachable by every path at once — below the cursor for the
  # poll, `already_settled` for the hub's release, unreadable, unrendered — is
  # the same one-way door the durable hold closed, relocated one lane over.
  # These two actions are the door handle on this side:
  #
  #   * `stuck_payments` — SEE it. A read, nothing else.
  #   * `retry_stuck`  — re-apply ONE row through `apply_payment/3`, the SAME
  #     validating path the push and the poll use. It is not a credit verb: it
  #     mints nothing, bypasses nothing, and a row that is genuinely invalid
  #     fails again with its reason recorded and STAYS in the queue. A row that
  #     was stuck by a since-fixed cause credits exactly once — the ledger's
  #     global idempotency key is what guarantees the "once", not this code.
  #
  # AUTHORIZATION is the same shape `poll_payments` uses (an exact-match source
  # allowlist, explicit refusal, never a silent drop) against a SEPARATE list
  # that defaults to empty. Separate because the two authorities are different:
  # driving the credit poll is not the same permission as reaching into the
  # money that the credit poll rejected.
  defp handle_stuck_payments(from, msg, state) do
    cond do
      not operator_source_allowed?(from, state) ->
        stuck_refusal(state, "stuck_payments", "untrusted_operator_source", msg)

      not Map.get(state, :credits_enabled, false) ->
        stuck_refusal(state, "stuck_payments", "credits_disabled", msg)

      true ->
        read_stuck_payments(msg, state)
    end
  end

  defp handle_retry_stuck(from, msg, state) do
    cond do
      not operator_source_allowed?(from, state) ->
        stuck_refusal(state, "retry_stuck", "untrusted_operator_source", msg)

      not Map.get(state, :credits_enabled, false) ->
        stuck_refusal(state, "retry_stuck", "credits_disabled", msg)

      true ->
        case stuck_key_arg(msg) do
          nil -> stuck_refusal(state, "retry_stuck", "bad_request", msg)
          key -> retry_stuck_payment(key, state)
        end
    end
  end

  defp operator_source_allowed?(from, state),
    do: poll_source_allowed?(from, Map.get(state, :operator_sources, []))

  defp stuck_key_arg(msg) do
    case Map.get(msg, "idempotency_key") do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  # Every refusal is explicit and echoes the key it was asked about: these are
  # typed by a human at a console, and a silent drop is indistinguishable from
  # a broken proxy.
  defp stuck_refusal(state, action, error, msg) do
    if error == "untrusted_operator_source" do
      Logger.warning("llm_proxy: refused #{action} from a source outside operator_sources")
    end

    body = %{action: action, ok: false, error: error}

    body =
      case stuck_key_arg(msg || %{}) do
        nil -> body
        key -> Map.put(body, :idempotency_key, key)
      end

    {:reply, Jason.encode!(body), state}
  end

  defp read_stuck_payments(msg, state) do
    case stuck_lookup(state, stuck_key_arg(msg)) do
      {:ok, rows} ->
        # ONE STUCK PAYMENT IS ONE ROW HERE, however many times it was recorded.
        # The durable queue deliberately has no key uniqueness — a settlement
        # can become stuck again after a restart or a mirror eviction and every
        # repeat is operator evidence worth keeping — but this surface reports
        # MONEY. Counting rows would show a single stuck settlement N times and
        # add its amount into `total_usd` N times, which is a number nobody can
        # act on. A key-less row (no idempotency_key derivable) is its own
        # identity: collapsing those together would hide distinct money.
        payments = Enum.uniq_by(rows, &(row_value(&1, :idempotency_key) || &1))
        shown = Enum.take(payments, @stuck_read_limit)

        body = %{
          action: "stuck_payments",
          ok: true,
          count: length(shown),
          total_usd: money2(stuck_total(shown)),
          complete: length(payments) <= @stuck_read_limit,
          rows: Enum.map(shown, &stuck_row_view/1)
        }

        # Echo the key a scoped read named, like every refusal does: a caller
        # correlating an async reply must not have to guess "most recent".
        body =
          case stuck_key_arg(msg) do
            nil -> body
            key -> Map.put(body, :idempotency_key, key)
          end

        {:reply, Jason.encode!(body), state}

      :no_store ->
        stuck_refusal(state, "stuck_payments", "no_stuck_store", msg)

      {:error, _why} ->
        stuck_refusal(state, "stuck_payments", "store_unavailable", msg)
    end
  end

  defp retry_stuck_payment(key, state) do
    case stuck_lookup(state, key) do
      {:ok, []} ->
        # Not a failure to hide: "this key is not in the unresolved queue" is
        # also the answer after a successful retry, which is exactly right.
        {:reply,
         Jason.encode!(%{
           action: "retry_stuck",
           ok: false,
           error: "not_stuck",
           idempotency_key: key
         }), state}

      {:ok, [row | _]} ->
        apply_stuck_retry(key, row, state)

      :no_store ->
        stuck_refusal(state, "retry_stuck", "no_stuck_store", %{"idempotency_key" => key})

      {:error, _why} ->
        stuck_refusal(state, "retry_stuck", "store_unavailable", %{"idempotency_key" => key})
    end
  end

  defp apply_stuck_retry(key, row, state) do
    payload = row_value(row, :row)

    if is_map(payload) do
      # THE SAME validating path a push and a poll take — including the
      # namespace gate and the reserved-method gate. `apply_payment/3` is the
      # only way credit is ever applied in this module and this is not an
      # exception to that.
      case apply_payment(poll_payment_message(payload), state, "retry") do
        {:applied, credited, balance, credit_key} ->
          finish_stuck_retry(key, state, %{
            credited_usd: money2(credited),
            balance_usd: money2(balance),
            credit_key: credit_key,
            duplicate: false
          })

        {:duplicate, credit_key} ->
          # The money is already in the ledger; the queue row is stale. Clearing
          # it is the whole point of answering `:duplicate` here.
          finish_stuck_retry(key, state, %{credit_key: credit_key, duplicate: true})

        {:transient, _credit_key} ->
          bump_store_metric(
            resolve_store_mod(state),
            "llm_payments_stuck_retry_failed",
            %{idempotency_key: key, reason: "store_unavailable"},
            1
          )

          {:reply,
           Jason.encode!(%{
             action: "retry_stuck",
             ok: false,
             error: "store_unavailable",
             retryable: true,
             idempotency_key: key
           }), state}

        {:permanent, reason, _credit_key} ->
          # Idempotent in the direction that matters: an invalid row fails the
          # SAME way every time, the reason is recorded durably (metric) and in
          # the reply, and the row is NOT cleared — it stays in the queue,
          # visible, rather than being silently re-stuck or silently dropped.
          Logger.error(
            "llm_proxy: retry_stuck #{inspect(key)} rejected again: #{inspect(reason)} — the row stays in the stuck queue"
          )

          bump_store_metric(
            resolve_store_mod(state),
            "llm_payments_stuck_retry_failed",
            %{idempotency_key: key, reason: reason},
            1
          )

          {:reply,
           Jason.encode!(%{
             action: "retry_stuck",
             ok: false,
             error: "still_invalid",
             reason: reason,
             idempotency_key: key
           }), state}
      end
    else
      Logger.error(
        "llm_proxy: stuck row #{inspect(key)} carries no settlement payload to retry: #{inspect(payload)}"
      )

      {:reply,
       Jason.encode!(%{
         action: "retry_stuck",
         ok: false,
         error: "invalid_stuck_row",
         idempotency_key: key
       }), state}
    end
  end

  # The credit landed (or was already there). Clearing the queue row is
  # best-effort and NEVER undoes the credit — but it must be DURABLE to be
  # worth anything, so a failed clear is said out loud (`cleared: false`)
  # rather than reported as a tidy success.
  defp finish_stuck_retry(key, state, detail) do
    cleared = durable_clear_stuck_payment(state, key)
    forget_stuck_payment(state, key)

    bump_store_metric(
      resolve_store_mod(state),
      "llm_payments_stuck_retried",
      %{idempotency_key: key, duplicate: detail.duplicate, cleared: cleared},
      1
    )

    Logger.warning(
      "llm_proxy: retry_stuck #{key} credited (duplicate=#{detail.duplicate}); #{cleared} durable queue row(s) cleared"
    )

    body =
      detail
      |> Map.take([:credited_usd, :balance_usd, :duplicate])
      |> Map.merge(%{
        action: "retry_stuck",
        ok: true,
        idempotency_key: key,
        cleared: cleared > 0
      })

    {:reply, Jason.encode!(body), state}
  end

  defp stuck_lookup(state, key) do
    store_mod = resolve_store_mod(state)

    if store_callback?(store_mod, :list_llm_stuck_payments, 1) do
      case safe_store_call(store_mod, :list_llm_stuck_payments, [key]) do
        {:ok, rows} when is_list(rows) ->
          {:ok, rows}

        other ->
          Logger.error("llm_proxy: stuck-payment read failed: #{inspect(other)}")
          {:error, other}
      end
    else
      :no_store
    end
  end

  defp durable_clear_stuck_payment(state, key) do
    store_mod = resolve_store_mod(state)

    if store_callback?(store_mod, :clear_llm_stuck_payment, 1) do
      case safe_store_call(store_mod, :clear_llm_stuck_payment, [key]) do
        {:ok, count} when is_integer(count) and count >= 0 ->
          count

        other ->
          Logger.error(
            "llm_proxy: durable stuck-payment CLEAR failed for #{inspect(key)}: #{inspect(other)}"
          )

          bump_store_metric(
            store_mod,
            "llm_payments_stuck_clear_failed",
            %{idempotency_key: key},
            1
          )

          0
      end
    else
      0
    end
  end

  # The mirror is this module's dedupe horizon for `record_stuck_payment/4`.
  # Leaving a retried key in it would make a genuine LATER re-stuck of the same
  # key invisible (deduped away), and would keep inflating `quota_status`'s
  # stuck count for money that is now credited.
  defp forget_stuck_payment(state, key) do
    Agent.update(Map.get(state, :state_pid, @state_name), fn mirror ->
      stuck = Map.get(mirror, :stuck_payments, [])
      Map.put(mirror, :stuck_payments, Enum.reject(stuck, &(stuck_key(&1) == key)))
    end)

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp stuck_total(rows) do
    Enum.reduce(rows, Decimal.new("0"), fn row, acc ->
      payload = row_value(row, :row)
      amount = if is_map(payload), do: row_value(payload, :amount_usd), else: nil
      Decimal.add(acc, decimal(amount || 0))
    end)
  end

  defp stuck_row_view(row) do
    payload = if is_map(row_value(row, :row)), do: row_value(row, :row), else: %{}

    %{
      idempotency_key: row_value(row, :idempotency_key),
      beneficiary: row_value(payload, :beneficiary),
      amount_usd: money2(decimal(row_value(payload, :amount_usd) || 0)),
      method: row_value(payload, :method),
      ref: row_value(payload, :ref),
      reason: row_value(row, :reason),
      at: stuck_at_text(row_value(row, :at))
    }
  end

  defp stuck_at_text(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp stuck_at_text(value) when is_binary(value), do: value
  defp stuck_at_text(_), do: nil

  defp poll_payments(state) do
    consumer = Map.get(state, :payments_consumer, "llm_proxy")

    case read_payments_cursor(state, consumer) do
      {:ok, cursor} ->
        lag_window = Map.get(state, :poll_lag, 100)
        limit = Map.get(state, :poll_limit, 100)
        after_seq = max(0, cursor - lag_window)
        fetch_limit = lag_window + limit

        case call_settlements_fn(Map.get(state, :settlements_fn), after_seq, fetch_limit) do
          {:ok, page} -> finish_payments_poll(page, cursor, state, consumer)
          {:error, reason} -> poll_read_error(reason, state)
        end

      {:error, reason} ->
        Logger.error(
          "llm_proxy: payments cursor read failed for #{inspect(consumer)}: #{inspect(reason)}"
        )

        bump_store_metric(
          resolve_store_mod(state),
          "llm_payments_cursor_read_failed",
          %{consumer: consumer},
          1
        )

        poll_error(state, "cursor_unavailable")
    end
  end

  defp call_settlements_fn(settlements_fn, after_seq, limit) do
    case settlements_fn.(after_seq, limit) do
      {:ok,
       %{
         settlements: rows,
         max_seq: max_seq,
         next_seq: next_seq,
         complete: complete
       }}
      when is_list(rows) and is_integer(max_seq) and max_seq >= 0 and
             is_integer(next_seq) and next_seq >= 0 and is_boolean(complete) ->
        if Enum.all?(rows, &is_map/1) do
          {:ok,
           %{
             settlements: rows,
             max_seq: max_seq,
             next_seq: next_seq,
             complete: complete
           }}
        else
          {:error, :bad_settlements_reply}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:bad_settlements_reply, other}}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp poll_read_error(reason, state) do
    Logger.error("llm_proxy: settlements poll read failed: #{inspect(reason)}")

    bump_store_metric(
      resolve_store_mod(state),
      "llm_payments_read_failed",
      %{reason: inspect(reason)},
      1
    )

    poll_error(state, "settlements_unavailable")
  end

  defp finish_payments_poll(%{max_seq: max_seq} = page, cursor, state, consumer)
       when cursor > max_seq do
    Logger.error(
      "llm_proxy: payments cursor ahead of hub max_seq; consumer=#{inspect(consumer)} " <>
        "cursor=#{cursor} max_seq=#{max_seq}; refusing rewind"
    )

    store_mod = resolve_store_mod(state)

    bump_store_metric(
      store_mod,
      "llm_payments_cursor_ahead",
      %{consumer: consumer, cursor: cursor, max_seq: max_seq},
      1
    )

    lag = max_seq - cursor
    bump_store_metric(store_mod, "llm_payments_lag", %{consumer: consumer}, lag)
    remember_poll_status(state, cursor, max_seq, lag)

    {:reply,
     Jason.encode!(%{
       action: "poll_payments",
       ok: true,
       applied: 0,
       duplicates: 0,
       stuck: 0,
       deferred: length(page.settlements),
       cursor: cursor,
       max_seq: max_seq,
       lag: lag,
       anomaly: "cursor_ahead"
     }), state}
  end

  defp finish_payments_poll(page, cursor, state, consumer) do
    rows = Enum.sort_by(page.settlements, &settlement_sort_key/1)
    total = length(rows)

    disposition =
      Enum.reduce_while(rows, empty_disposition(cursor), fn row, acc ->
        msg = poll_payment_message(row)

        case apply_payment(msg, state, "poll") do
          {:applied, _credited, _balance, _key} ->
            {:cont,
             acc
             |> Map.update!(:applied, &(&1 + 1))
             |> resolved_row(row)}

          {:duplicate, _key} ->
            {:cont,
             acc
             |> Map.update!(:duplicates, &(&1 + 1))
             |> resolved_row(row)}

          {:transient, key} ->
            Logger.error(
              "llm_proxy: payments poll stopped at transient credit write failure; " <>
                "key=#{inspect(key)} outbox_seq=#{inspect(row_value(row, :outbox_seq))}"
            )

            {:halt, %{acc | stopped: true}}

          {:permanent, reason, key} ->
            settlement_key = row_value(row, :idempotency_key) || key
            record_stuck_payment(row, reason, settlement_key, state)

            {:cont,
             acc
             |> Map.update!(:stuck, &(&1 + 1))
             |> resolved_row(row)}
        end
      end)

    deferred = total - disposition.resolved

    requested_cursor =
      if disposition.stopped do
        disposition.last_resolved_seq
      else
        # Binding pin: this is the hub's UNFILTERED page cursor. Never derive
        # it from the filtered settlement rows. A stale hub cursor may never
        # rewind the durable consumer cursor.
        max(page.next_seq, cursor)
      end

    effective_cursor =
      if requested_cursor == cursor do
        cursor
      else
        case write_payments_cursor(state, consumer, requested_cursor) do
          :ok ->
            requested_cursor

          {:error, reason} ->
            Logger.error(
              "llm_proxy: payments cursor write failed for #{inspect(consumer)} at " <>
                "#{requested_cursor}: #{inspect(reason)}; credits remain idempotently replayable"
            )

            bump_store_metric(
              resolve_store_mod(state),
              "llm_payments_cursor_write_failed",
              %{consumer: consumer, cursor: requested_cursor},
              1
            )

            cursor
        end
      end

    lag = page.max_seq - effective_cursor
    store_mod = resolve_store_mod(state)
    bump_store_metric(store_mod, "llm_payments_lag", %{consumer: consumer}, lag)
    remember_poll_status(state, effective_cursor, page.max_seq, lag)

    {:reply,
     Jason.encode!(%{
       action: "poll_payments",
       ok: true,
       applied: disposition.applied,
       duplicates: disposition.duplicates,
       stuck: disposition.stuck,
       deferred: deferred,
       cursor: effective_cursor,
       max_seq: page.max_seq,
       lag: lag
     }), state}
  end

  defp empty_disposition(cursor) do
    %{
      applied: 0,
      duplicates: 0,
      stuck: 0,
      resolved: 0,
      stopped: false,
      # The durable cursor proves rows through it were previously resolved.
      # This floor prevents a transient encountered in the trailing reread
      # from rewinding the cursor behind already-resolved history.
      last_resolved_seq: cursor
    }
  end

  defp resolved_row(acc, row) do
    seq = row_value(row, :outbox_seq)

    %{
      acc
      | resolved: acc.resolved + 1,
        last_resolved_seq:
          if(is_integer(seq) and seq >= 0,
            do: max(acc.last_resolved_seq, seq),
            else: acc.last_resolved_seq
          )
    }
  end

  defp settlement_sort_key(row) do
    case row_value(row, :outbox_seq) do
      seq when is_integer(seq) and seq >= 0 -> {0, seq}
      _ -> {1, 0}
    end
  end

  # The direct hub seam returns its store-native Decimal. Convert that one
  # trusted representation to the same plain decimal string the push wire
  # carries; JSON numbers remain numbers and are rejected by parse_money/1.
  defp poll_payment_message(row) do
    amount =
      case row_value(row, :amount_usd) do
        %Decimal{} = decimal -> Decimal.to_string(decimal, :normal)
        other -> other
      end

    %{
      "beneficiary" => row_value(row, :beneficiary),
      "amount_usd" => amount,
      "method" => row_value(row, :method),
      "ref" => row_value(row, :ref),
      "namespace" => row_value(row, :namespace),
      "idempotency_key" => row_value(row, :idempotency_key),
      "outbox_seq" => row_value(row, :outbox_seq),
      "meta" => row_value(row, :meta)
    }
  end

  defp row_value(row, key) when is_map(row) do
    Map.get(row, key, Map.get(row, Atom.to_string(key)))
  end

  defp row_value(_row, _key), do: nil

  defp read_payments_cursor(state, consumer) do
    store_mod = resolve_store_mod(state)

    if cursor_store_ready?(store_mod) do
      case safe_store_call(store_mod, :llm_payments_cursor, [consumer]) do
        {:ok, nil} -> {:ok, 0}
        {:ok, cursor} when is_integer(cursor) and cursor >= 0 -> {:ok, cursor}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:bad_cursor_reply, other}}
      end
    else
      {:ok,
       Agent.get(Map.get(state, :state_pid, @state_name), fn mirror ->
         mirror
         |> Map.get(:payments_cursors, %{})
         |> Map.get(consumer, 0)
       end)}
    end
  end

  defp write_payments_cursor(state, consumer, cursor)
       when is_integer(cursor) and cursor >= 0 do
    store_mod = resolve_store_mod(state)

    if cursor_store_ready?(store_mod) do
      case safe_store_call(store_mod, :put_llm_payments_cursor, [consumer, cursor]) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:bad_cursor_write_reply, other}}
      end
    else
      Agent.update(Map.get(state, :state_pid, @state_name), fn mirror ->
        cursors = Map.get(mirror, :payments_cursors, %{})
        Map.put(mirror, :payments_cursors, Map.put(cursors, consumer, cursor))
      end)

      :ok
    end
  end

  defp cursor_store_ready?(store_mod) do
    is_atom(store_mod) and not is_nil(store_mod) and Code.ensure_loaded?(store_mod) and
      function_exported?(store_mod, :llm_payments_cursor, 1) and
      function_exported?(store_mod, :put_llm_payments_cursor, 2)
  end

  defp safe_store_call(store_mod, function, args) do
    apply(store_mod, function, args)
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp record_stuck_payment(row, reason, key, state) do
    record =
      row
      |> Map.put(:reason, reason)
      |> Map.put_new(:at, DateTime.utc_now())

    case remember_stuck_payment(state, record, key) do
      :already_present ->
        :ok

      :recorded ->
        store_mod = resolve_store_mod(state)

        if store_callback?(store_mod, :record_llm_stuck_payment, 1) do
          case safe_store_call(store_mod, :record_llm_stuck_payment, [record]) do
            :ok ->
              :ok

            other ->
              Logger.error(
                "llm_proxy: durable stuck-payment record failed for #{inspect(key)}: #{inspect(other)}"
              )

              bump_store_metric(
                store_mod,
                "llm_payments_stuck_store_failed",
                %{idempotency_key: key},
                1
              )
          end
        end

        bump_store_metric(
          store_mod,
          "llm_payments_stuck",
          %{idempotency_key: key},
          1
        )
    end
  end

  defp remember_stuck_payment(state, record, key) do
    state_pid = Map.get(state, :state_pid, @state_name)

    result =
      Agent.get_and_update(state_pid, fn mirror ->
        stuck = Map.get(mirror, :stuck_payments, [])

        if not is_nil(key) and Enum.any?(stuck, &(stuck_key(&1) == key)) do
          {{:already_present, []}, mirror}
        else
          appended = stuck ++ [record]
          overflow = max(length(appended) - @payments_stuck_limit, 0)
          evicted = Enum.take(appended, overflow)

          {{:recorded, evicted}, Map.put(mirror, :stuck_payments, Enum.drop(appended, overflow))}
        end
      end)

    {status, evicted} = result

    Enum.each(evicted, fn old ->
      Logger.warning(
        "llm_proxy: evicting oldest in-memory stuck payment mirror entry; " <>
          "idempotency_key=#{inspect(stuck_key(old))}"
      )
    end)

    status
  end

  defp stuck_key(row) do
    row_value(row, :idempotency_key) ||
      case {row_value(row, :method), row_value(row, :ref)} do
        {method, ref} when is_binary(method) and is_binary(ref) -> "#{method}:#{ref}"
        _ -> nil
      end
  end

  defp store_callback?(store_mod, function, arity) do
    is_atom(store_mod) and not is_nil(store_mod) and Code.ensure_loaded?(store_mod) and
      function_exported?(store_mod, function, arity)
  end

  defp bump_store_metric(store_mod, event, meta, value) do
    if store_callback?(store_mod, :bump_metric, 3) do
      store_mod.bump_metric(event, meta, value)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp remember_poll_status(state, cursor, max_seq, lag) do
    Agent.update(Map.get(state, :state_pid, @state_name), fn mirror ->
      Map.put(mirror, :payments_poll, %{cursor: cursor, max_seq: max_seq, lag: lag})
    end)
  end

  # Decimal.parse/1 also accepts "NaN"/"Infinity"/"-Infinity" (represented with
  # a non-integer :NaN/:inf coefficient) — a payment amount must be a finite
  # number: NaN would RAISE at the Decimal.compare/2 >0 guard downstream (an
  # upstream hub retrying a permanently-malformed payload forever), and
  # Infinity would pass the >0 guard and mint an infinite balance. Reject both
  # here so they fall to the same bad_payment_confirmed reply as any other
  # malformed amount.
  # (M4) Exponent forms are NOT part of the contract either: Decimal.parse/1
  # happily accepts "5e2" (= 500.00) with a finite integer coefficient, but
  # the wire contract is plain decimal strings only (the hub sends
  # Decimal.to_string/1 of a normalized amount) — a stray exponent is far
  # more likely a malformed/hostile payload than a legitimate five-hundred-
  # dollar top-up, so it falls to the same bad_payment_confirmed reply.
  defp parse_money(v) when is_binary(v) do
    with false <- String.contains?(v, ["e", "E"]),
         {%Decimal{coef: coef} = d, ""} when is_integer(coef) <- Decimal.parse(v) do
      {:ok, d}
    else
      _ -> :error
    end
  end

  defp parse_money(_), do: :error

  defp bump_credit_degraded_metric(store_mod) do
    if is_atom(store_mod) and not is_nil(store_mod) and Code.ensure_loaded?(store_mod) and
         function_exported?(store_mod, :bump_metric, 3) do
      store_mod.bump_metric("llm_proxy_budget_degraded", %{context: "payment_confirmed"}, 1)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
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
      fn -> %{sessions: %{}, usage: %{}, notified: %{}, global: %{}, credits: %{}} end,
      opts
    )
  end

  @doc "Default minimum interval (ms) between repeated block notices — 4 hours."
  def default_notice_repeat_ms, do: @default_notice_repeat_ms

  @doc """
  Should a block notice be delivered for `(budget_identity, reason, day)` NOW?

  Keeps a last-notified timestamp per {budget_identity, reason, day} (reason =
  the cap type, e.g. `:budget` / `:request_quota` / `:global`, so one cap type
  never silences another). Returns true — and atomically advances the
  timestamp — when no notice was sent yet today OR the last one is older than
  the minimum repeat interval; false otherwise.

  Options:

    * `:now` — the current instant (`DateTime`; `NaiveDateTime`/`Date`
      accepted). Defaults to `DateTime.utc_now/0`. Pass the proxy clock so
      tests stay deterministic.
    * `:repeat_ms` — minimum interval between notices for the same key.
      Defaults to #{@default_notice_repeat_ms} ms (4h). `0` or `nil` =
      legacy once-per-day (never repeat within the same UTC day).
    * `:variant` — an extra term folded into the dedup key (default `nil` =
      the plain 3-tuple key, byte-identical to the pre-0.4.0 behaviour). A
      caller passes it when the notice's CONTENT materially changed, so the
      new text is not swallowed by a rate limit set for the old text.

  State is **per proxy process lifetime** (a restart clears it and MAY
  re-notify — non-durable by design) and pruned to the requested `day` on
  each call so it cannot grow unbounded. Atomic under concurrency: exactly
  one of N racing callers for the same key sees true.
  """
  def notice_due?(pid \\ @state_name, budget_identity, reason, day, opts \\ [])

  def notice_due?(pid, budget_identity, reason, %Date{} = day, opts) when is_list(opts) do
    now = notice_now(Keyword.get(opts, :now))
    repeat_ms = Keyword.get(opts, :repeat_ms, @default_notice_repeat_ms)

    key =
      case Keyword.get(opts, :variant) do
        nil -> {budget_identity, reason, day}
        variant -> {budget_identity, reason, day, variant}
      end

    Agent.get_and_update(pid, fn state ->
      pruned =
        state
        |> Map.get(:notified)
        |> normalize_notified()
        |> Enum.filter(fn {k, _at} -> notice_key_day(k) == day end)
        |> Map.new()

      due? =
        case Map.get(pruned, key) do
          nil ->
            true

          %DateTime{} = last ->
            is_integer(repeat_ms) and repeat_ms > 0 and
              DateTime.diff(now, last, :millisecond) >= repeat_ms
        end

      # Map.put (not `%{state | ...}`) so a keyless Agent state (e.g. an older boot)
      # cannot KeyError.
      if due? do
        {true, Map.put(state, :notified, Map.put(pruned, key, now))}
      else
        {false, Map.put(state, :notified, pruned)}
      end
    end)
  end

  # The pre-0.2.19 shape was a MapSet of {bid, day}; an already-running state
  # Agent from an older boot must not crash the new code — treat as empty
  # (worst case: one extra notice, same as a restart).
  defp normalize_notified(%{} = map) when not is_struct(map), do: map
  defp normalize_notified(_), do: %{}

  # Day pruning must survive BOTH key shapes: the plain {bid, reason, day} and
  # the variant-bearing {bid, reason, day, variant}. Anything else (a key left
  # by an older boot) is dropped by returning a value that can never equal a
  # %Date{}.
  defp notice_key_day({_bid, _reason, day}), do: day
  defp notice_key_day({_bid, _reason, day, _variant}), do: day
  defp notice_key_day(_other), do: :unknown

  defp notice_now(nil), do: DateTime.utc_now()
  defp notice_now(%DateTime{} = dt), do: dt
  defp notice_now(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")
  defp notice_now(%Date{} = day), do: DateTime.new!(day, ~T[00:00:00], "Etc/UTC")

  @doc """
  Legacy shim (pre-0.2.19 API): delegates to `notice_due?/5` with reason
  `:budget` and the default repeat interval. Prefer `notice_due?/5`.
  """
  def notice_once?(pid \\ @state_name, budget_identity, %Date{} = day) do
    notice_due?(pid, budget_identity, :budget, day, [])
  end

  @doc """
  Register a session and mint its opaque bearer token.

  Recognized attrs: `:conversation_id`, `:slot`, `:kind` (required),
  `:workspace_key` (default `"default"`), `:daily_limit_usd`, and `:notify`
  (default `true`) — pass `notify: false` for background sessions (e.g. a
  summarizer slot sharing the conversation's budget identity) so a block
  neither sends the user a Telegram notice nor consumes the notice timestamp
  of the user-facing session.
  """
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
      daily_limit_usd: session_daily_limit(attrs),
      # notify: false = background session (e.g. a summarizer sharing the
      # conversation's budget identity): when blocked it neither delivers a
      # Telegram block notice NOR consumes/advances the notice timestamp, so it
      # can't starve the user-facing session's notice. Default true.
      notify: Map.get(attrs, :notify, true) != false
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

  @doc """
  The budget identity for a session: `"llmb_" <> url-safe-base64(sha256(...))`
  over exactly `workspace_key`, `kind`, `conversation_id`, NUL-joined in that
  order. `workspace_key` defaults to `"default"`; all three are `to_string/1`
  coerced, so an atom and its binary produce the SAME identity.

  ## Pinned host-facing contract (C4) — DO NOT CHANGE THE SHAPE

  This is a **public, stable contract**, not an internal detail. Hosts derive
  user-facing artifacts from it — notably a payment beneficiary, and from that
  a per-user deposit address. A change to the input list, the join, the digest,
  the encoding or the `llmb_` prefix silently RE-KEYS every user's deposit
  address: money already sent to the old address lands on an identity nothing
  reads, and every existing credit balance is orphaned. There is no migration
  that recovers a deposit made against a derivation that no longer exists.

  Consequently:

    * it stays public and it stays this shape;
    * both sides pin the same golden vector, so a refactor fails loudly here
      and in the host's composition check rather than silently:

          budget_identity(%{workspace_key: "default", kind: "dm",
                            conversation_id: "tg:1:0"})
          #=> "llmb_xDByWmMCGVabJZ7C9tBC16tKsVUOYlcbah1O0Sz2aNI"

      (see `checks/llm_proxy_budget_identity_golden_test.exs` for the full
      vector set, including the omitted-workspace_key and atom-coercion
      equivalences and a second non-default triple);
    * changing it is a MAJOR, coordinated migration — never a refactor.
  """
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

  defp quota_status_for_conversation(%{"conversation_id" => cid} = msg, state)
       when is_binary(cid) and cid != "" do
    # Tolerate both host state shapes: everything under :quota (wingston lineage)
    # or store_mod/default_daily_limit at the top level with a *_usd global key
    # (mm lineage). The message may pin an explicit "day" (ISO) — mm's commands do.
    # (X5c) :store_mod specifically goes through resolve_store_mod/1 — the same
    # resolution credit_payment/2 now uses.
    quota =
      state
      |> Map.get(:quota, %{})
      |> Map.put(:store_mod, resolve_store_mod(state))
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

    # (X5b) credits_enabled gates the credit read here too, not just the plug's
    # block gate (credit_exhausted?/2): a feature-off install must show "0.00"
    # WITHOUT ever consulting the store — probe P5 showed a feature-off install
    # displaying a durable balance the block gate ignores entirely. credit_balance/3
    # (and therefore store_mod.llm_credit_balance/1) is only called when on.
    credit =
      if Map.get(state, :credits_enabled, false) do
        store_mod = Map.get(quota, :store_mod)

        case credit_balance_result(state_pid, store_mod, budget_identity) do
          {:ok, balance} ->
            %{balance_usd: money2(balance)}

          {:error, reason} ->
            Logger.error(
              "llm_proxy: quota_status credit balance store read failed: " <>
                "#{inspect(reason)} — reporting balance unavailable"
            )

            bump_store_metric(
              store_mod,
              "llm_credit_balance_read_failed",
              %{context: "quota_status", reason: "store_unavailable"},
              1
            )

            %{balance_usd: nil, unavailable: true}
        end
      else
        %{balance_usd: money2(Decimal.new("0"))}
      end

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
      credit: credit,
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
    |> maybe_add_payments_poll(state, budget_identity)
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

  defp quota_status(%{"conversation_id" => cid} = msg, state)
       when is_binary(cid) and cid != "" do
    quota_status_for_conversation(msg, state)
  end

  defp quota_status(msg, state) do
    %{
      action: "quota_status",
      ok: false,
      conversation_id: Map.get(msg, "conversation_id"),
      error: "missing_conversation_id",
      # No conversation_id means no budget_identity to look up a real balance
      # against — keep the field present (schema-stable for consumers) with
      # the safe default rather than omitting it.
      credit: %{balance_usd: money2(Decimal.new("0"))}
    }
    |> maybe_add_payments_poll(state, nil)
  end

  # The `payments_poll` operator block exists ONLY when polling is configured
  # (`settlements_fn`) — the prime invariant: an install with no payments
  # config gets a byte-identical reply. `held`/`held_count` are scoped to the
  # asked budget identity (that is why the entries carry no beneficiary): a
  # per-conversation reply must not enumerate other users' holds. A reply with
  # no conversation_id has no identity, so the list is empty.
  defp maybe_add_payments_poll(reply, state, budget_identity) do
    if is_nil(Map.get(state, :settlements_fn)) do
      reply
    else
      consumer = Map.get(state, :payments_consumer, "llm_proxy")

      case read_payments_cursor(state, consumer) do
        {:ok, cursor} ->
          state_pid = Map.get(state, :state_pid, @state_name)

          {poll_status, stuck_count} =
            Agent.get(state_pid, fn mirror ->
              {
                Map.get(mirror, :payments_poll, %{}),
                mirror |> Map.get(:stuck_payments, []) |> length()
              }
            end)

          held =
            if is_binary(budget_identity),
              do: held_for_identity(state_pid, resolve_store_mod(state), budget_identity),
              else: []

          Map.put(reply, :payments_poll, %{
            cursor: cursor,
            lag: Map.get(poll_status, :lag),
            stuck: stuck_count,
            held_count: length(held),
            # Most recent 10, newest first — a bounded operator/user surface,
            # not the queue itself.
            held: held |> Enum.reverse() |> Enum.take(10) |> Enum.map(&held_status_entry/1)
          })

        {:error, _reason} ->
          unavailable_payments_poll(reply)
      end
    end
  rescue
    _ ->
      unavailable_payments_poll(reply)
  catch
    _, _ ->
      unavailable_payments_poll(reply)
  end

  defp unavailable_payments_poll(reply) do
    Map.put(reply, :payments_poll, %{cursor: nil, unavailable: true})
  end

  defp held_status_entry(row) do
    %{
      ref: Map.get(row, :ref),
      amount_usd: money2(Map.get(row, :amount_usd, Decimal.new("0"))),
      reason: Map.get(row, :reason),
      at: held_at_iso(Map.get(row, :at))
    }
  end

  defp held_at_iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp held_at_iso(at) when is_binary(at), do: at
  defp held_at_iso(_), do: nil

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
          # Sidebar section (dashboard ≥ sidebar-groups): "LLM" is a builtin
          # section, so this page renders next to the host's Usage page.
          # This declaration WINS — host stamps are fill-nil-only, for
          # pages whose packages don't declare yet.
          "group" => "LLM",
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

  # ── Credit ledger primitives ──────────────────────────────────────────────
  #
  # A payment-agnostic prepaid credit balance per budget_identity, on top of the
  # existing daily-limit budget: the store (when it exports the two callbacks)
  # is durable and authoritative; the in-memory `credits` mirror is kept in sync
  # for callback-absent mode and local bookkeeping. A configured durable read
  # failure is NOT equivalent to an absent store: paid admission fails closed
  # until the authoritative balance is readable again.

  @doc """
  Prepaid credit balance for a budget identity. Durable read when the store
  exports the coherent credit callback pair; falls back to the in-memory mirror
  only when that pair is absent. Always returns a `Decimal` and never raises.
  A configured store read failure returns the conservative
  `Decimal.new("0")` and never overwrites the mirror; error-aware admission and
  status consumers use `credit_balance_result/3`.
  """
  def credit_balance(pid \\ @state_name, store_mod, budget_identity) do
    case credit_balance_result(pid, store_mod, budget_identity) do
      {:ok, %Decimal{} = bal} ->
        bal

      {:error, reason} ->
        Logger.error(
          "llm_proxy: credit balance store read failed: #{inspect(reason)} — returning conservative zero"
        )

        Decimal.new("0")
    end
  end

  # Durable credits are both-callbacks-or-neither: a store exporting only ONE
  # of llm_credit_balance/1 / record_llm_credit_entry/1 is treated as fully
  # absent for the credit path (README: "missing EITHER callback falls back
  # to the mirror for both"). Exporting only the read callback would
  # otherwise shadow a mirror top-up behind a durable-store read that never
  # actually recorded anything (paying user told ok, gate reads durable 0,
  # stays blocked); exporting only the write callback would silently accept
  # writes it can never read back durably. One resolution point for both call
  # sites below.
  @doc false
  def credit_store_ready?(store_mod) do
    is_atom(store_mod) and not is_nil(store_mod) and Code.ensure_loaded?(store_mod) and
      function_exported?(store_mod, :llm_credit_balance, 1) and
      function_exported?(store_mod, :record_llm_credit_entry, 1)
  end

  @doc false
  def credit_balance_result(pid \\ @state_name, store_mod, budget_identity) do
    case durable_credit_balance(store_mod, budget_identity) do
      {:ok, %Decimal{} = bal} -> {:ok, bal}
      :no_store -> {:ok, mirror_credit_balance(pid, budget_identity)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp durable_credit_balance(store_mod, budget_identity) do
    if credit_store_ready?(store_mod) do
      case store_mod.llm_credit_balance(budget_identity) do
        {:ok, %Decimal{} = bal} -> {:ok, bal}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:nonconforming_return, other}}
      end
    else
      :no_store
    end
  rescue
    e -> {:error, {:raised, e.__struct__, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp mirror_credit_balance(pid, budget_identity) do
    Agent.get(pid, fn state ->
      state
      |> Map.get(:credits, %{})
      |> Map.get(budget_identity, %{})
      |> Map.get(:balance, Decimal.new("0"))
    end)
  end

  @doc """
  Apply one signed credit-ledger entry (top-up or debit) with idempotency.
  Dedup is two-layer and race-safe: the mirror seen-check-and-mark is a
  SINGLE atomic `Agent.get_and_update` (not a separate read then write), so
  N concurrent callers with the same `idempotency_key` can never all observe
  "not seen" — exactly one wins the mark and proceeds to the durable write;
  every other racer (and every later replay) gets `:duplicate` without
  touching the balance. The store's own `{:error, :duplicate}` contract is
  the second layer, for the case where the mirror was reset (restart) but
  the durable ledger already has the key. Recorded durably when the store
  exports record_llm_credit_entry/1 and is healthy.

  (X4) Credit writes FAIL CLOSED per spec: when a durable store IS configured
  (`credit_store_ready?/1`) but `record_llm_credit_entry/1` errors/raises/
  exits, the mirror is NOT applied and the atomic seen-mark taken above is
  RELEASED before returning — the failed write must not permanently consume
  the idempotency key, so a later redelivery of the same key (once the store
  heals) is a genuine retry, not a swallowed duplicate. Releasing the mark
  only on the error path (never on success) keeps the concurrency property:
  concurrent same-key calls still credit at most once (every other racer
  during the write attempt sees the mark and gets `:duplicate`; only after an
  error is the key freed for a future attempt to retry). Mirror-only mode (no
  durable store at all — `:no_store`) is unchanged: fail-open, same as ever,
  since there is nothing durable to reconcile from.

  Returns `{:ok, new_mirror_balance}` | `:duplicate` | `{:error, :store_unavailable}`.
  """
  def apply_credit_entry(pid \\ @state_name, store_mod, %{idempotency_key: key, budget_identity: bi} = entry) do
    case mirror_mark_credit_seen(pid, bi, key) do
      :already_seen ->
        :duplicate

      :newly_marked ->
        case durable_record_credit_entry(store_mod, entry) do
          {:error, :duplicate} ->
            :duplicate

          :ok ->
            {:ok, mirror_apply_credit(pid, entry)}

          :no_store ->
            {:ok, mirror_apply_credit(pid, entry)}

          {:error, _reason} ->
            mirror_unmark_credit_seen(pid, bi, key)
            {:error, :store_unavailable}

          # (R3-I1) A NONCONFORMING return VALUE (the raise/exit cases are
          # already rescued in durable_record_credit_entry/2) — most likely a
          # host adapter forwarding Repo.insert/1's `{:ok, struct}` straight
          # through. Without this arm it raised CaseClauseError out of the
          # money path: the seen-mark leaked forever (redelivery acked
          # `duplicate:true` while the mirror balance was never applied — a
          # success-shaped lost payment) and the debit path 502'd an
          # already-billed call. Treat it exactly like a failed write: release
          # the mark, fail closed, let the hub redeliver. Self-converging even
          # when the nonconforming write actually LANDED: the store's own
          # uniqueness contract answers `{:error, :duplicate}` on the retry
          # and the entry settles exactly once.
          other ->
            Logger.warning(
              "llm_proxy: record_llm_credit_entry/1 returned nonconforming " <>
                inspect(other) <>
                " — treated as store failure (fails closed, retryable, key released)"
            )

            mirror_unmark_credit_seen(pid, bi, key)
            {:error, :store_unavailable}
        end
    end
  end

  defp durable_record_credit_entry(store_mod, entry) do
    if credit_store_ready?(store_mod) do
      store_mod.record_llm_credit_entry(entry)
    else
      :no_store
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # Atomic seen-check-and-mark: a single Agent message so the check and the
  # mark can never be split by a concurrent racer (the bug a nil-store /
  # store-round-trip race could otherwise hit — two callers both seeing
  # "not seen" and both crediting the mirror). Returns :already_seen (mirror
  # untouched) or :newly_marked (key now in the seen-set; caller owns this
  # entry and must apply the balance itself via mirror_apply_credit/2).
  defp mirror_mark_credit_seen(pid, budget_identity, key) do
    Agent.get_and_update(pid, fn state ->
      credits = Map.get(state, :credits, %{})
      row = Map.get(credits, budget_identity) || %{balance: Decimal.new("0"), seen: MapSet.new()}

      if MapSet.member?(row.seen, key) do
        {:already_seen, state}
      else
        row = %{row | seen: MapSet.put(row.seen, key)}
        {:newly_marked, Map.put(state, :credits, Map.put(credits, budget_identity, row))}
      end
    end)
  end

  # (X4) Release a seen-mark taken by mirror_mark_credit_seen/3 when the durable
  # write it was guarding subsequently FAILED — the mark is a lock, not a
  # ledger: it must not survive a write that never actually applied anywhere.
  # Only the error path in apply_credit_entry/3 calls this; a successful write
  # (durable :ok, :no_store, or a store-reported :duplicate) keeps its mark, so
  # a settled key still dedups a true replay. A missing row (already pruned or
  # never created) is a no-op.
  defp mirror_unmark_credit_seen(pid, budget_identity, key) do
    Agent.update(pid, fn state ->
      credits = Map.get(state, :credits, %{})

      case Map.get(credits, budget_identity) do
        nil ->
          state

        row ->
          row = %{row | seen: MapSet.delete(row.seen, key)}
          Map.put(state, :credits, Map.put(credits, budget_identity, row))
      end
    end)
  end

  # Balance-only mirror apply. The seen-set mark already happened atomically
  # in mirror_mark_credit_seen/3 before the durable write was attempted, so
  # this only ever runs for the single caller that won that mark.
  defp mirror_apply_credit(pid, %{budget_identity: bi, amount_usd: amt}) do
    Agent.get_and_update(pid, fn state ->
      credits = Map.get(state, :credits, %{})
      row = Map.get(credits, bi) || %{balance: Decimal.new("0"), seen: MapSet.new()}
      row = %{row | balance: Decimal.add(row.balance, amt)}
      {row.balance, Map.put(state, :credits, Map.put(credits, bi, row))}
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
      block_reason = request_block_reason(opts, session, request_ctx, budget)

      cond do
        block_reason == :global ->
          # Operator-wide daily ceiling reached — block EVERY conversation (cost-DoS backstop),
          # before the per-conversation check. Same delivery/SSE shape as a per-conv block.
          global_exhausted_response(
            conn,
            session,
            request_ctx,
            opts,
            streaming?(body) and Map.get(opts, :allow_streaming, false)
          )

        block_reason == :request_quota ->
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

        block_reason in [:budget_exhausted, :store_unavailable] ->
          # Only render an SSE budget body when streaming was REQUESTED *and* the gate is
          # on; otherwise the buffered JSON body (byte-identical to before).
          budget_exhausted_response(
            conn,
            session,
            request_ctx,
            budget,
            opts,
            streaming?(body) and Map.get(opts, :allow_streaming, false),
            block_reason
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
            # (X2) Thread the full budget map (not just spent_usd) through the fold
            # so every discarded-attempt debit uses the SAME limit_usd the gate saw.
            budget =
              record_discarded_attempts(
                opts,
                session,
                request_ctx,
                conn.body_params,
                Map.put(budget, :spent_usd, budget.spent_usd || Decimal.new("0")),
                discarded_attempts
              )

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
      block_reason = request_block_reason(opts, session, request_ctx, budget)

      cond do
        block_reason == :global ->
          bump_metric(opts, "llm_proxy_compact_block")

          json(conn, 429, %{
            error: %{
              message: "operator daily budget exhausted",
              type: "budget",
              code: "global_budget_exhausted"
            }
          })

        block_reason == :request_quota ->
          bump_metric(opts, "llm_proxy_compact_block")

          json(conn, 429, %{
            error: %{
              message: "daily request limit reached",
              type: "budget",
              code: "request_quota_exhausted"
            }
          })

        block_reason in [:budget_exhausted, :store_unavailable] ->
          bump_metric(opts, "llm_proxy_compact_block")

          if block_reason == :store_unavailable do
            bump_quota_metric(opts, session, "store_unavailable")
          end

          {message, code} =
            if block_reason == :store_unavailable do
              {"prepaid credit balance temporarily unavailable", "credit_store_unavailable"}
            else
              {"daily budget exhausted", "budget_exhausted"}
            end

          json(conn, 429, %{
            error: %{
              message: message,
              type: "budget",
              code: code
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
          # (X2) Pass the full `budget` map (not just spent_usd) so the debit
          # chokepoint sees the SAME limit_usd this cond's exhausted?/1 gate did.
          record_budget_call(
            opts,
            session,
            request_ctx,
            compact_record(status, resp, budget, opts),
            budget
          )

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
      # put_new (not Map.get default at the call site) so an EXPLICIT nil/0 keeps
      # meaning legacy once-per-day while an absent key gets the 4h default.
      |> Map.put_new(:notice_repeat_ms, Proxy.default_notice_repeat_ms())
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
  # (X2) `budget` is the full map (spent_usd + limit_usd), threaded through so
  # every discarded-attempt debit sees the same limit_usd the gate saw.
  defp record_discarded_attempts(_opts, _session, _request_ctx, _request, budget, []), do: budget

  defp record_discarded_attempts(opts, session, request_ctx, request, budget, discarded),
    do: record_nonempty_discarded_attempts(opts, session, request_ctx, request, budget, discarded)

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

  defp record_nonempty_discarded_attempts(opts, session, request_ctx, request, budget, discarded) do
    Enum.reduce(discarded, budget, fn %{body: body}, budget_acc ->
      usage = normalize_usage_counts(Map.get(body, "usage") || %{})
      upstream_router = upstream_router(Map.get(body, "x_router"))
      model = served_model(upstream_router, body, request)
      {cost, _invalid?} = executed_cost_usd(usage, opts, upstream_router, budget_acc.spent_usd)
      {cached_tokens, non_cached_tokens} = Proxy.cache_split(usage, upstream_router)

      record_budget_call(
        opts,
        session,
        request_ctx,
        %{
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
        },
        budget_acc
      )

      Map.put(budget_acc, :spent_usd, Decimal.add(budget_acc.spent_usd, cost))
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

  # Credits only matter once the free daily budget is spent. Reading the balance
  # only on the already-exhausted path keeps the hot path store-call-free and
  # makes the no-credits configuration byte-identical to 0.2.19.
  #
  # (B2) Feature-gated on `credits_enabled` (derived from `payments_source`
  # config being present, see init/1): when off, this returns true WITHOUT
  # reading any balance — zero credit consults, byte-identical 0.2.19
  # blocking. A feature-off install must never be unblocked by a stray/
  # hand-credited mirror balance, and enabling payments later must never
  # retro-charge overage accrued while the feature was off.
  @doc false
  # Public compatibility predicate for the credit-spend checks. Configured
  # durable read failures count as exhausted (fail closed).
  def credit_exhausted?(opts, session) do
    credit_block_reason(opts, session) != nil
  end

  defp request_block_reason(opts, session, request_ctx, budget) do
    cond do
      global_exhausted?(opts, request_ctx) ->
        :global

      request_quota_exhausted?(opts, budget) ->
        :request_quota

      exhausted?(budget) ->
        credit_block_reason(opts, session)

      true ->
        nil
    end
  end

  defp credit_block_reason(opts, session) do
    if Map.get(opts, :credits_enabled, false) do
      case Proxy.credit_balance_result(
             opts.state_pid,
             opts.store_mod,
             session.budget_identity
           ) do
        {:ok, balance} ->
          if Decimal.compare(balance, Decimal.new("0")) == :gt,
            do: nil,
            else: :budget_exhausted

        {:error, reason} ->
          Logger.error(
            "llm_proxy: credit balance store read FAILED: #{inspect(reason)} — " <>
              "blocking paid request (fails closed)"
          )

          bump_metric(opts, "llm_proxy_budget_degraded")
          :store_unavailable
      end
    else
      :budget_exhausted
    end
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

  # Deliver the Telegram block notice for THIS blocked request — or not. Returns
  # what actually happened so the synthetic completion content can tell the truth:
  #
  #   :sent       — a notice went out on this request
  #   :suppressed — rate-limited: this identity was already notified for this cap
  #                 type earlier today (within notice_repeat_ms)
  #   :skipped    — the session was registered with notify: false (background
  #                 work); it neither delivers nor consumes/advances the notice
  #                 timestamp, so it can't starve the user-facing session's notice
  defp block_notice_delivery(opts, session, request_ctx, reason, notice) do
    cond do
      not session_notify?(session) ->
        :skipped

      Proxy.notice_due?(opts.state_pid, session.budget_identity, reason, request_ctx.day,
        now: Map.get(opts, :clock, &DateTime.utc_now/0).(),
        repeat_ms: Map.get(opts, :notice_repeat_ms, Proxy.default_notice_repeat_ms()),
        variant: notice_variant(opts, session, reason)
      ) ->
        msg = Jason.encode!(%{action: "slot_reply", slot: session.slot, content: notice})
        opts.deliver_fn.(opts.swarm_name, opts.sender, :llm_proxy, msg)
        :sent

      true ->
        :suppressed
    end
  end

  # (R4-M2) A newly-appeared hold changes the dedup key, so the FIRST notice
  # after a quarantine is always due.
  #
  # Without it: the user is blocked at 09:00 (notice sent, no hold yet), the hub
  # quarantines at 09:30, and every block until 13:00 returns :suppressed — the
  # user is never told about the hold, while synthetic_block_content/2 tells the
  # agent "the user was already notified earlier today; do not send a separate
  # user reply". That statement is true of the OLD text and false of the new.
  #
  # The variant is a FLAG, never the hold count. Folding the count in mints a
  # fresh dedup key per hold, which turns notice_repeat_ms into one notice per
  # settlement — and deposit addresses are permissionless, so a saturated C1
  # window (which quarantines everything) lets a third party drive that. The
  # flag keeps what it was added for: the no-hold -> held transition changes the
  # key once, so the first hold re-notifies instead of being swallowed. A later
  # hold's larger sum rides the next due notice.
  #
  # PRIME INVARIANT: credits off (or a non-:budget cap) -> nil -> the dedup key
  # is the plain 3-tuple, byte-identical to 0.3.0.
  # (R4-P4-I2) DURABLE-FIRST, exactly like the sentence itself. Reading the
  # mirror here while `held_notice_line/2` reads durable is the C1 fix applied
  # to the notice's CONTENT but not to its DUE decision, and the two then
  # disagree across instances: the instance serving the blocked user builds the
  # hold sentence from the durable row (correct) but computes the plain dedup
  # key from its own empty mirror, so if that identity was already notified
  # today with the plain text the notice is SUPPRESSED — and
  # `synthetic_block_content/2` then tells the agent the user was already
  # notified. The user is blocked, has already paid, and is told nothing for a
  # whole notice_repeat_ms window. Same read, same authority, one argument.
  defp notice_variant(opts, session, :budget) do
    if Map.get(opts, :credits_enabled, false) do
      case Proxy.held_payments(
             Map.get(opts, :state_pid),
             Map.get(opts, :store_mod),
             session.budget_identity
           ) do
        [] -> nil
        _held -> :held
      end
    end
  end

  defp notice_variant(_opts, _session, _reason), do: nil

  # Sessions registered with notify: false (background work, e.g. summarizers)
  # must never target the user with a block notice. Map.get: sessions registered
  # by an older proxy build carry no :notify key — default true.
  defp session_notify?(session), do: Map.get(session, :notify, true) != false

  # The agent-facing synthetic completion must describe what THIS request did —
  # claiming "a notice was sent" when dedup suppressed it makes the agent stay
  # silent while the user was never told anything on this request.
  defp synthetic_block_content(reason, delivery) do
    lead =
      case reason do
        :budget ->
          "The daily LLM limit for this conversation was reached."

        :credit_store_unavailable ->
          "The daily LLM limit was reached, and the prepaid balance is temporarily unavailable; no paid request was sent."

        :request_quota ->
          "This chat reached today's AI usage limit."

        :global ->
          "The service-wide daily LLM budget was reached."
      end

    tail =
      case delivery do
        :sent -> "A deterministic Telegram notice was sent; do not send a separate user reply."
        :suppressed -> "The user was already notified earlier today; do not send a separate user reply."
        :skipped -> "No user notice was sent by this path."
      end

    lead <> " " <> tail
  end

  defp budget_exhausted_response(
         conn,
         session,
         request_ctx,
         budget,
         opts,
         streaming?,
         block_reason
       ) do
    metric_reason = Atom.to_string(block_reason)

    notice_reason =
      if block_reason == :store_unavailable, do: :credit_store_unavailable, else: :budget

    bump_quota_metric(opts, session, metric_reason)
    notice = budget_block_notice(request_ctx, budget, opts, session, block_reason)

    # Deterministic Telegram delivery + block metrics are mode-independent; only the
    # HTTP response body differs (SSE chunk vs buffered JSON).
    delivery = block_notice_delivery(opts, session, request_ctx, notice_reason, notice)
    if delivery == :sent, do: bump_metric(opts, "llm_proxy_budget_block_notified")

    bump_metric(opts, "llm_proxy_budget_block")
    emit_display(%{kind: :llm_proxy_block, cid: session.conversation_id, reason: "budget"})
    content = synthetic_block_content(notice_reason, delivery)

    if streaming? do
      budget_exhausted_sse(conn, request_ctx, content)
    else
      budget_exhausted_json(conn, request_ctx, budget, opts, content)
    end
  end

  defp request_quota_exhausted_response(conn, session, request_ctx, budget, opts, streaming?) do
    bump_quota_metric(opts, session, "request_quota_exhausted")
    limit = request_quota_limit(opts)
    notice = request_quota_notice(request_ctx, limit)
    delivery = block_notice_delivery(opts, session, request_ctx, :request_quota, notice)

    bump_metric(opts, "llm_proxy_request_quota_block")
    emit_display(%{kind: :llm_proxy_block, cid: session.conversation_id, reason: "request_quota"})
    content = synthetic_block_content(:request_quota, delivery)

    if streaming? do
      request_quota_exhausted_sse(conn, request_ctx, limit, content)
    else
      request_quota_exhausted_json(conn, request_ctx, budget, opts, limit, content)
    end
  end

  @global_notice "⏳ The service daily LLM budget is exhausted. Please try again tomorrow at 00:00 UTC. 🪶"

  # Operator-wide ceiling block. Mirrors budget_exhausted_response: deterministic Telegram
  # notice (rate-limited per conversation per cap type per UTC day), a durable block metric
  # the operator can ALERT on, an error log, and the synthetic SSE/JSON body — but framed
  # as a service-wide cap.
  defp global_exhausted_response(conn, session, request_ctx, opts, streaming?) do
    delivery = block_notice_delivery(opts, session, request_ctx, :global, @global_notice)

    bump_metric(opts, "llm_proxy_global_block")
    emit_display(%{kind: :llm_proxy_block, cid: session.conversation_id, reason: "global"})
    bump_quota_metric(opts, session, "global_budget_exhausted")

    Logger.error(
      "llm_proxy: GLOBAL daily budget ceiling reached — blocking all conversations until 00:00 UTC"
    )

    content = synthetic_block_content(:global, delivery)

    if streaming? do
      budget_exhausted_sse(conn, request_ctx, content)
    else
      global_exhausted_json(conn, request_ctx, opts, global_status(opts, request_ctx), content)
    end
  end

  defp global_exhausted_json(conn, request_ctx, opts, global, content) do
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
            "content" => content
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
  defp budget_exhausted_sse(conn, request_ctx, content) do
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
                "content" => content
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

  defp request_quota_exhausted_sse(conn, request_ctx, limit, content) do
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
                "content" => content
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

  defp budget_exhausted_json(conn, request_ctx, budget, opts, content) do
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
            "content" => content
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

  defp request_quota_exhausted_json(conn, request_ctx, budget, opts, limit, content) do
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
            "content" => content
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

  # Exposed @doc false so the credit-surfaces check can drive the hint-append
  # logic directly (like bump_metric). Base text is byte-identical to 0.2.19;
  # the hint (from opts.topup_hint_fun, see init/1) is appended on its own
  # line only when credits_enabled is true (R3-M2), the fun is present, its
  # result non-empty, and the fun doesn't raise.
  #
  # (C1) The HELD line replaces the hint: a user whose money demonstrably left
  # their wallet, and who is now looking at a "you are blocked" message, must
  # be told that the payment arrived and is NOT credited yet. It rides the
  # EXISTING notice — same delivery, same {identity, cap, day} dedup and
  # notice_repeat_ms rate limit (see block_notice_delivery/5) — deliberately:
  # a second notification channel for held money is how users get spammed or,
  # worse, get a hold notice with no context about why they are blocked.
  #
  # (R4-I4) While a hold is unresolved the top-up hint is SUPPRESSED. It is not
  # "still the right action for a NEW payment": the mechanism that produced the
  # hold is an aggregate issuance cap over a window, or a per-settlement
  # max_payment_usd. Under the aggregate cap the window is still saturated, so
  # a second deposit made on the strength of the hint is likely quarantined
  # too; and the per-beneficiary small-top-up carve-out cannot rescue it,
  # because this beneficiary has by definition already consumed theirs.
  # "Your $5 is held pending an operator" followed immediately by "send USDC to
  # 0xABC" tells the user to send good money after bad — $15 frozen instead of
  # $5, still blocked, the same instruction twice. That is a worse support
  # incident than the silence C1 was written to prevent. Once the hold clears,
  # the hint returns unchanged.
  @doc false
  def budget_notice(request_ctx, _budget, opts, session) do
    reset_date = request_ctx.day |> Date.add(1) |> Date.to_iso8601()
    base = "⏳ This chat reached its daily LLM limit. Try again tomorrow at 00:00 UTC (#{reset_date})."
    held = held_notice_line(opts, session)

    [base, held, if(is_nil(held), do: topup_hint(opts, session))]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp budget_block_notice(_request_ctx, _budget, _opts, _session, :store_unavailable) do
    "⏳ This chat reached its daily LLM limit. The prepaid balance is temporarily " <>
      "unavailable, so no paid request was sent. Please try again later."
  end

  defp budget_block_notice(request_ctx, budget, opts, session, :budget_exhausted) do
    budget_notice(request_ctx, budget, opts, session)
  end

  # One sentence, appended at most once no matter how many holds the identity
  # has (they are summed). Gated on the same strict credits_enabled derivation
  # as every other credit surface: with credits off the handler refuses every
  # payment_held, so the mirror is empty by construction — the gate keeps the
  # feature-off path from even reading the Agent, byte-identical to 0.3.0.
  defp held_notice_line(opts, session) do
    if Map.get(opts, :credits_enabled, false) do
      # Durable-first: this line is the user's ONLY signal that money they sent
      # is held, and the in-memory mirror behind it does not survive a deploy.
      Proxy.held_notice_line(
        Map.get(opts, :state_pid),
        Map.get(opts, :store_mod),
        session.budget_identity
      )
    end
  end

  # (R3-M2) Gated on the SAME strict credits_enabled derivation as every
  # other credit surface (block gate, debit chokepoint, handler,
  # quota_status): with credits off, this object silently drops every
  # payment_confirmed, so rendering the hint would point a blocked user at a
  # payment path that cannot credit them. Off (or key absent) -> no hint,
  # byte-identical to 0.2.19 regardless of a configured fun.
  defp topup_hint(opts, session) do
    if Map.get(opts, :credits_enabled, false) do
      do_topup_hint(opts, session)
    end
  end

  defp do_topup_hint(opts, session) do
    case Map.get(opts, :topup_hint_fun) do
      fun when is_function(fun, 1) ->
        try do
          case fun.(session.budget_identity) do
            hint when is_binary(hint) and hint != "" -> hint
            _ -> nil
          end
        rescue
          _ -> nil
        catch
          _, _ -> nil
        end

      _ ->
        nil
    end
  end

  defp request_quota_notice(request_ctx, _limit) do
    reset_date = request_ctx.day |> Date.add(1) |> Date.to_iso8601()

    "⏳ This chat reached today's daily LLM request limit. Try again tomorrow at 00:00 UTC (#{reset_date})."
  end

  @doc false
  # Public for the credit-spend check: the straddle-debit chokepoint every
  # spend-recording call site funnels through.
  def record_budget_call(opts, session, request_ctx, record, spent_before \\ nil) do
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
    maybe_debit_credit(opts, session, record, spent_before)
    store_row
  end

  # Straddle math: only the portion of this call's cost ABOVE the daily limit is
  # credit-funded. overflow(spent) = max(0, spent - limit);
  # debit = overflow(spent_before + cost) - overflow(spent_before).
  #
  # (B2) Feature-gated on `credits_enabled`: a feature-off install must never
  # accrue a negative mirror balance (which would retro-charge pre-feature
  # overage the moment payments are enabled later) — no-op entirely when off,
  # before touching the credit store at all.
  #
  # (X2) The 5th arg (formerly a bare `spent_before` Decimal) is now whatever the
  # call site has: nil (no debit), the legacy bare spent_before (a Decimal or —
  # X3 — an integer, for direct/legacy callers that never carried a limit
  # alongside it), or the full `budget` map the exhausted?/1 gate itself
  # consulted (%{spent_usd:, limit_usd:}). normalize_debit_budget/1 collapses
  # all three into one shape so do_maybe_debit_credit/4 always has a
  # `limit_usd` to prefer — the gate and the debit MUST agree on the same
  # limit (a store-row-pinned budget.limit_usd that differs from
  # session.daily_limit_usd otherwise double- or under-charges the straddle
  # band the gate actually used).
  defp maybe_debit_credit(_opts, _session, _record, nil), do: :ok

  defp maybe_debit_credit(opts, session, record, budget) do
    if Map.get(opts, :credits_enabled, false) do
      do_maybe_debit_credit(opts, session, record, normalize_debit_budget(budget))
    else
      :ok
    end
  end

  # Legacy bare spent_before (Decimal or — X3 — integer): no limit info travels
  # with it, so do_maybe_debit_credit/4 falls back to session/opts exactly as
  # before. Proxy.decimal/1 coerces the integer case (a store returning an
  # integer spent_usd is legal per 0.2.19 and must not crash here).
  defp normalize_debit_budget(%Decimal{} = spent_before),
    do: %{spent_usd: spent_before, limit_usd: nil}

  defp normalize_debit_budget(spent_before) when is_integer(spent_before),
    do: %{spent_usd: Proxy.decimal(spent_before), limit_usd: nil}

  # The real budget map (from budget_status/fallback_budget_status): carry its
  # limit_usd through so the debit uses the SAME limit the gate saw. spent_usd
  # is still coerced (X3) in case a legacy store's budget row carries an
  # integer there too.
  defp normalize_debit_budget(%{} = budget) do
    %{
      spent_usd: Proxy.decimal(Map.get(budget, :spent_usd)),
      # (I2) A nonconforming store row can carry limit_usd: nil. The gate
      # (exhausted?/1) falls back `limit || Proxy.default_daily_limit()` — the
      # debit must use the EXACT same fallback, not the session/opts chain, or
      # a nil-limit row makes gate and debit disagree on where the free band
      # ends (under- or double-charging the straddle). The session/opts chain
      # remains only for the legacy bare-Decimal/integer arms above, which
      # never saw a budget map at all.
      limit_usd: Map.get(budget, :limit_usd) || Proxy.default_daily_limit()
    }
  end

  defp do_maybe_debit_credit(opts, session, record, %{spent_usd: spent_before, limit_usd: gate_limit}) do
    with %Decimal{} = cost <- Map.get(record, :cost_usd),
         request_id when is_binary(request_id) <- Map.get(record, :request_id) do
      limit = gate_limit || session.daily_limit_usd || opts.default_daily_limit
      zero = Decimal.new("0")
      overflow = fn spent -> Decimal.max(zero, Decimal.sub(spent, limit)) end
      debit = Decimal.sub(overflow.(Decimal.add(spent_before, cost)), overflow.(spent_before))

      if Decimal.compare(debit, zero) == :gt do
        entry = %{
          idempotency_key: "debit:" <> request_id,
          budget_identity: session.budget_identity,
          amount_usd: Decimal.negate(debit),
          kind: "debit",
          at: DateTime.utc_now(),
          meta: %{"request_id" => request_id}
        }

        case Proxy.apply_credit_entry(opts.state_pid, opts.store_mod, entry) do
          {:error, :store_unavailable} ->
            # (I1) The request was ALREADY served — budget-side accounting fails
            # OPEN, per the spec's failure asymmetry — and unlike the top-up path
            # (credit_payment/2, whose retryable NACK makes the hub redeliver),
            # a debit has no redelivery vehicle: a durable-write failure here
            # would otherwise lose the debit silently and forever. Make the loss
            # visible (same degraded log+metric pattern as record_budget_call/5's
            # store-down branch), then re-apply the entry MIRROR-ONLY (store_mod
            # nil -> apply_credit_entry's :no_store arm) so the fail-open mirror
            # balance stays the conservative, lower figure while the store is
            # down. Safe on both sides of recovery: balance reads are
            # durable-first (credit_balance/3), so a healed store's un-debited
            # balance simply shadows the mirror — nothing re-syncs the mirror
            # from durable, and the mirror-only re-apply re-takes the
            # idempotency seen-mark, so the same request_id can never be
            # double-applied by any later replay. The durable ledger's missing
            # debit (an outage-window under-charge) is the documented rider.
            Logger.warning(
              "llm_proxy: credit DEBIT store write FAILED — debit applied to in-memory " <>
                "mirror only; durable ledger under-charges this call (no retry vehicle); " <>
                "request_id=#{request_id} debit_usd=#{Decimal.to_string(debit)}"
            )

            bump_metric(opts, "llm_proxy_budget_degraded")
            Proxy.apply_credit_entry(opts.state_pid, nil, entry)

          _ ->
            :ok
        end
      end

      :ok
    else
      _ -> :ok
    end
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

    # (X2) Pass the full `budget` map so the debit sees the same limit_usd the
    # cond's exhausted?/1 gate did (not a re-derived session/opts limit).
    record_budget_call(opts, session, request_ctx, record, budget)

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

    # (X2) Same limit_usd the gate saw, not a re-derived session/opts one.
    record_budget_call(opts, session, request_ctx, record, budget)

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

        # (X2) Consistent with every other call site: pass the full budget map
        # (this record carries no cost_usd, so maybe_debit_credit no-ops anyway).
        record_budget_call(
          s.opts,
          s.session,
          s.request_ctx,
          %{
            request_id: request_id(),
            model: model,
            status: "upstream_#{status}",
            provider: Map.get(router, "provider")
          },
          s.budget
        )

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

    record_budget_call(
      s.opts,
      s.session,
      s.request_ctx,
      %{
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
      },
      s.budget
    )
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
