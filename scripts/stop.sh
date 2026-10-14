#!/usr/bin/env bash
# Kill the live run's process group (executor and children) and its watchdog. usage: stop.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
STATE="$(state_file)"; [ -f "$STATE" ] || { echo "no run"; exit 0; }
PID="$(jq -r '.pid // empty' "$STATE")"; WPID="$(jq -r '.watchdogPid // empty' "$STATE")"
if pid_alive "$PID"; then kill -- "-$PID" 2>/dev/null || kill "$PID" 2>/dev/null || true; sleep 3; kill -9 -- "-$PID" 2>/dev/null || true; echo "stopped pid $PID"; else echo "pid $PID not alive"; fi
pid_alive "$WPID" && { kill "$WPID" 2>/dev/null || true; }
RUN="$(jq -r .runDir "$STATE")"; echo stopped > "$RUN/stopped.txt"
