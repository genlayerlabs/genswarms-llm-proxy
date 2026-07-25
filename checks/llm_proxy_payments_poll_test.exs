# Outbox consumer: explicit gates, per-row disposition, cursor semantics,
# trailing-window idempotency, anomalies, lag metrics, and entry provenance.
# Standalone — no Postgres, no network.
alias Genswarms.LlmProxy, as: Proxy

ExUnit.start(autorun: false)

{:ok, failures} = Agent.start_link(fn -> [] end)

check = fn label, ok ->
  if ok do
    IO.puts("  ok   #{label}")
  else
    IO.puts("  FAIL #{label}")
    Agent.update(failures, &[label | &1])
  end
end

defmodule PaymentsPollStore do
  def reset(opts \\ []) do
    :persistent_term.put(
      {__MODULE__, :state},
      %{
        cursor: Keyword.get(opts, :cursor),
        cursor_writes: [],
        entries: [],
        keys: MapSet.new(Keyword.get(opts, :keys, [])),
        transient_keys: MapSet.new(Keyword.get(opts, :transient_keys, [])),
        stuck: [],
        metrics: [],
        cursor_read_error: Keyword.get(opts, :cursor_read_error),
        cursor_write_error: Keyword.get(opts, :cursor_write_error)
      }
    )
  end

  def state, do: :persistent_term.get({__MODULE__, :state})
  defp update(fun), do: :persistent_term.put({__MODULE__, :state}, fun.(state()))

  def heal(key) do
    update(fn state ->
      %{state | transient_keys: MapSet.delete(state.transient_keys, key)}
    end)
  end

  def heal_cursor do
    update(&%{&1 | cursor_write_error: nil})
  end

  def llm_credit_balance(budget_identity) do
    balance =
      state().entries
      |> Enum.filter(&(&1.budget_identity == budget_identity))
      |> Enum.reduce(Decimal.new("0"), &Decimal.add(&1.amount_usd, &2))

    {:ok, balance}
  end

  def record_llm_credit_entry(%{idempotency_key: key} = entry) do
    state = state()

    cond do
      MapSet.member?(state.transient_keys, key) ->
        {:error, :db_down}

      MapSet.member?(state.keys, key) ->
        {:error, :duplicate}

      true ->
        update(fn current ->
          %{
            current
            | keys: MapSet.put(current.keys, key),
              entries: current.entries ++ [entry]
          }
        end)

        :ok
    end
  end

  def llm_payments_cursor(_consumer) do
    case state().cursor_read_error do
      nil -> {:ok, state().cursor}
      reason -> {:error, reason}
    end
  end

  def put_llm_payments_cursor(_consumer, cursor) do
    case state().cursor_write_error do
      nil ->
        update(fn state ->
          %{state | cursor: cursor, cursor_writes: state.cursor_writes ++ [cursor]}
        end)

        :ok

      reason ->
        {:error, reason}
    end
  end

  def record_llm_stuck_payment(row) do
    update(fn state -> %{state | stuck: state.stuck ++ [row]} end)
    :ok
  end

  def bump_metric(event, meta, value) do
    update(fn state -> %{state | metrics: state.metrics ++ [{event, meta, value}]} end)
    :ok
  end
end

row = fn seq, ref, over ->
  Map.merge(
    %{
      beneficiary: "w:default|k:dm|c:tg:9:0",
      amount_usd: Decimal.new("2.50"),
      method: "usdc_base",
      ref: ref,
      idempotency_key: "8453:#{ref}",
      namespace: "llm_quota",
      at: ~U[2026-07-25 10:00:00Z],
      outbox_seq: seq,
      meta: %{"hub_fact" => "kept"}
    },
    over
  )
end

{:ok, pid} = Proxy.start_state_link()

base_state = %{
  state_pid: pid,
  endpoint: "http://127.0.0.1:4318/v1/chat/completions",
  provider: "openai-compatible",
  quota: %{store_mod: PaymentsPollStore},
  store_mod: PaymentsPollStore,
  payments_source: "payments",
  credit_namespace: "llm_quota",
  credit_per_usd: Decimal.new("2.0"),
  credits_enabled: true,
  settlements_fn: nil,
  payments_consumer: "llm_proxy",
  poll_lag: 100,
  poll_limit: 100,
  poll_sources: ["cron"]
}

decode_poll = fn from, state ->
  {:reply, json, ^state} =
    Proxy.handle_message(from, Jason.encode!(%{action: "poll_payments"}), state)

  Jason.decode!(json)
end

# Gates are explicit and distinct.
PaymentsPollStore.reset()

unknown_sender = decode_poll.(%{"not" => "scalar"}, base_state)

check.(
  "unknown/non-scalar sender is explicitly refused",
  unknown_sender["error"] == "untrusted_poll_source"
)

wrong_sender = decode_poll.("other", base_state)

check.(
  "sender outside poll_sources is explicitly refused",
  wrong_sender["error"] == "untrusted_poll_source"
)

no_fn = decode_poll.("cron", base_state)

check.(
  "missing settlements_fn is explicitly refused",
  no_fn["error"] == "settlements_fn_not_configured"
)

credits_off =
  decode_poll.(
    "cron",
    %{
      base_state
      | settlements_fn: fn _, _ ->
          {:ok, %{settlements: [], max_seq: 0, next_seq: 0, complete: true}}
        end,
        credits_enabled: false
    }
  )

check.("credits-off polling is explicitly refused", credits_off["error"] == "credits_disabled")

atom_source_state = %{
  base_state
  | settlements_fn: fn _, _ ->
      {:ok, %{settlements: [], max_seq: 0, next_seq: 0, complete: true}}
    end,
    poll_sources: [:cron]
}

check.(
  "poll source comparison normalizes configured atom and stamped string",
  decode_poll.("cron", atom_source_state)["ok"] == true
)

# Prime invariant: explicit defaults produce byte-identical quota_status output
# to a state with no poll keys, and the additive block is absent.
quota_msg =
  Jason.encode!(%{
    action: "quota_status",
    conversation_id: "tg:9:0",
    kind: "dm",
    workspace_key: "default",
    day: "2026-07-25"
  })

legacy_state =
  base_state
  |> Map.drop([:settlements_fn, :payments_consumer, :poll_lag, :poll_limit, :poll_sources])

{:reply, legacy_quota_json, _} = Proxy.handle_message("operator", quota_msg, legacy_state)
{:reply, default_quota_json, _} = Proxy.handle_message("operator", quota_msg, base_state)

check.(
  "no poll config keeps quota_status byte-identical and omits payments_poll",
  legacy_quota_json == default_quota_json and
    not Map.has_key?(Jason.decode!(default_quota_json), "payments_poll")
)

{:reply, configured_quota_json, _} =
  Proxy.handle_message("operator", quota_msg, atom_source_state)

check.(
  "configured polling adds cursor, lag, and stuck quota status",
  Jason.decode!(configured_quota_json)["payments_poll"] == %{
    "cursor" => 0,
    "lag" => 0,
    "stuck" => 0
  }
)

{:ok, fresh_quota_pid} = Proxy.start_state_link()
fresh_poll_state = %{atom_source_state | state_pid: fresh_quota_pid}
{:reply, pre_poll_quota_json, _} = Proxy.handle_message("operator", quota_msg, fresh_poll_state)

check.(
  "configured polling reports null lag before any successful poll",
  Jason.decode!(pre_poll_quota_json)["payments_poll"]["lag"] == nil
)

PaymentsPollStore.reset(cursor_read_error: :db_down)

{:reply, unavailable_quota_json, _} =
  Proxy.handle_message("operator", quota_msg, atom_source_state)

check.(
  "cursor-store failure is distinct and never fabricates a healthy zero",
  Jason.decode!(unavailable_quota_json)["payments_poll"] == %{
    "cursor" => nil,
    "unavailable" => true
  }
)

# One page exercises every disposition. Cursor begins at 100: seq 101 applies,
# 102 is already durable, 103 is permanently malformed, 104 is transient, and
# 105 is deferred without being touched.
rows = [
  row.(101, "0xA:0", %{}),
  row.(102, "0xDUP:0", %{}),
  row.(103, "0xBAD:0", %{method: "debit"}),
  row.(104, "0xDOWN:0", %{}),
  row.(105, "0xLATER:0", %{})
]

PaymentsPollStore.reset(
  cursor: 100,
  keys: ["usdc_base:0xDUP:0"],
  transient_keys: ["usdc_base:0xDOWN:0"]
)

{:ok, reads} = Agent.start_link(fn -> [] end)

scripted = fn after_seq, limit ->
  Agent.update(reads, &(&1 ++ [{after_seq, limit}]))
  {:ok, %{settlements: rows, max_seq: 105, next_seq: 105, complete: true}}
end

state = %{base_state | settlements_fn: scripted}
first = decode_poll.("cron", state)
store_after_first = PaymentsPollStore.state()

check.(
  "poll reads from cursor-lag with lag plus progress capacity",
  Agent.get(reads, & &1) == [{0, 200}]
)

check.(
  "per-row disposition applies, dedups, sticks, stops transiently, and defers the tail",
  Map.take(first, ["action", "ok", "applied", "duplicates", "stuck", "deferred"]) == %{
    "action" => "poll_payments",
    "ok" => true,
    "applied" => 1,
    "duplicates" => 1,
    "stuck" => 1,
    "deferred" => 2
  }
)

check.(
  "transient stop advances only through the last resolved row",
  first["cursor"] == 103 and first["max_seq"] == 105 and first["lag"] == 2 and
    store_after_first.cursor == 103 and store_after_first.cursor_writes == [103]
)

check.(
  "permanent rejection is durable, retains the full row, and is alarmed by idempotency key",
  length(store_after_first.stuck) == 1 and
    hd(store_after_first.stuck).outbox_seq == 103 and
    hd(store_after_first.stuck).reason == "reserved_method" and
    Enum.any?(store_after_first.metrics, fn
      {"llm_payments_stuck", %{idempotency_key: "8453:0xBAD:0"}, 1} -> true
      _ -> false
    end)
)

check.(
  "D0 lag gauge is emitted with max_seq-new_cursor",
  Enum.any?(store_after_first.metrics, fn
    {"llm_payments_lag", %{consumer: "llm_proxy"}, 2} -> true
    _ -> false
  end)
)

check.(
  "hub-native Decimal amount is normalized into the strings-only validating path",
  length(store_after_first.entries) == 1 and
    hd(store_after_first.entries).idempotency_key == "usdc_base:0xA:0"
)

# Heal and replay the overlapping page. Prior applied rows resolve as
# duplicates, the poison row remains stuck rather than freezing the page, and
# the deferred rows now apply before the cursor uses page.next_seq.
PaymentsPollStore.heal("usdc_base:0xDOWN:0")
second = decode_poll.("cron", state)
balance_after_second = PaymentsPollStore.llm_credit_balance("w:default|k:dm|c:tg:9:0")

check.(
  "healed replay resolves the whole page and advances by hub next_seq",
  second["applied"] == 2 and second["duplicates"] == 2 and second["stuck"] == 1 and
    second["deferred"] == 0 and second["cursor"] == 105 and second["lag"] == 0
)

store_after_second = PaymentsPollStore.state()

check.(
  "two polls over one stuck key append and alarm exactly once within the mirror horizon",
  length(store_after_second.stuck) == 1 and
    Enum.count(store_after_second.metrics, fn
      {"llm_payments_stuck", %{idempotency_key: "8453:0xBAD:0"}, 1} -> true
      _ -> false
    end) == 1
)

third = decode_poll.("cron", state)

check.(
  "trailing-window reread applies nothing twice",
  third["applied"] == 0 and third["duplicates"] == 4 and third["cursor"] == 105 and
    PaymentsPollStore.llm_credit_balance("w:default|k:dm|c:tg:9:0") == balance_after_second
)

# Metadata is stamped on the same credit-entry path for push and poll, without
# dropping pre-existing metadata.
poll_entry =
  Enum.find(PaymentsPollStore.state().entries, &(&1.idempotency_key == "usdc_base:0xA:0"))

check.(
  "poll credit entry stamps rate/source/outbox_seq and preserves existing meta",
  poll_entry.meta["credit_per_usd"] == "2.0" and poll_entry.meta["source"] == "poll" and
    poll_entry.meta["outbox_seq"] == 101 and poll_entry.meta["hub_fact"] == "kept"
)

push_msg =
  Jason.encode!(%{
    action: "payment_confirmed",
    beneficiary: "w:push|k:dm|c:tg:2:0",
    amount_usd: "1.25",
    method: "card",
    ref: "push-1",
    namespace: "llm_quota",
    meta: %{"operator" => "kept"}
  })

{:reply, push_json, _} = Proxy.handle_message("payments", push_msg, state)
push_entry = Enum.find(PaymentsPollStore.state().entries, &(&1.idempotency_key == "card:push-1"))

check.(
  "push semantics stay successful while entry meta stamps rate/source and preserves keys",
  Jason.decode!(push_json)["ok"] == true and push_entry.meta["credit_per_usd"] == "2.0" and
    push_entry.meta["source"] == "push" and push_entry.meta["operator"] == "kept" and
    not Map.has_key?(push_entry.meta, "outbox_seq")
)

parent = self()

bad_meta_log =
  ExUnit.CaptureLog.capture_log(fn ->
    bad_meta_msg =
      Jason.encode!(%{
        action: "payment_confirmed",
        beneficiary: "w:push|k:dm|c:tg:3:0",
        amount_usd: "1.25",
        method: "card",
        ref: "push-bad-meta",
        namespace: "llm_quota",
        meta: ["not", "a", "map"]
      })

    {:reply, json, _} = Proxy.handle_message("payments", bad_meta_msg, state)
    send(parent, {:bad_meta_reply, json})
  end)

bad_meta_json =
  receive do
    {:bad_meta_reply, json} -> json
  end

bad_meta_entry =
  Enum.find(PaymentsPollStore.state().entries, &(&1.idempotency_key == "card:push-bad-meta"))

check.(
  "non-map push meta is dropped with a warning without crashing or storing garbage",
  Jason.decode!(bad_meta_json)["ok"] == true and
    bad_meta_entry.meta == %{
      "credit_per_usd" => "2.0",
      "method" => "card",
      "ref" => "push-bad-meta",
      "source" => "push"
    } and
    bad_meta_log =~ "dropping non-map hub payment meta" and bad_meta_log =~ "source=push"
)

# Empty filtered pages still advance by the unfiltered page's next_seq.
PaymentsPollStore.reset(cursor: 10)

foreign_only_state = %{
  state
  | settlements_fn: fn 0, 200 ->
      {:ok, %{settlements: [], max_seq: 80, next_seq: 80, complete: false}}
    end
}

foreign_only = decode_poll.("cron", foreign_only_state)

check.(
  "foreign-namespace-only page advances by unfiltered next_seq",
  foreign_only["cursor"] == 80 and foreign_only["applied"] == 0 and foreign_only["lag"] == 0
)

# A JSON-number-style amount never gains acceptance through the direct seam.
PaymentsPollStore.reset(cursor: 0)
numeric_row = row.(1, "0xFLOAT:0", %{amount_usd: 5.0})

numeric_state = %{
  state
  | settlements_fn: fn 0, 200 ->
      {:ok, %{settlements: [numeric_row], max_seq: 1, next_seq: 1, complete: true}}
    end
}

numeric = decode_poll.("cron", numeric_state)

check.(
  "numeric amount remains a permanent rejection; money inputs stay strings-only",
  numeric["applied"] == 0 and numeric["stuck"] == 1 and
    PaymentsPollStore.state().entries == [] and
    hd(PaymentsPollStore.state().stuck).reason == "bad_payment_confirmed"
)

# Credit succeeds before the cursor write. A failed cursor write reports the
# still-durable cursor, emits an alarm, and replay dedups the credit.
PaymentsPollStore.reset(cursor: 0, cursor_write_error: :db_down)
cursor_row = row.(1, "0xCURSOR:0", %{})

cursor_fail_state = %{
  state
  | settlements_fn: fn 0, 200 ->
      {:ok, %{settlements: [cursor_row], max_seq: 1, next_seq: 1, complete: true}}
    end
}

cursor_failed = decode_poll.("cron", cursor_fail_state)
cursor_failed_store = PaymentsPollStore.state()

check.(
  "cursor-write failure keeps the durable cursor while retaining the applied credit",
  cursor_failed["applied"] == 1 and cursor_failed["cursor"] == 0 and
    cursor_failed["lag"] == 1 and cursor_failed_store.cursor == 0 and
    length(cursor_failed_store.entries) == 1 and
    Enum.any?(cursor_failed_store.metrics, fn
      {"llm_payments_cursor_write_failed", %{cursor: 1}, 1} -> true
      _ -> false
    end)
)

PaymentsPollStore.heal_cursor()
cursor_replay = decode_poll.("cron", cursor_fail_state)

check.(
  "cursor-write recovery replays idempotently and advances without losing or duplicating credit",
  cursor_replay["applied"] == 0 and cursor_replay["duplicates"] == 1 and
    cursor_replay["cursor"] == 1 and length(PaymentsPollStore.state().entries) == 1
)

# Cursor-ahead is alarmed and never rewound or written.
PaymentsPollStore.reset(cursor: 200)

ahead_state = %{
  state
  | settlements_fn: fn 100, 200 ->
      {:ok, %{settlements: [], max_seq: 150, next_seq: 150, complete: true}}
    end
}

ahead = decode_poll.("cron", ahead_state)
ahead_store = PaymentsPollStore.state()

check.(
  "cursor-ahead anomaly is noted without rewind or advance",
  ahead["ok"] == true and ahead["anomaly"] == "cursor_ahead" and ahead["cursor"] == 200 and
    ahead["max_seq"] == 150 and ahead_store.cursor == 200 and ahead_store.cursor_writes == []
)

check.(
  "cursor-ahead emits both alarm and exact lag gauge",
  Enum.any?(ahead_store.metrics, fn
    {"llm_payments_cursor_ahead", %{cursor: 200, max_seq: 150}, 1} -> true
    _ -> false
  end) and
    Enum.any?(ahead_store.metrics, fn
      {"llm_payments_lag", _, -50} -> true
      _ -> false
    end)
)

# A stale hub next_seq is floored at the durable cursor, and the unchanged
# effective value is not durably rewritten.
PaymentsPollStore.reset(cursor: 50)

stale_next_state = %{
  state
  | settlements_fn: fn 0, 200 ->
      {:ok, %{settlements: [], max_seq: 60, next_seq: 0, complete: true}}
    end
}

stale_next = decode_poll.("cron", stale_next_state)
stale_next_store = PaymentsPollStore.state()

check.(
  "stale hub next_seq cannot rewind the durable cursor",
  stale_next["cursor"] == 50 and stale_next_store.cursor == 50
)

check.(
  "unchanged cursor values skip the durable write",
  stale_next_store.cursor_writes == []
)

# Exact dense-sequence liveness probe from the review: with cursor/lag/limit
# 100/100/100, the trailing window consumes 100 rows, so the read must request
# another 100 rows of progress capacity and credit seqs 101..150 immediately.
dense_rows = for seq <- 1..150, do: row.(seq, "dense-#{seq}", %{})
dense_seen = for seq <- 1..100, do: "usdc_base:dense-#{seq}"
PaymentsPollStore.reset(cursor: 100, keys: dense_seen)
{:ok, dense_reads} = Agent.start_link(fn -> [] end)

dense_state = %{
  state
  | settlements_fn: fn after_seq, limit ->
      Agent.update(dense_reads, &(&1 ++ [{after_seq, limit}]))

      page =
        dense_rows
        |> Enum.filter(&(Map.fetch!(&1, :outbox_seq) > after_seq))
        |> Enum.take(limit)

      next_seq =
        case List.last(page) do
          nil -> after_seq
          last -> Map.fetch!(last, :outbox_seq)
        end

      {:ok, %{settlements: page, max_seq: 150, next_seq: next_seq, complete: next_seq == 150}}
    end
}

dense = decode_poll.("cron", dense_state)
dense_store = PaymentsPollStore.state()

check.(
  "dense 1..150 review probe credits 101..150 in one poll without stalling",
  Agent.get(dense_reads, & &1) == [{0, 200}] and dense["applied"] == 50 and
    dense["duplicates"] == 100 and dense["cursor"] == 150 and dense["lag"] == 0 and
    Enum.map(dense_store.entries, & &1.idempotency_key) ==
      Enum.map(101..150, &"usdc_base:dense-#{&1}")
)

# Concurrent overlapping ticks share the existing atomic seen-mark: one
# credits and the other dedups.
PaymentsPollStore.reset(cursor: 0)
concurrent_row = row.(1, "0xRACE:0", %{})

concurrent_state = %{
  state
  | settlements_fn: fn 0, 200 ->
      {:ok, %{settlements: [concurrent_row], max_seq: 1, next_seq: 1, complete: true}}
    end
}

concurrent_replies =
  1..2
  |> Enum.map(fn _ -> Task.async(fn -> decode_poll.("cron", concurrent_state) end) end)
  |> Enum.map(&Task.await(&1, 5_000))

check.(
  "overlapping polls credit exactly once via the atomic seen-mark",
  Enum.sum(Enum.map(concurrent_replies, & &1["applied"])) == 1 and
    Enum.sum(Enum.map(concurrent_replies, & &1["duplicates"])) == 1 and
    length(PaymentsPollStore.state().entries) == 1
)

failed = Agent.get(failures, & &1)
IO.puts("")

if failed == [] do
  IO.puts("LLM_PROXY_PAYMENTS_POLL: ALL PASS")
else
  IO.puts("LLM_PROXY_PAYMENTS_POLL: FAILED")
  Enum.each(Enum.reverse(failed), &IO.puts("  Failed: #{&1}"))
  System.halt(1)
end
