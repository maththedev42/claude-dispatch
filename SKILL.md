---
name: dispatch
description: Run a queue of numbered prompt files through external coding CLIs (OpenCode, Antigravity, claude -p) on a cost ladder, detached from the session, and verify every landed commit with gates, a diff review and spot checks before moving on. Use when the user says "dispatch the prompts", "run the queue", "/dispatch", "resume dispatch", or asks what the dispatch run is doing. Never commits code itself; prompts stay the unit of work.
argument-hint: "[start | resume | status | stop | <prompt-file>]"
---

# Dispatch

You are the coordinator. The executor is an external CLI started by `scripts/run.sh`
in its own process session, so it survives this conversation. Your job is to pick the
rung, start it, wait, read the result, verify what landed, write follow-up prompts,
and report. You never edit application code and never commit the executor's work.

Scripts live in `${CLAUDE_SKILL_DIR}/scripts/` and read the repo config
`.claude/dispatch.json` (falls back to `~/.dispatch/config.json`; see
`config.example.json`). State lives in `~/.dispatch/<repo-slug>/`. All scripts print JSON.

## Invariants (read before every run)

1. **The verdict is the `RESULT:` line plus a landed commit.** Never the exit code. The
   last `RESULT: PASSED|FAIL|BLOCKED — reason` line in the output wins. No line means
   "not trusted": verify anyway if HEAD moved, treat as a crash if it did not.
2. **Questions are never answered mid-run and never inferred from prose.** `BLOCKED`
   is a question. Answer it only when the prompt, the rules file or the repository
   already contain the answer; cite where. Otherwise notify the user and stop the
   queue. A question is not a capacity failure: same rung on the re-run.
3. **Capacity failures climb the ladder; everything else retries once.** Credits and
   auth park the rung and escalate the same prompt. Rate limit waits `retryAt` or
   15 minutes once, then escalates. Crash, timeout or no `RESULT` line retry once on the
   same rung with a recovery note, then escalate.
4. **The coordinator never commits executor work.** A dirty tree after a run gets one
   "finish and commit by path" re-run on the same session. Still dirty: stop, report the
   paths.
5. **Rules broken by the executor stop the queue.** A push, a branch switch, an amend,
   or edits to files that were already dirty before the run are blockers, reported, not
   repaired.
6. **Gates never run while an executor is alive.** Gates run sequentially in a detached
   worktree (`gates.sh`), one heavy command at a time.
7. **Three rounds on one prompt pause for the user.** Offer: raise the cap, skip, cancel.
8. **Nothing secret leaves the allowlist.** The executor gets only `env.pass` names and
   `env.set` values. Logs stay under `~/.dispatch`, never in the repo, and are never
   parsed for keys.
9. **No invented values.** Model ids and flags come from the config, the CLI's `--help`
   or `<cli> models`. If a configured free model is gone, skip it and say so.

## Procedure

### start [prompt-file]
1. `status.sh`. If a run is alive, say so and switch to **watch**.
2. Build the queue: the overview table order if `order` is `overview-table` (read the
   markdown table in `overview`, file column), else the sorted file names in `promptDir`.
   Skip the overview file itself. With an argument, the queue is that one file.
3. For the first prompt: rung = the lowest rung not parked in `~/.dispatch/<slug>/parked.json`
   (parks carry `until`; expired parks are cleared). Round = 1 unless `history.jsonl`
   shows earlier runs of the same `promptSha`.
4. `run.sh <prompt> <rung>`. Exit 3 means tracked-dirty: show the paths and stop,
   unless the dirty paths are exactly the ones the last run of this prompt left (resume
   mode: write a short resume note to a temp file, re-run with `--allow-dirty --note`).
   Exit 5 means no usable model on this rung: next rung.
5. **Watch.** Run in the background, with no time limit, a loop that polls
   `status.sh` every 60 s and exits when `.alive` is false:

   ```bash
   while [ "$(bash "${CLAUDE_SKILL_DIR}/scripts/status.sh" | jq -r .alive)" = true ]; do sleep 60; done
   ```

   The harness reports when it ends. As a fallback, if `/loop` is available, arm a
   self-paced wakeup of 20 minutes that re-checks `status.sh`.

### on exit
Read `status.sh` and `classify.sh <runDir>` and take exactly one branch:

| Situation | Action |
|---|---|
| `verdict` BLOCKED | Invariant 2. If answerable: write the answer under a `# Answer` heading in a note file, `run.sh --session <session> --note <file>` on the same rung. Else notify and stop. A question about files "another agent" edited mid-run is answered from the machine, not from the prompt: `ps` for executors, `lsof -d cwd` for processes in the repo, the files' mtimes, and the run's own `tool_use` events (did it write them itself?). No live writer → the files are prior work on the same task, keep and finish. A live writer → stop and notify |
| `kind` credits or auth | Park the rung (`parked.json`: `{rung, kind, until}`; credits until `retryAt` or "user clears"), escalate the same prompt |
| `kind` rate-limit | First time: wait `retryAt` or 15 min (a sleep in the background, no time limit), re-run same rung. Second time: escalate |
| `kind` model (a 400 or "context length" rejection from the model itself) | Next model on the same rung (`run.sh --model`), fresh session, with a recovery note. No models left on the rung: escalate |
| `kind` timeout, or not-installed, or unknown with HEAD unchanged | First time: re-run same rung with a recovery note ("RECOVERY MODE: a previous attempt stopped; inspect `git status` and `git diff`, continue from the work on disk"). Second time: escalate |
| `pushed`, `branchChanged`, or the diff touches a path in `dirty-before.txt` | Blocker. Report, stop the queue |
| `headMoved` false and `dirtyNow` non-empty | One finish re-run on the same session: note "Commit only the files you changed, by path, with a real message; delete the prompt file; end with RESULT". Still dirty afterwards: stop, report paths |
| `headMoved` true, verdict PASSED or absent | **Verify** below. An absent verdict is noted in the report |
| `headMoved` true, verdict FAIL | Verify what landed, then a follow-up prompt with the FAIL reason, round + 1 |
| `headMoved` false, verdict FAIL | Follow-up prompt with the reason, round + 1 |
| Every rung parked | Notify with the earliest `until`; if under an hour, sleep and retry; else stop |

### verify (HEAD moved)
1. Read the commits in `status.sh .commits` and their bodies. Claims in a body are
   checked, never trusted.
2. Gates: spawn a subagent (`general-purpose`, the `review.model` from config) with the
   exact command `bash "${CLAUDE_SKILL_DIR}/scripts/gates.sh" <head>` and the machine
   rules; ask for the summary JSON and every failed command's log tail, quoted.
3. Review: spawn a subagent with the prompt text as it was when dispatched
   (`git show <planning-commit>:<prompt>` or the copy in `<runDir>/prompt.md`), the
   diff `git show <sha>`, and the `review.checklist` from config. Ask for numbered
   findings tagged blocker / major / minor / ok with file:line and quotes, "items not
   done", "out-of-scope files touched".
4. Your own spot checks: open the source for every blocker and major and confirm or
   drop it. Fetch the vendor page or re-run `<cli> --help` for any external value in
   dispute.
5. Close: clean, or minors only → delete the prompt file if present, commit the
   planning files by path, next prompt. Minors → one follow-up prompt file appended
   to the queue end. Blocker or major → a follow-up prompt file placed next, same
   number plus a letter; round + 1 for that prompt. Gate failure → follow-up prompt,
   never a hand repair.

### report (after every prompt)
Outcome first. One table: prompt, commit, verdict, gates. Findings grouped
blocker / major / minor with file:line and the follow-up they went into. External
facts checked and where. What was skipped and why. Then `notify.sh "<prompt> <verdict>" "<one line>"`.

At queue end: a table of prompts × commits × verdicts, what remains the user's
(merges, decisions, parked rungs and their reset times).

### resume
`status.sh`. Alive → watch. Exited and not yet closed (no `closed.txt` in the run dir)
→ **on exit**. Closed → **start** with the next prompt. Write `closed.txt` into the run
dir when a prompt is closed so a resume never double-counts it.

### status / stop
`status.sh` printed in one short table. `stop.sh` kills the executor's process group;
then **on exit** with "stopped by user" (no retry).

## Writing follow-up prompts
Same shape as the originals: app name in the file name and H1, "Confirmed at HEAD"
with file:line evidence, "Fixes", "Tests" that fake the collaborator not the subject,
"Gates" to quote. Name the unknown and forbid values that are not read from a source.
