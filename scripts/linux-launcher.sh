#!/usr/bin/env bash
# Installed beside app/ and the Rust narad binary.
set -euo pipefail
umask 077
app_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export NARAD_STATE="${NARAD_STATE:-${XDG_DATA_HOME:-$HOME/.local/share}/narad}"
mkdir -p -- "$NARAD_STATE"
NARAD_STATE="$(cd -- "$NARAD_STATE" && pwd)"
api_port="${NARAD_API_PORT:-45700}"
control_port="${NARAD_CONTROL_PORT:-45678}"
daemon_pid=""
gui_pid=""
cleanup() {
  trap - EXIT INT TERM
  if [[ -n "$gui_pid" ]] && kill -0 "$gui_pid" 2>/dev/null; then
    kill -TERM "$gui_pid" 2>/dev/null || true
    wait "$gui_pid" 2>/dev/null || true
  fi
  if [[ -n "$daemon_pid" ]]; then
    kill -INT "$daemon_pid" 2>/dev/null || true
    for ((attempt=0; attempt<50; attempt++)); do
      kill -0 "$daemon_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -TERM "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if ! "$app_root/narad" --state "$NARAD_STATE" --api-port "$api_port" status >/dev/null 2>&1; then
  device_name="${NARAD_DEVICE_NAME:-}"
  if [[ -z "$device_name" ]]; then
    device_name="$(hostnamectl --pretty 2>/dev/null || true)"
    [[ -n "$device_name" ]] || device_name="$(hostname -s)"
  fi
  "$app_root/narad" --state "$NARAD_STATE" --api-port "$api_port" serve \
    --name "$device_name" --port "$control_port" &
  daemon_pid=$!
  ready=false
  for ((attempt=0; attempt<100; attempt++)); do
    if "$app_root/narad" --state "$NARAD_STATE" --api-port "$api_port" status >/dev/null 2>&1; then
      ready=true
      break
    fi
    if ! kill -0 "$daemon_pid" 2>/dev/null; then
      echo 'Narad backend failed to start. Check the state directory and listening ports.' >&2
      exit 1
    fi
    sleep 0.1
  done
  if [[ "$ready" != true ]]; then
    echo 'Narad backend startup timed out.' >&2
    exit 1
  fi
fi
cd -- "$app_root/app"
./narad_client "$@" &
gui_pid=$!
wait "$gui_pid"
gui_pid=""
