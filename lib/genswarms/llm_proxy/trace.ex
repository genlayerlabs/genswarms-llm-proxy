defmodule Genswarms.LlmProxy.Trace do
  @moduledoc """
  Opt-in private, append-only buffered-call capture. The host implements
  `record_llm_trace(event) :: :ok | {:error, term}` on `trace_store_mod`.
  Never publishes payloads through object messages, metrics, or logs.
  Sink failure latches admission closed until the proxy is restarted after repair.
  """
  import Plug.Conn
  alias Genswarms.LlmProxy, as: Proxy

  def prepare(conn, _) do
    opts = conn.private.router_opts

    if opts[:trace_store_mod] && conn.request_path in ["/v1/chat/completions", "/v1/compact"] do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] ->
          case Proxy.lookup_session(opts.state_pid, token) do
            nil -> conn
            session -> start(conn, opts, session, token)
          end

        _ ->
          conn
      end
    else
      conn
    end
  end

  defp start(conn, opts, session, token) do
    cond do
      Agent.get(opts.state_pid, &Map.get(&1, :trace_failed, false)) ->
        reject(conn, 503, "trace_storage_unavailable")

      conn.body_params["stream"] in [true, "true", 1] ->
        reject(conn, 422, "trace_requires_buffered_request")

      true ->
        id = "trace_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

        context = %{
          id: id,
          identity:
            Map.take(session, [:workspace_key, :kind, :conversation_id, :slot, :budget_identity]),
          secrets: [token, Genswarms.LlmProxy.Secret.reveal(opts[:upstream_api_key])],
          # Correlation is a client label, never authorization or ownership.
          correlation: get_req_header(conn, "x-agent-turn-id") |> List.first() |> bounded_label()
        }

        opts = Map.put(opts, :trace_context, context)

        if emit(opts, "request", %{path: conn.request_path, body: conn.body_params}) == :ok do
          conn
          |> put_private(:router_opts, opts)
          |> register_before_send(fn result ->
            emit(opts, "response", %{
              status: result.status,
              capture_incomplete: Process.get({__MODULE__, id, :failed}, false),
              body: IO.iodata_to_binary(result.resp_body || "")
            })

            failed = Process.delete({__MODULE__, id, :failed}) == true
            Process.delete({__MODULE__, id, :seq})

            result
            |> put_resp_header("x-llm-trace-id", id)
            |> put_resp_header(
              "x-llm-trace-status",
              if(failed, do: "incomplete", else: "complete")
            )
          end)
        else
          reject(conn, 503, "trace_storage_unavailable")
        end
    end
  end

  def emit(%{trace_context: ctx, trace_store_mod: sink} = opts, type, data) do
    key = {__MODULE__, ctx.id, :seq}
    seq = Process.get(key, 0)

    event = %{
      schema: "genswarms.llm-trace/1",
      trace_id: ctx.id,
      seq: seq,
      identity: ctx.identity,
      correlation: ctx.correlation,
      type: type,
      observed_at: DateTime.to_iso8601(DateTime.utc_now()),
      data: scrub(data, ctx.secrets)
    }

    Process.put(key, seq + 1)

    result =
      try do
        sink.record_llm_trace(event)
      rescue
        _ -> {:error, :trace_storage_failed}
      catch
        _, _ -> {:error, :trace_storage_failed}
      end

    if result == :ok do
      :ok
    else
      Process.put({__MODULE__, ctx.id, :failed}, true)
      Agent.update(opts.state_pid, &Map.put(&1, :trace_failed, true))
      {:error, :trace_storage_failed}
    end
  end

  def emit(_, _, _), do: :ok

  def wrap(upstream, opts) do
    fn body, headers, actual_opts ->
      if blocked?(opts) or emit(opts, "upstream_request", %{body: body}) != :ok do
        {:error, :trace_storage_failed}
      else
        result = upstream.(body, headers, actual_opts)
        # Preserve the paid result even if capture fails; never retry to repair logging.
        emit(opts, "upstream_result", %{result: Tuple.to_list(result)})
        result
      end
    end
  end

  defp blocked?(%{trace_context: _, state_pid: pid}),
    do: Agent.get(pid, &Map.get(&1, :trace_failed, false))

  defp blocked?(_), do: false

  def scrub(value, secrets) when is_binary(value) do
    Enum.reduce(secrets, value, fn
      secret, acc when is_binary(secret) and byte_size(secret) > 0 ->
        String.replace(acc, secret, "[REDACTED]")

      _, acc ->
        acc
    end)
  end

  def scrub(value, secrets) when is_list(value), do: Enum.map(value, &scrub(&1, secrets))
  def scrub(value, secrets) when is_tuple(value), do: value |> Tuple.to_list() |> scrub(secrets)

  def scrub(value, secrets) when is_map(value) do
    Map.new(value, fn {k, v} ->
      sensitive =
        String.downcase(to_string(k)) in ~w(authorization api_key access_token refresh_token private_key)

      {k, if(sensitive, do: "[REDACTED]", else: scrub(v, secrets))}
    end)
  end

  def scrub(value, _), do: value

  defp bounded_label(nil), do: nil
  defp bounded_label(text), do: String.slice(text, 0, 256)

  defp reject(conn, status, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{code: code}}))
    |> halt()
  end
end
