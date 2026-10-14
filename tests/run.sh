#!/usr/bin/env bash
# Test suite for the dispatch scripts. Uses fake opencode/agy/claude from tests/bin.
# usage: bash tests/run.sh      (touches only a mktemp directory; never a real CLI)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$(cd "$HERE/../scripts" && pwd)"
TMP="$(mktemp -d)"
export DISPATCH_HOME="$TMP/dispatch-home"
export DISPATCH_FAKE_SCENARIO_FILE="$TMP/scenario.txt"
export PATH="$HERE/bin:$PATH"
export SECRET_API_KEY=leak
unset CLAUDE_SKILL_DIR
mkdir -p "$DISPATCH_HOME"

FAILS=0; PASSES=0
pass() { PASSES=$((PASSES+1)); echo "PASS  $1"; }
fail() { FAILS=$((FAILS+1)); echo "FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; }
eq() { # name actual expected
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$3] got [$2]"; fi
}
has() { # name haystack needle (fixed string)
  if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "missing [$3]"; fi
}
hasnt() {
  if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1" "unexpected [$3]"; else pass "$1"; fi
}
j() { jq -r "$2" <<<"$1"; }

cleanup() {
  local m wp
  for m in "$DISPATCH_HOME"/*/runs/*/meta.json; do
    [ -f "$m" ] || continue
    wp="$(jq -r '.watchdogPid // empty' "$m")"
    [ -n "$wp" ] && { pkill -P "$wp" 2>/dev/null; kill "$wp" 2>/dev/null; } || true
    wp="$(jq -r '.pid // empty' "$m")"
    [ -n "$wp" ] && { kill -- "-$wp" 2>/dev/null; } || true
  done
  if [ "$FAILS" = 0 ]; then rm -rf "$TMP"; else echo "temp dir kept: $TMP"; fi
}
trap cleanup EXIT

# ---- fixture ---------------------------------------------------------------
PROMPT1=".planning/queue/01-app-first.md"
mkrepo() {
  REPO="$(mktemp -d "$TMP/repo.XXXXXX")"
  cd "$REPO" || exit 1
  git init -q -b main .
  git config user.email t@example.com; git config user.name Tester
  git config commit.gpgsign false; git config core.hooksPath /dev/null
  mkdir -p .planning/queue .claude
  cat > .planning/queue/00-OVERVIEW.md <<'MD'
# Overview

| Order | File | Notes |
|---|---|---|
| 1 | 01-app-first.md | first |
| 2 | 02-app-second.md | second |
MD
  printf '# 01 - App: first\n\nDo the first thing. PROMPT-TEXT-ONE\n' > .planning/queue/01-app-first.md
  printf '# 02 - App: second\n\nDo the second thing.\n' > .planning/queue/02-app-second.md
  echo "hello" > README.md
  cat > .claude/dispatch.json <<'JSON'
{
  "promptDir": ".planning/queue",
  "order": "overview-table",
  "overview": ".planning/queue/00-OVERVIEW.md",
  "reviewRules": ".planning/queue/00-OVERVIEW.md",
  "ladder": [
    {"kind": "opencode", "models": ["opencode/gone-free", "opencode/big-pickle"], "timeoutMinutes": 1},
    {"kind": "agy", "models": ["m-agy"], "timeoutMinutes": 1},
    {"kind": "claude", "models": [], "timeoutMinutes": 1}
  ],
  "env": {"pass": ["HOME", "PATH", "DISPATCH_FAKE_SCENARIO_FILE"], "set": {"OPENCODE_PERMISSION": "{\"question\":\"deny\"}"}},
  "gates": {"symlink": [], "commands": ["true", "echo 'Test Files  1 passed (1)'; echo 'Tests  2 passed (2)'", "false"]},
  "notify": "none"
}
JSON
  git add -A && git commit -q -m "initial"
}

go() { # rung scenario [extra run.sh args]
  local rung="$1" scen="$2"; shift 2
  echo "$scen" > "$DISPATCH_FAKE_SCENARIO_FILE"
  RUNOUT="$("$S/run.sh" "$PROMPT1" "$rung" "$@" 2>&1)"; RUNRC=$?
}
wait_done() { # status.sh .alive -> false, 0.2 s poll, 30 s cap
  local i
  for i in $(seq 1 150); do
    [ "$("$S/status.sh" | jq -r .alive)" = false ] && return 0
    sleep 0.2
  done
  fail "wait_done (still alive after 30 s)"; return 1
}
settle() {
  wait_done
  ST="$("$S/status.sh")"; RUND="$(j "$ST" .runDir)"
  CL="$("$S/classify.sh" "$RUND")"
  ARGV="$(cat "$RUND/fake-argv.txt" 2>/dev/null)"
  ARGVL="$(tr '\n' ' ' < "$RUND/fake-argv.txt" 2>/dev/null)"
  FENV="$(cat "$RUND/fake-env.txt" 2>/dev/null)"
}
epoch() { perl -MTime::Local -e '@a=$ARGV[0]=~/(\d+)/g; print timegm($a[5],$a[4],$a[3],$a[2],$a[1]-1,$a[0])' "$1"; }
near() { # name iso expected-seconds-from-now tolerance
  local e now; e="$(epoch "$2")"; now="$(date +%s)"
  local d=$(( e - now - $3 )); [ $d -lt 0 ] && d=$(( -d ))
  if [ "$d" -le "$4" ]; then pass "$1"; else fail "$1" "retryAt $2 is $((e-now))s ahead, wanted ~$3"; fi
}

# ---- a: dirty preflight ----------------------------------------------------
mkrepo
echo "local change" >> README.md
go 0 passed
eq "a: dirty tree exits 3" "$RUNRC" 3
has "a: dirty tree prints the path" "$RUNOUT" "README.md"
go 0 passed --allow-dirty
eq "a: --allow-dirty starts (exit 0)" "$RUNRC" 0
settle

# ---- b: opencode passed ----------------------------------------------------
mkrepo
go 0 passed
eq "b: run.sh exits 0" "$RUNRC" 0
eq "b: gone model skipped, big-pickle chosen" "$(j "$RUNOUT" .model)" opencode/big-pickle
settle
eq "b: alive false" "$(j "$ST" .alive)" false
eq "b: exitCode 0" "$(j "$ST" .exitCode)" 0
eq "b: headMoved true" "$(j "$ST" .headMoved)" true
eq "b: one commit" "$(j "$ST" '.commits|length')" 1
eq "b: commit subject" "$(j "$ST" '.commits[0].subject')" "FAKE-01: done"
eq "b: promptPresent false" "$(j "$ST" .promptPresent)" false
eq "b: verdict PASSED" "$(j "$ST" .verdict)" PASSED
has "b: reason has FAKE-01" "$(j "$ST" .reason)" FAKE-01
eq "b: session ses_fake1" "$(j "$ST" .session)" ses_fake1
eq "b: pushed false" "$(j "$ST" .pushed)" false
eq "b: branchChanged false" "$(j "$ST" .branchChanged)" false
for w in run --format json --pure --auto --dir -m opencode/big-pickle; do
  if printf '%s\n' "$ARGV" | grep -qxF -- "$w"; then pass "b: argv has $w"; else fail "b: argv has $w"; fi
done
has "b: argv has the pointer sentence" "$ARGV" "Read the file $RUND/prompt.md and carry out the task"
if printf '%s\n' "$ARGV" | grep -qxF -- "-s"; then fail "b: argv must not have -s"; else pass "b: argv has no -s"; fi
has "b: env has OPENCODE_PERMISSION=" "$FENV" "OPENCODE_PERMISSION="
has "b: env has DISPATCH_RUN_DIR=" "$FENV" "DISPATCH_RUN_DIR="
hasnt "b: env does not leak SECRET_API_KEY" "$FENV" "SECRET_API_KEY="
eq "b: classify kind none" "$(j "$CL" .kind)" none
B_RUND="$RUND"

# ---- o: composed prompt ----------------------------------------------------
P="$(cat "$B_RUND/prompt.md")"
has "o: prompt.md has prompt text" "$P" "PROMPT-TEXT-ONE"
has "o: prompt.md has the rules path substituted" "$P" 'Read `.planning/queue/00-OVERVIEW.md` first'
has "o: prompt.md has the prompt path" "$P" "\`$PROMPT1\` in the repository"
hasnt "o: no unsubstituted placeholders" "$P" "{{"
mkrepo
echo "NOTE-MARKER-xyz recover from the earlier crash" > "$TMP/note.txt"
go 0 passed --note "$TMP/note.txt"
settle
has "o: --note content appended" "$(cat "$RUND/prompt.md")" "NOTE-MARKER-xyz recover from the earlier crash"

# ---- c: session flags ------------------------------------------------------
mkrepo; go 0 passed --session ses_fake1; settle
has "c: opencode -s ses_fake1" "$ARGVL" "-s ses_fake1 "
mkrepo; go 1 passed --session conv_fake1; settle
has "c: agy --conversation" "$ARGVL" "--conversation conv_fake1 "
mkrepo; go 2 passed --session sess_fake1; settle
has "c: claude --resume" "$ARGVL" "--resume sess_fake1"

# ---- d: agy passed ---------------------------------------------------------
mkrepo; go 1 passed; eq "d: agy run.sh exits 0" "$RUNRC" 0; settle
for w in -p --dangerously-skip-permissions; do
  if printf '%s\n' "$ARGV" | grep -qxF -- "$w"; then pass "d: argv has $w"; else fail "d: argv has $w"; fi
done
has "d: --output-format json" "$ARGVL" "--output-format json "
has "d: --model m-agy" "$ARGVL" "--model m-agy "
has "d: --print-timeout 45s" "$ARGVL" "--print-timeout 45s"
eq "d: verdict PASSED" "$(j "$ST" .verdict)" PASSED
eq "d: session conv_fake1" "$(j "$ST" .session)" conv_fake1
eq "d: deniedActions 0" "$(j "$ST" .deniedActions)" 0
eq "d: headMoved true" "$(j "$ST" .headMoved)" true

# ---- e: claude passed ------------------------------------------------------
mkrepo; go 2 passed; eq "e: claude run.sh exits 0" "$RUNRC" 0; settle
for w in -p --verbose; do
  if printf '%s\n' "$ARGV" | grep -qxF -- "$w"; then pass "e: argv has $w"; else fail "e: argv has $w"; fi
done
has "e: --output-format stream-json" "$ARGVL" "--output-format stream-json "
has "e: --permission-mode bypassPermissions" "$ARGVL" "--permission-mode bypassPermissions"
hasnt "e: no --model" "$ARGV" "--model"
eq "e: verdict PASSED" "$(j "$ST" .verdict)" PASSED
eq "e: session sess_fake1" "$(j "$ST" .session)" sess_fake1

# ---- f, g: blocked, fail ---------------------------------------------------
mkrepo; go 0 blocked; settle
eq "f: verdict BLOCKED" "$(j "$ST" .verdict)" BLOCKED
eq "f: reason is the question" "$(j "$ST" .reason)" "which port should the server use?"
eq "f: headMoved false" "$(j "$ST" .headMoved)" false
mkrepo; go 0 fail; settle
eq "g: verdict FAIL" "$(j "$ST" .verdict)" FAIL
eq "g: reason" "$(j "$ST" .reason)" "tsc failed"

# ---- h: credits ------------------------------------------------------------
mkrepo; go 0 credits401; settle
eq "h: opencode credits (not auth)" "$(j "$CL" .kind)" credits
eq "h: opencode credits terminal" "$(j "$CL" .terminal)" true
mkrepo; go 1 credits401; settle
eq "h: agy credits" "$(j "$CL" .kind)" credits
eq "h: agy credits terminal" "$(j "$CL" .terminal)" true
RA="$(j "$CL" .retryAt)"
if printf '%s' "$RA" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$'; then pass "h: agy retryAt is ISO"; near "h: agy retryAt ~ now+3723s" "$RA" 3723 60; else fail "h: agy retryAt is ISO" "got [$RA]"; fi
mkrepo; go 2 credits401; settle
eq "h: claude credits" "$(j "$CL" .kind)" credits

# ---- i: auth, rate limit ---------------------------------------------------
mkrepo; go 0 auth; settle
eq "i: auth kind" "$(j "$CL" .kind)" auth
eq "i: auth exitCode 1" "$(j "$CL" .exitCode)" 1
mkrepo; go 0 ratelimit; settle
eq "i: rate-limit kind" "$(j "$CL" .kind)" rate-limit
eq "i: rate-limit not terminal" "$(j "$CL" .terminal)" false
RA="$(j "$CL" .retryAt)"
if printf '%s' "$RA" | grep -qE '^[0-9]{4}-'; then near "i: rate-limit retryAt ~ now+20s" "$RA" 20 30; else fail "i: rate-limit retryAt" "got [$RA]"; fi

# ---- j: noresult -----------------------------------------------------------
# classify.sh returns none for exit 0 with an empty error surface; "no RESULT + HEAD unchanged =
# crash" is the coordinator's rule (SKILL.md), so here we only pin the two inputs it decides on.
mkrepo; go 0 noresult; settle
eq "j: noresult verdict null" "$(j "$ST" .verdict)" null
eq "j: noresult headMoved false" "$(j "$ST" .headMoved)" false
eq "j: noresult classify none" "$(j "$CL" .kind)" none

# ---- k: dirty --------------------------------------------------------------
mkrepo; go 0 dirty; settle
has "k: dirtyNow has README.md" "$(j "$ST" .dirtyNow)" README.md
eq "k: headMoved false" "$(j "$ST" .headMoved)" false
eq "k: verdict FAIL" "$(j "$ST" .verdict)" FAIL

# ---- l, m: hang, stop, second run ------------------------------------------
mkrepo; go 0 hang
eq "l: hang run starts" "$RUNRC" 0
sleep 0.5
eq "l: hang alive true" "$("$S/status.sh" | jq -r .alive)" true
go 0 passed
eq "m: second run.sh while alive exits 4" "$RUNRC" 4
"$S/stop.sh" >/dev/null 2>&1
dead=no
for i in $(seq 1 50); do [ "$("$S/status.sh" | jq -r .alive)" = false ] && { dead=yes; break; }; sleep 0.2; done
eq "l: alive false within 10 s of stop.sh" "$dead" yes
ST="$("$S/status.sh")"
if [ -f "$(j "$ST" .runDir)/stopped.txt" ]; then pass "l: stopped.txt exists"; else fail "l: stopped.txt exists"; fi

# ---- n: gates --------------------------------------------------------------
mkrepo
HEADSHA="$(git rev-parse HEAD)"
GOUT="$("$S/gates.sh" "$HEADSHA" 2>&1)"; GRC=$?
eq "n: gates.sh exit 0" "$GRC" 0
eq "n: ok false" "$(j "$GOUT" .ok)" false
eq "n: three gates" "$(j "$GOUT" '.gates|length')" 3
eq "n: exit codes 0,0,1" "$(j "$GOUT" '[.gates[].exit]|join(",")')" "0,0,1"
has "n: gate 2 summary has Test Files" "$(j "$GOUT" '.gates[1].summary')" "Test Files"
eq "n: worktree removed (one entry)" "$(git worktree list | wc -l | tr -d ' ')" 1

# ---- p: model-level rejection ----------------------------------------------
for r in 0 1 2; do
  mkrepo; go $r model400; settle
  case $r in 0) n=opencode;; 1) n=agy;; 2) n=claude;; esac
  eq "p: $n model kind" "$(j "$CL" .kind)" model
  eq "p: $n model terminal" "$(j "$CL" .terminal)" true
  eq "p: $n verdict null" "$(j "$ST" .verdict)" null
  eq "p: $n headMoved false" "$(j "$ST" .headMoved)" false
done

# ---- q: --model override ---------------------------------------------------
mkrepo; go 0 passed --model opencode/space-bunny-free
eq "q: override exits 0" "$RUNRC" 0
eq "q: run.sh JSON reports override model" "$(j "$RUNOUT" .model)" opencode/space-bunny-free
settle
has "q: argv has -m override" "$ARGVL" "-m opencode/space-bunny-free "
mkrepo; go 0 passed --model opencode/not-listed
eq "q: unlisted override exits 0" "$RUNRC" 0
eq "q: unlisted override reported" "$(j "$RUNOUT" .model)" opencode/not-listed
settle
has "q: argv has -m unlisted override" "$ARGVL" "-m opencode/not-listed "

# ---- r: no listed opencode model -------------------------------------------
mkrepo
jq '.ladder[0].models=["opencode/gone-a","opencode/gone-b"]' .claude/dispatch.json > "$TMP/cfg.json" \
  && mv "$TMP/cfg.json" .claude/dispatch.json
git commit -q -am "gone models"
go 0 passed
eq "r: no listed model exits 5" "$RUNRC" 5
has "r: message names opencode models" "$RUNOUT" "opencode models"

echo
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" = 0 ]
