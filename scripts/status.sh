#!/usr/bin/env bash
# Report the state of the current (or last) run as one JSON object. Read-only.
#
# usage: status.sh [--run <run-dir>]
#
# Fields: everything from meta.json plus
#   alive        pid still running
#   exitCode     from exit.txt once the executor exited (null while alive)
#   timedOut     the watchdog killed it
#   head         HEAD now; headMoved = head != baseHead
#   commits      list of {sha, subject} in baseHead..HEAD
#   branchNow / branchChanged
#   dirtyNow     tracked-dirty paths now (string, may be empty)
#   promptPresent  the prompt file still exists in the tree
#   verdict/reason  from the LAST "RESULT: PASSED|FAIL|BLOCKED — reason" line in the output (null if absent)
#   session      session/conversation id found in the output, for a same-session re-run
#   deniedActions  (agy) count of denied_actions in the envelope
#   pushed       true if the reflog shows a push-like update of the remote branch since start (best effort)

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

RUN=""
while [ $# -gt 0 ]; do case "$1" in --run) RUN="$2"; shift 2 ;; *) die "unknown option $1" ;; esac; done

ROOT="$(repo_root)"; cd "$ROOT"
STATE="$(state_file)"
if [ -z "$RUN" ]; then
  [ -f "$STATE" ] || { echo '{"status":"idle"}'; exit 0; }
  RUN="$(jq -r .runDir "$STATE")"
fi
META="$RUN/meta.json"; [ -f "$META" ] || die "no meta.json in $RUN"

PID="$(jq -r .pid "$META")"
ALIVE=false; pid_alive "$PID" && ALIVE=true
EXIT=null; [ -f "$RUN/exit.txt" ] && EXIT="$(cat "$RUN/exit.txt")"
TIMED=false; [ -f "$RUN/timeout.txt" ] && TIMED=true
BASE="$(jq -r .baseHead "$META")"
HEAD_NOW="$(git rev-parse HEAD)"
BRANCH_BASE="$(jq -r .branch "$META")"; BRANCH_NOW="$(git rev-parse --abbrev-ref HEAD)"
COMMITS="$(git log --format='%H%x09%s' "$BASE..$HEAD_NOW" 2>/dev/null | jq -R -s 'split("\n") | map(select(length>0)) | map(split("\t") | {sha:.[0], subject:.[1]})')"
DIRTY_NOW="$(git status --porcelain --untracked-files=no)"
PROMPT="$(jq -r .prompt "$META")"
PRESENT=false; [ -f "$PROMPT" ] && PRESENT=true

VERDICT=null; REASON=null
RL="$(result_line "$RUN/stdout.jsonl" || true)"
if [ -n "$RL" ]; then
  VERDICT="$(printf '%s' "$RL" | cut -f1 | jq -R .)"
  REASON="$(printf '%s' "$RL" | cut -f2- | jq -R .)"
fi

# Session id: opencode `sessionID`, agy `conversation_id`, claude `session_id`.
SESSION="$( { jq -r 'select(type=="object") | (.sessionID // .conversation_id // .session_id // empty)' "$RUN/stdout.jsonl" 2>/dev/null \
  || jq -r '.. | objects | (.sessionID // .conversation_id // .session_id // empty)' "$RUN/stdout.jsonl" 2>/dev/null; } | grep -v '^$' | head -1 || true)"
[ -n "$SESSION" ] && SESSION="$(printf '%s' "$SESSION" | jq -R .)" || SESSION=null

DENIED="$( { jq -r 'select(type=="object") | .denied_actions // empty | length' "$RUN/stdout.jsonl" 2>/dev/null || true; } | head -1)"
[ -n "$DENIED" ] || DENIED=0

# Push detection: a remote-tracking ref reflog entry written by a push after the run started.
# (`git push` records "update by push" in refs/remotes/<remote>/<branch>'s reflog with a timestamp.)
STARTED="$(jq -r .startedAt "$META")"
START_EPOCH="$(perl -MTime::Local -e 'my ($y,$mo,$d,$h,$mi,$s)=$ARGV[0]=~/(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)Z/; print timegm($s,$mi,$h,$d,$mo-1,$y)' "$STARTED")"
PUSHED=false
for ref in $(git for-each-ref --format='%(refname)' 'refs/remotes/' 2>/dev/null); do
  if git reflog show --date=raw "$ref" 2>/dev/null | grep 'update by push' | grep -oE '@\{[0-9]+ ' | tr -dc '0-9\n' | awk -v s="$START_EPOCH" '$1 >= s {found=1} END {exit !found}'; then PUSHED=true; break; fi
done

STATUS=running
if [ "$ALIVE" = false ]; then STATUS=exited; fi

jq -n --slurpfile meta "$META" --argjson alive "$ALIVE" --argjson exitCode "$EXIT" --argjson timedOut "$TIMED" \
  --arg head "$HEAD_NOW" --argjson commits "$COMMITS" --arg branchNow "$BRANCH_NOW" --arg dirtyNow "$DIRTY_NOW" \
  --argjson promptPresent "$PRESENT" --argjson verdict "$VERDICT" --argjson reason "$REASON" --argjson session "$SESSION" \
  --argjson deniedActions "$DENIED" --argjson pushed "$PUSHED" --arg status "$STATUS" \
  '$meta[0] + {status:$status, alive:$alive, exitCode:$exitCode, timedOut:$timedOut, head:$head,
    headMoved:($head != $meta[0].baseHead), commits:$commits, branchNow:$branchNow,
    branchChanged:($branchNow != $meta[0].branch), dirtyNow:$dirtyNow, promptPresent:$promptPresent,
    verdict:$verdict, reason:$reason, session:$session, deniedActions:$deniedActions, pushed:$pushed}'
