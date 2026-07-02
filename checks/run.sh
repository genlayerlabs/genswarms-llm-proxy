#!/bin/sh
# Runs every standalone proxy check (no Postgres, no network). Exit 1 on any failure.
set -e
cd "$(dirname "$0")/.."
fail=0
for f in checks/llm_proxy_*.exs; do
  if mix run "$f" >/tmp/proxy-check.out 2>&1; then
    echo "ok   $f"
  else
    echo "FAIL $f"
    tail -20 /tmp/proxy-check.out
    fail=1
  fi
done
exit $fail
