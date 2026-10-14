#!/usr/bin/env bash
# Shared by the fake executables. Sourced, never executed. The calling fake defines
# cli_ok <text>, cli_credits and cli_error_surface helpers, then calls fake_main "$@".

fake_main() {
  : "${DISPATCH_RUN_DIR:?fake executor: DISPATCH_RUN_DIR not set}"
  : "${DISPATCH_FAKE_SCENARIO_FILE:?fake executor: DISPATCH_FAKE_SCENARIO_FILE not set}"
  printf '%s\n' "$@" > "$DISPATCH_RUN_DIR/fake-argv.txt"
  env | sort > "$DISPATCH_RUN_DIR/fake-env.txt"
  local scenario; scenario="$(cat "$DISPATCH_FAKE_SCENARIO_FILE")"

  # Locate the composed prompt (pointer sentence) and the task file named inside it.
  local pointer composed task=""
  pointer="$(printf '%s\n' "$@" | grep '^Read the file ' | head -1 || true)"
  composed="${pointer#Read the file }"; composed="${composed%% and carry*}"
  if [ -f "$composed" ]; then
    task="$(sed -n 's/.*carrying out is `\([^`]*\)`.*/\1/p' "$composed" | head -1)"
  fi

  case "$scenario" in
    passed)
      touch done.txt
      [ -n "$task" ] && [ -f "$task" ] && git rm -q -f -- "$task"
      git add done.txt
      git commit -q -m "FAKE-01: done"
      cli_ok $'Work finished.\nRESULT: PASSED — committed FAKE-01'
      exit 0 ;;
    passed_push)
      touch done.txt
      [ -n "$task" ] && [ -f "$task" ] && git rm -q -f -- "$task"
      git add done.txt
      git commit -q -m "FAKE-01: done"
      git push -q origin HEAD >/dev/null 2>&1
      cli_ok $'Work finished and pushed.\nRESULT: PASSED — committed FAKE-01'
      exit 0 ;;
    blocked)
      cli_ok $'I need a decision.\nRESULT: BLOCKED — which port should the server use?'
      exit 0 ;;
    fail)
      cli_ok $'Gate failed.\nRESULT: FAIL — tsc failed'
      exit 0 ;;
    noresult)
      cli_ok 'I looked around and wrote a lot of prose without a verdict line.'
      exit 0 ;;
    dirty)
      echo "uncommitted edit" >> README.md
      cli_ok $'Edited but could not commit.\nRESULT: FAIL — could not commit'
      exit 0 ;;
    credits401)
      cli_credits ;;
    model400)
      cli_model400 ;;
    auth)
      echo "Error: not signed in, run login" >&2; exit 1 ;;
    ratelimit)
      echo "429 Too Many Requests, try again in 20 seconds" >&2; exit 1 ;;
    hang)
      sleep 600; exit 0 ;;
    *)
      echo "fake executor: unknown scenario '$scenario'" >&2; exit 99 ;;
  esac
}
