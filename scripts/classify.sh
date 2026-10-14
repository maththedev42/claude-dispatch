#!/usr/bin/env bash
# Classify a finished run's failure from its ERROR SURFACE only: stderr plus the error
# events in the output stream. Never the model's prose. Order matters: not-installed,
# credits, auth, rate-limit (credits before auth because a billing failure can arrive
# as HTTP 401, e.g. opencode Zen `CreditsError` with statusCode 401).
#
# usage: classify.sh <run-dir>
# prints JSON: {kind, terminal, retryAt, evidence}
#   kind: not-installed | credits | auth | rate-limit | timeout | unknown | none
#   none = exit 0 and no error events; the verdict then comes from status.sh.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
RUN="${1:-}"; [ -d "$RUN" ] || die "usage: classify.sh <run-dir>"

SURFACE="$RUN/error-surface.txt"
{
  [ -f "$RUN/stderr.log" ] && cat "$RUN/stderr.log"
  if [ -f "$RUN/stdout.jsonl" ]; then
    # opencode: {"type":"error",...,"error":{"name":..,"data":{"message":..,"statusCode":..}}}
    # agy:      {"status":"ERROR","error":"..."}      claude: {"type":"result","is_error":true,"result":"..."}
    while IFS= read -r line || [ -n "$line" ]; do
      printf '%s' "$line" | jq -r '
        if type != "object" then empty
        elif .type == "error" then ([.error.name?, .error.data.message?, (.error.data.statusCode? | tostring)?, .error?|tostring] | map(select(. != null)) | join(" "))
        elif (.status? == "ERROR") then (.error // . | tostring)
        elif (.type? == "result" and .is_error? == true) then (.result // . | tostring)
        else empty end' 2>/dev/null || true
    done < "$RUN/stdout.jsonl"
    # Whole-file JSON (agy prints one object).
    jq -r 'if type=="object" and .status=="ERROR" then (.error // . | tostring) else empty end' "$RUN/stdout.jsonl" 2>/dev/null || true
  fi
} > "$SURFACE" 2>/dev/null || true

EXIT="$(cat "$RUN/exit.txt" 2>/dev/null || echo "")"
KIND=unknown; TERMINAL=true; RETRY=null
if [ -f "$RUN/timeout.txt" ]; then
  KIND=timeout; TERMINAL=false
elif grep -qiE '\benoent\b|command not found|no such file or directory|is not recognized as' "$SURFACE"; then
  KIND=not-installed
elif grep -qiE '\b(credit|credits|quota|billing|insufficient funds|payment|out of (tokens|balance)|balance|usage limit|hit your usage|usage cap|insufficient balance|out of credits|resource_exhausted|exhausted your capacity|individual quota reached|CreditsError)\b|\bexceeded your (usage|plan)\b' "$SURFACE"; then
  KIND=credits
elif grep -qiE '\b(log ?in|login required|unauthori[sz]ed|authenticat\w*|sign[ -]?in|signed[ -]?out|not signed in|credential|oauth|api key|ineligibletiererror)\b|\b401\b' "$SURFACE"; then
  KIND=auth
elif grep -qiE '\brate.?limit\b|too many requests|\b429\b|try again in\b' "$SURFACE"; then
  KIND=rate-limit; TERMINAL=false
elif [ "$EXIT" = "0" ] && [ ! -s "$SURFACE" ]; then
  KIND=none; TERMINAL=false
fi

# retryAt from "Resets in 31h54m27s" (agy) or "try again in 20s / 5 minutes".
if m="$(grep -oiE 'Resets in[[:space:]]+([0-9]+h)?([0-9]+m)?([0-9]+s)?' "$SURFACE" | head -1)"; [ -n "$m" ]; then
  h="$(printf '%s' "$m" | grep -oE '[0-9]+h' | tr -d h)"; mi="$(printf '%s' "$m" | grep -oE '[0-9]+m' | tr -d m)"; s="$(printf '%s' "$m" | grep -oE '[0-9]+s' | tr -d s)"
  secs=$(( ${h:-0}*3600 + ${mi:-0}*60 + ${s:-0} ))
  RETRY="\"$(perl -MPOSIX -e 'print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time + $ARGV[0]))' "$secs")\""
elif m="$(grep -oiE 'try again in[[:space:]]+[0-9]+[[:space:]]*(s|sec|seconds?|m|min|minutes?|h|hours?)' "$SURFACE" | head -1)"; [ -n "$m" ]; then
  n="$(printf '%s' "$m" | grep -oE '[0-9]+')"; u="$(printf '%s' "$m" | grep -oiE '(s|sec|seconds?|m|min|minutes?|h|hours?)$')"
  case "$u" in h*) secs=$((n*3600));; m*) secs=$((n*60));; *) secs=$n;; esac
  RETRY="\"$(perl -MPOSIX -e 'print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time + $ARGV[0]))' "$secs")\""
fi

EVIDENCE="$(head -c 600 "$SURFACE" | jq -R -s .)"
jq -n --arg kind "$KIND" --argjson terminal "$TERMINAL" --argjson retryAt "$RETRY" --argjson evidence "$EVIDENCE" --arg exitCode "$EXIT" \
  '{kind:$kind, terminal:$terminal, retryAt:$retryAt, exitCode:(if $exitCode=="" then null else ($exitCode|tonumber) end), evidence:$evidence}'
