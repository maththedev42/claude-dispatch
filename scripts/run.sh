#!/usr/bin/env bash
# Start one executor run for one prompt file on one ladder rung, detached, and exit.
#
# usage: run.sh <prompt-file> <rung-index> [--allow-dirty] [--note <file>] [--session <id>] [--model <id>]
#
# Exit codes: 0 started, 3 tracked-dirty tree (paths on stdout), 4 a run is already alive,
#             5 no usable model on this rung, 2 config/usage error.
#
# The executor is started in its own session (perl POSIX::setsid), with stdin closed,
# stdout/stderr in the run directory, and an environment built from the config allowlist only.
# It keeps running if the coordinator session dies. The verdict is read later by status.sh
# from the RESULT: line and the landed commit, never from the exit code.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PROMPT="${1:-}"; RUNG="${2:-}"
[ -n "$PROMPT" ] && [ -n "$RUNG" ] || die "usage: run.sh <prompt-file> <rung-index> [--allow-dirty] [--note <file>] [--session <id>] [--model <id>]"
shift 2
ALLOW_DIRTY=0; NOTE=""; SESSION=""; MODEL_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --note) NOTE="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --model) MODEL_OVERRIDE="$2"; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done

ROOT="$(repo_root)"; cd "$ROOT"
[ -f "$PROMPT" ] || die "prompt file not found: $PROMPT"
STATE="$(state_file)"; SDIR="$(state_dir)"

# 1. One live run per repo.
if [ -f "$STATE" ]; then
  OLD_PID="$(jq -r '.pid // empty' "$STATE")"
  if pid_alive "$OLD_PID"; then
    echo "a run is already alive: pid $OLD_PID, prompt $(jq -r .prompt "$STATE")"; exit 4
  fi
fi

# 2. Tracked-dirty preflight (untracked files are ignored on purpose).
DIRTY="$(git status --porcelain --untracked-files=no)"
if [ -n "$DIRTY" ] && [ "$ALLOW_DIRTY" != 1 ]; then
  echo "tracked files are modified; stop or pass --allow-dirty for a resume:"; echo "$DIRTY"; exit 3
fi

# 3. Rung and model.
LADDER_LEN="$(cfg_json '.ladder | length')"
[ "$RUNG" -ge 0 ] && [ "$RUNG" -lt "$LADDER_LEN" ] 2>/dev/null || die "rung $RUNG out of range (ladder has $LADDER_LEN)"
KIND="$(cfg ".ladder[$RUNG].kind")"
TIMEOUT_MIN="$(cfg ".ladder[$RUNG].timeoutMinutes // .timeoutMinutes // 90")"
MODEL=""
if [ -n "$MODEL_OVERRIDE" ]; then
  MODEL="$MODEL_OVERRIDE"
else
  MODELS="$(cfg_json ".ladder[$RUNG].models // []")"
  COUNT="$(printf '%s' "$MODELS" | jq 'length')"
  if [ "$KIND" = opencode ] && [ "$COUNT" -gt 0 ]; then
    # Free models are "limited time": keep only the ones the CLI still lists (read-only call).
    AVAILABLE="$(opencode models 2>/dev/null || true)"
    for i in $(seq 0 $((COUNT - 1))); do
      m="$(printf '%s' "$MODELS" | jq -r ".[$i]")"
      if printf '%s\n' "$AVAILABLE" | grep -qxF "$m"; then MODEL="$m"; break; fi
    done
    if [ -z "$MODEL" ]; then echo "none of the configured opencode models is listed by 'opencode models'"; exit 5; fi
  elif [ "$COUNT" -gt 0 ]; then
    MODEL="$(printf '%s' "$MODELS" | jq -r '.[0]')"
  fi
fi

# 4. Run directory and composed prompt.
RUN_ID="$(ts_compact)-$(basename "$PROMPT" .md)"
RUN="$SDIR/runs/$RUN_ID"; mkdir -p "$RUN"
RULES="$(cfg '.reviewRules // empty')"
[ -n "$RULES" ] || RULES="the rules file of the project"
{
  cat "$PROMPT"
  printf '\n\n'
  sed -e "s|{{RULES}}|${RULES}|g" -e "s|{{PROMPT}}|$PROMPT|g" "$SKILL_DIR/templates/trailer.md"
  if [ -n "$NOTE" ]; then printf '\n\n'; cat "$NOTE"; fi
} > "$RUN/prompt.md"

BASE_HEAD="$(git rev-parse HEAD)"; BRANCH="$(git rev-parse --abbrev-ref HEAD)"
PROMPT_SHA="$(git hash-object "$PROMPT")"
printf '%s\n' "$DIRTY" > "$RUN/dirty-before.txt"

# 5. Argv per kind. Every flag below was read from the CLI's --help (see README, "Executors").
POINTER="Read the file $RUN/prompt.md and carry out the task it describes. Everything in that file applies, including the RESULT line rule at its end."
case "$KIND" in
  opencode)
    CMD=(opencode run --format json --pure --auto --dir "$ROOT")
    [ -n "$MODEL" ] && CMD+=(-m "$MODEL")
    [ -n "$SESSION" ] && CMD+=(-s "$SESSION")
    CMD+=("$POINTER") ;;
  claude)
    CMD=(claude -p "$POINTER" --output-format stream-json --verbose --permission-mode bypassPermissions)
    [ -n "$MODEL" ] && CMD+=(--model "$MODEL")
    [ -n "$SESSION" ] && CMD+=(--resume "$SESSION") ;;
  agy)
    CMD=(agy -p "$POINTER" --output-format json --dangerously-skip-permissions)
    [ -n "$MODEL" ] && CMD+=(--model "$MODEL")
    [ -n "$SESSION" ] && CMD+=(--conversation "$SESSION")
    # Return partial output 15 s before the watchdog would kill the process.
    CMD+=(--print-timeout "$(( TIMEOUT_MIN * 60 - 15 ))s") ;;
  *) die "unknown rung kind: $KIND" ;;
esac
printf '%s\n' "${CMD[@]}" > "$RUN/argv.txt"

# 6. Environment: allowlist only. Nothing else from the coordinator's env reaches the executor.
ENV_ARGS=()
for name in $(cfg_json '.env.pass // ["HOME","PATH","LANG","TERM","TMPDIR"]' | jq -r '.[]'); do
  if [ -n "${!name:-}" ]; then ENV_ARGS+=("$name=${!name}"); fi
done
for k in $(cfg_json '.env.set // {}' | jq -r 'keys[]'); do
  ENV_ARGS+=("$k=$(cfg_json '.env.set' | jq -r --arg k "$k" '.[$k]')")
done
ENV_ARGS+=("DISPATCH_RUN_DIR=$RUN")

# 7. Detach: new session (perl POSIX::setsid), stdin closed, outputs captured, exit code recorded.
WRAP="$RUN/wrap.sh"
{
  echo '#!/usr/bin/env bash'
  echo "cd $(printf '%q' "$ROOT")"
  printf 'env -i'; for a in "${ENV_ARGS[@]}"; do printf ' %q' "$a"; done
  printf ' '; for a in "${CMD[@]}"; do printf '%q ' "$a"; done
  printf ' < /dev/null > %q 2> %q\n' "$RUN/stdout.jsonl" "$RUN/stderr.log"
  echo 'code=$?'
  echo "echo \$code > $(printf '%q' "$RUN/exit.txt")"
  echo "date -u +%Y-%m-%dT%H:%M:%SZ > $(printf '%q' "$RUN/ended.txt")"
} > "$WRAP"
chmod +x "$WRAP"

nohup perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!"' -- "$WRAP" >/dev/null 2>&1 &
PID=$!

# Watchdog in its own session: kills the executor's process group after the timeout.
WATCH="$RUN/watchdog.sh"
{
  echo '#!/usr/bin/env bash'
  echo "sleep $(( TIMEOUT_MIN * 60 ))"
  echo "if [ ! -f $(printf '%q' "$RUN/exit.txt") ] && kill -0 $PID 2>/dev/null; then kill -- -$PID 2>/dev/null; sleep 5; kill -9 -- -$PID 2>/dev/null; echo timeout > $(printf '%q' "$RUN/timeout.txt"); fi"
} > "$WATCH"
chmod +x "$WATCH"
nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- "$WATCH" >/dev/null 2>&1 &
WPID=$!

# 8. State.
jq -n --arg prompt "$PROMPT" --arg promptSha "$PROMPT_SHA" --argjson rung "$RUNG" --arg kind "$KIND" \
  --arg model "$MODEL" --argjson pid "$PID" --argjson watchdogPid "$WPID" --arg run "$RUN" \
  --arg startedAt "$(now_iso)" --arg baseHead "$BASE_HEAD" --arg branch "$BRANCH" \
  --argjson timeoutMinutes "$TIMEOUT_MIN" --arg session "$SESSION" --argjson allowDirty "$ALLOW_DIRTY" \
  '{prompt:$prompt, promptSha:$promptSha, rung:$rung, kind:$kind, model:$model, pid:$pid, watchdogPid:$watchdogPid,
    runDir:$run, startedAt:$startedAt, baseHead:$baseHead, branch:$branch, timeoutMinutes:$timeoutMinutes,
    session:(if $session=="" then null else $session end), allowDirty:($allowDirty==1), status:"running"}' \
  > "$RUN/meta.json"
cp "$RUN/meta.json" "$STATE"
# Append to the per-repo history (one line per run) so a new session can see what happened before.
jq -c . "$RUN/meta.json" >> "$SDIR/history.jsonl"

jq -c '{status, prompt, rung, kind, model, pid, runDir}' "$STATE"
