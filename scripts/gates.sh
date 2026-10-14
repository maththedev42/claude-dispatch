#!/usr/bin/env bash
# Run the configured gates at a fixed commit in a detached worktree, sequentially, one heavy
# command at a time, and print a table. The worktree is removed on exit whatever happens.
# Never run while an executor is alive in the same repo (status.sh .alive).
#
# usage: gates.sh <sha> [--keep]
# Config: gates.commands (array of shell strings, run in order from the worktree root),
#         gates.symlink (paths to symlink from the checkout, e.g. node_modules),
#         gates.timeoutMinutes (per command, default 30).
# Logs: $DISPATCH_HOME/<slug>/gates/<sha>-<ts>/gN.log ; summary.json next to them.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
SHA="${1:-}"; [ -n "$SHA" ] || die "usage: gates.sh <sha> [--keep]"
KEEP=0; [ "${2:-}" = "--keep" ] && KEEP=1

ROOT="$(repo_root)"; cd "$ROOT"
git rev-parse --verify "$SHA^{commit}" >/dev/null 2>&1 || die "not a commit: $SHA"
if [ -f "$(state_file)" ] && pid_alive "$(jq -r '.pid // empty' "$(state_file)")"; then die "an executor is alive; gates wait"; fi

OUT="$(state_dir)/gates/$(git rev-parse --short "$SHA")-$(ts_compact)"; mkdir -p "$OUT"
WT="$OUT/wt"
cleanup() { if [ "$KEEP" != 1 ]; then git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT

git worktree add -q --detach "$WT" "$SHA" >/dev/null
for p in $(cfg_json '.gates.symlink // []' | jq -r '.[]'); do
  if [ -e "$ROOT/$p" ] && [ ! -e "$WT/$p" ]; then mkdir -p "$(dirname "$WT/$p")"; ln -s "$ROOT/$p" "$WT/$p"; fi
done

TMO="$(cfg '.gates.timeoutMinutes // 30')"
N=0; RESULTS='[]'
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  N=$((N+1)); LOG="$OUT/g$N.log"
  START=$(date +%s)
  # perl alarm as a portable timeout.
  CODE=0  # a failing gate must not trip set -e: record the code and keep going
  ( cd "$WT" && perl -e 'alarm shift; exec @ARGV' "$((TMO*60))" bash -lc "$cmd" ) > "$LOG" 2>&1 || CODE=$?
  SECS=$(( $(date +%s) - START ))
  SUMMARY="$(grep -E '^\s*(Test Files|Tests)\s+' "$LOG" | tail -2 | tr -s ' ' | tr '\n' ';' || true)"
  [ -n "$SUMMARY" ] || SUMMARY="$(tail -1 "$LOG" | cut -c1-120)"
  RESULTS="$(printf '%s' "$RESULTS" | jq --arg cmd "$cmd" --argjson code "$CODE" --argjson secs "$SECS" --arg log "$LOG" --arg summary "$SUMMARY" \
    '. + [{n:(length+1), cmd:$cmd, exit:$code, seconds:$secs, log:$log, summary:$summary}]')"
done < <(cfg_json '.gates.commands // []' | jq -r '.[]')

jq -n --arg sha "$SHA" --argjson results "$RESULTS" '{sha:$sha, ok:($results | all(.exit==0)), gates:$results}' | tee "$OUT/summary.json"
