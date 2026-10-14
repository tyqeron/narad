#!/usr/bin/env bash
set -euo pipefail
narad_repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$narad_repo"
export NARAD_STATE="${NARAD_STATE:-$narad_repo/.narad}"
if [[ "$NARAD_STATE" != /* ]]; then
  export NARAD_STATE="$narad_repo/$NARAD_STATE"
fi
narad_api_port="${NARAD_API_PORT:-45700}"
narad_control_port="${NARAD_CONTROL_PORT:-45678}"
narad_daemon_pid=""
cleanup() {
  if [[ -n "$narad_daemon_pid" ]]; then
    kill -INT "$narad_daemon_pid" 2>/dev/null || true
    wait "$narad_daemon_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
cargo build --locked -p narad
if ! target/debug/narad --state "$NARAD_STATE" --api-port "$narad_api_port" status >/dev/null 2>&1; then
  target/debug/narad --state "$NARAD_STATE" --api-port "$narad_api_port" serve --name "${1:-My laptop}" --port "$narad_control_port" &
  narad_daemon_pid=$!
  narad_ready=false
  for _ in {1..50}; do
    if target/debug/narad --state "$NARAD_STATE" --api-port "$narad_api_port" status >/dev/null 2>&1; then
      narad_ready=true
      break
    fi
    if ! kill -0 "$narad_daemon_pid" 2>/dev/null; then
      printf '%s\n' 'Narad daemon failed to start.' >&2
      exit 1
    fi
    sleep 0.1
  done
  if [[ "$narad_ready" != true ]]; then
    printf '%s\n' 'Narad daemon startup timed out.' >&2
    exit 1
  fi
fi
cd clients/flutter
flutter pub get
flutter run -d linux
