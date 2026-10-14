#!/usr/bin/env bash
# Shared helpers for the dispatch scripts. Sourced, never executed.
# Requires: bash 3.2+, git, jq, perl (POSIX::setsid), python3 optional.

set -euo pipefail

DISPATCH_HOME="${DISPATCH_HOME:-$HOME/.dispatch}"
SKILL_DIR="${CLAUDE_SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

die() { echo "dispatch: $*" >&2; exit 2; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need git; need jq; need perl

repo_root() { git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"; }

# Slug: <basename>-<8 hex of the absolute path>, so two checkouts of one repo never share state.
repo_slug() {
  local root; root="$(repo_root)"
  local hash
  if command -v shasum >/dev/null 2>&1; then hash="$(printf '%s' "$root" | shasum | cut -c1-8)"
  else hash="$(printf '%s' "$root" | cksum | cut -d' ' -f1)"; fi
  printf '%s-%s' "$(basename "$root")" "$hash"
}

state_dir() { local d="$DISPATCH_HOME/$(repo_slug)"; mkdir -p "$d/runs"; printf '%s' "$d"; }
state_file() { printf '%s/state.json' "$(state_dir)"; }

# Config: <repo>/.claude/dispatch.json, else $DISPATCH_HOME/config.json.
config_path() {
  local root; root="$(repo_root)"
  if [ -f "$root/.claude/dispatch.json" ]; then printf '%s' "$root/.claude/dispatch.json"
  elif [ -f "$DISPATCH_HOME/config.json" ]; then printf '%s' "$DISPATCH_HOME/config.json"
  else die "no config: create $root/.claude/dispatch.json (see config.example.json)"; fi
}

cfg() { jq -r "$1" "$(config_path)"; }          # raw string or null
cfg_json() { jq -c "$1" "$(config_path)"; }     # compact JSON

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ts_compact() { date -u +%Y%m%d-%H%M%S; }

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# Extract every string value of a JSON-lines or plain-text file, one per line.
# Works for opencode --format json, claude stream-json, agy json, and plain text.
text_surface() {
  local f="$1"
  [ -f "$f" ] || return 0
  if jq -e . "$f" >/dev/null 2>&1; then
    jq -r '.. | strings' "$f" 2>/dev/null || true
  else
    # Try line by line (JSONL); fall back to raw text.
    local any=0
    while IFS= read -r line || [ -n "$line" ]; do
      if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
        any=1; printf '%s' "$line" | jq -r '.. | strings' 2>/dev/null || true
      else
        printf '%s\n' "$line"
      fi
    done < "$f"
    [ "$any" = 1 ] || cat "$f"
  fi
}

# The verdict is the LAST line matching RESULT: PASSED|FAIL|BLOCKED [— reason]. Never the exit code.
# Prints "<verdict>\t<reason>" or nothing.
result_line() {
  text_surface "$1" | tr -d '\r' \
    | grep -E '^[[:space:]]*RESULT:[[:space:]]*(PASSED|FAIL|BLOCKED)' | tail -1 \
    | sed -E 's/^[[:space:]]*RESULT:[[:space:]]*(PASSED|FAIL|BLOCKED)[[:space:]]*(-|—|–|:)?[[:space:]]*(.*)$/\1\t\3/'
}
