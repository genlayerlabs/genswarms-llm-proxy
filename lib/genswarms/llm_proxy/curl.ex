defmodule Genswarms.LlmProxy.Curl do
  @moduledoc """
  THE single curl seam. Before this module the binary resolution was copy-pasted
  five times with TWO different fallbacks (`/run/current-system/sw/bin/curl` in
  ingress/sender/rally vs `/usr/bin/curl` in memory/browse_core), and rally inlined
  the `-w "\\n%{http_code}"` status-split twice — duplicated, untestable, and
  raising `:enoent` inside fire-and-forget Tasks when curl wasn't at the hard-coded
  path (the failure simply vanished).

  This module gives the objects:
    - `bin/0` — clean resolution: `{:ok, path} | {:error, :no_curl}`. Never a path
      that doesn't exist.
    - `bin!/0` — raising form for legacy call-sites whose error handling lives
      downstream (ingress's poll classifier, sender's send classifier).
    - `parse_response/1` — the PURE status-split for the `-w "\\n%{http_code}"`
      convention, shared and tested (mirrors `Wingston.Browse.parse_curl_head/1`).
    - `get/2` / `post/2` — default fetchers. Objects take these as injectable funs
      in their init config (e.g. rally's `http_get:`/`http_post:`), so HTTP
      classification is testable offline with a canned fun.

  The objects shell out to curl because `:httpc` is unusable in this OTP build
  (`:http_util` undefined — see migration-gaps appendix).
  """

  @nix_curl "/run/current-system/sw/bin/curl"
  @usr_curl "/usr/bin/curl"

  @doc "Resolve the curl binary: {:ok, path} | {:error, :no_curl}. Never a phantom path."
  def bin do
    cond do
      path = System.find_executable("curl") -> {:ok, path}
      File.exists?(@nix_curl) -> {:ok, @nix_curl}
      File.exists?(@usr_curl) -> {:ok, @usr_curl}
      true -> {:error, :no_curl}
    end
  end

  @doc """
  Raising form for call-sites whose failure handling lives downstream (the old
  behavior was a hard-coded fallback path that made System.cmd raise :enoent;
  this raises a clear message instead).
  """
  def bin! do
    case bin() do
      {:ok, path} -> path
      {:error, :no_curl} -> raise "curl not found on PATH (or at #{@nix_curl} / #{@usr_curl})"
    end
  end

  @doc """
  Split a curl output produced with `-w "\\n%{http_code}"` into
  `{:ok, status_code, body}` — `{:error, :bad_http_response}` when the trailing
  status line isn't numeric. Pure; public for tests. Handles the empty body
  (status only), a multi-line (pretty-printed JSON) body, and a body whose last
  line is itself numeric (the -w status is always the FINAL line).
  """
  def parse_response(out) when is_binary(out) do
    case String.split(String.trim_trailing(out), "\n") do
      [only] ->
        case Integer.parse(only) do
          {code, _} -> {:ok, code, ""}
          :error -> {:error, :bad_http_response}
        end

      parts ->
        status = List.last(parts)
        body = parts |> Enum.drop(-1) |> Enum.join("\n")

        case Integer.parse(status) do
          {code, _} -> {:ok, code, body}
          :error -> {:error, :bad_http_response}
        end
    end
  end

  @doc """
  GET `url`, returning `{:ok, status, body} | {:error, :no_curl | :bad_http_response
  | {:curl, exit_code}}`. Options: `timeout:` seconds (default 10),
  `headers:` [{name, value}].
  """
  def get(url, opts \\ []) do
    request(["-s", "-w", "\n%{http_code}"] ++ common_args(opts) ++ ["--", url])
  end

  @doc """
  POST `opts[:body]` (default "") to `url`, same return shape as `get/2`.
  Options: `body:`, `timeout:`, `headers:`.
  """
  def post(url, opts \\ []) do
    args =
      ["-s", "-w", "\n%{http_code}", "-X", "POST"] ++
        common_args(opts) ++
        ["--data-binary", Keyword.get(opts, :body, ""), "--", url]

    request(args)
  end

  defp common_args(opts) do
    timeout = ["--max-time", to_string(Keyword.get(opts, :timeout, 10))]

    # Strip CR/LF from header values (defense in depth): curl forwards -H values
    # literally, so an embedded newline from a future untrusted caller would inject
    # on-wire headers. No current caller passes untrusted values.
    headers =
      opts
      |> Keyword.get(:headers, [])
      |> Enum.flat_map(fn {k, v} -> ["-H", "#{k}: #{String.replace(to_string(v), ~r/[\r\n]/, "")}"] end)

    timeout ++ headers
  end

  defp request(args) do
    with {:ok, bin} <- bin() do
      case System.cmd(bin, args, stderr_to_stdout: false) do
        {out, 0} -> parse_response(out)
        {_out, code} -> {:error, {:curl, code}}
      end
    end
  end
end
