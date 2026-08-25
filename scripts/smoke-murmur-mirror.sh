#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Build/Products/Release/murmur-mirror"
PORT=17771

if [ ! -x "$APP" ]; then
  echo "murmur-mirror is not built at $APP" >&2
  exit 1
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use; smoke test will not disturb another listener" >&2
  exit 1
fi

log_file="$(mktemp -t murmur-mirror-smoke)"
"$APP" --port "$PORT" >"$log_file" 2>&1 &
server_pid=$!

cleanup() {
  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" >/dev/null 2>&1 || true
  rm -f "$log_file"
}
trap cleanup EXIT

for _ in {1..50}; do
  if curl --silent --fail "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | rg -q "127\\.0\\.0\\.1:$PORT"; then
      echo "murmur-mirror listener is not bound only to 127.0.0.1" >&2
      exit 1
    fi
    "$APP" --smoke-client --port "$PORT"
    exit 0
  fi
  sleep 0.1
done

echo "murmur-mirror did not become healthy" >&2
exit 1
