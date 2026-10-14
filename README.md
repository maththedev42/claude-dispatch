# claude-dispatch

A [Claude Code](https://code.claude.com) skill that runs a queue of prompt files through
external coding CLIs on a cost ladder, detached from the session, and verifies every
landed commit before moving on.

You write prompts. Claude dispatches them to the cheapest executor that has capacity
(free OpenCode models, then Antigravity, then `claude -p`, in any order you configure),
waits, reads the result, runs your gates in a throwaway worktree, reviews the diff
against the prompt with a subagent, checks the findings itself, writes follow-up
prompts for what is wrong, and reports. You get a notification when it needs you.

The design comes from a year of running the same loop by hand: pasting prompts into a
terminal, waiting, reading diffs, writing the next prompt. Every rule below exists
because its absence cost a day.

## Install

```bash
git clone https://github.com/maththedev42/claude-dispatch ~/.claude/skills/dispatch
cp ~/.claude/skills/dispatch/config.example.json <your-repo>/.claude/dispatch.json
```

Edit the config: your prompt directory, your gates, your ladder. Then in Claude Code,
inside the repo:

```
/dispatch start
```

Requirements: macOS or Linux, bash, git, jq, perl. At least one executor on PATH:
[`opencode`](https://opencode.ai), [`agy`](https://antigravity.google) or `claude`.

## How a prompt runs

1. **Preflight.** One live run per repo. Tracked-modified files stop the run with their
   paths, so the executor never works on top of someone else's uncommitted changes.
   Resume mode exists for the one case where the modified files belong to an earlier,
   interrupted run of the same prompt.
2. **Compose.** The prompt file plus a trailer: read the rules file, work on the current
   branch, never push or switch, commit by path, delete the prompt file, and end with
   `RESULT: PASSED | FAIL | BLOCKED — reason`.
3. **Start.** `run.sh` starts the CLI in its own process session with stdin closed, an
   environment built only from the configured allowlist, output captured under
   `~/.dispatch/<repo>/runs/<id>/`, and a watchdog that kills the process group after
   the rung's timeout. The script exits at once. The run survives the Claude session.
4. **Watch.** Claude waits in the background and reads `status.sh` when the process
   exits: HEAD before and after, the commits, the tree state, the `RESULT` line, the
   session id, whether anything was pushed.
5. **Verify.** Gates run sequentially in a detached worktree at the landed commit.
   A subagent reviews the diff against the prompt text with the checklist in the
   config. Claude confirms every blocker and major in the source itself.
6. **Close.** Clean work: the prompt file is deleted and the planning commit lands.
   Minors become a follow-up prompt at the end of the queue; blockers become the next
   prompt. Three rounds on one prompt pause for you.

## The ladder

```json
"ladder": [
  { "kind": "opencode", "models": ["opencode/big-pickle", "..."] },
  { "kind": "agy",      "models": ["claude-sonnet-5-5-medium"] },
  { "kind": "claude",   "models": [] }
]
```

A prompt starts on the lowest rung that is not parked. Only capacity failures climb:
out of credits, logged out, or a second rate limit. Crashes and timeouts retry once on
the same rung with a recovery note. Questions never change rung.

OpenCode free models are marked "limited time" by the vendor; `run.sh` keeps only the
ones `opencode models` still lists at start time.

## Executors

Every flag was read from the CLI's own `--help` on the day of writing. Re-check yours.

| Kind | Command |
|---|---|
| opencode | `opencode run --format json --pure --auto --dir <repo> -m <model> [-s <session>] "<pointer>"` |
| agy | `agy -p "<pointer>" --output-format json --dangerously-skip-permissions [--model M] [--conversation ID] --print-timeout <timeout-15>s` |
| claude | `claude -p "<pointer>" --output-format stream-json --verbose --permission-mode bypassPermissions [--model M] [--resume ID]` |

`<pointer>` is one sentence that tells the executor to read the composed prompt file
in the run directory, so prompts of any length work the same way on all three.

Write modes auto-approve every tool call. That is the point of a headless run and the
reason for the rules in the trailer and the checks in `status.sh`: the executor is
trusted to edit and commit, and nothing else.

## What stops the queue

| Event | What happens |
|---|---|
| The executor asks a question (`RESULT: BLOCKED`) | Answered only if the prompt, rules or repo already hold the answer, with the source cited. Otherwise you are notified and the queue stops |
| Out of credits or logged out | The rung is parked, the same prompt climbs |
| Rate limit | One wait, then climb |
| The model itself rejects the request (400, context length) | Next model on the same rung, then climb |
| Crash, timeout, no `RESULT` line | One retry with a recovery note, then climb |
| Commit landed | Gates, review, spot checks, report |
| Tree left dirty | One "finish and commit" re-run on the same session, then stop. The coordinator never commits executor work |
| The executor pushed, switched branch or amended | Blocker, queue stops |
| Gates fail or the review finds a blocker | Follow-up prompt, never a hand repair |
| Three rounds on one prompt | Pause: raise the cap, skip or cancel |
| Every rung parked | Wait for the earliest reset if under an hour, else stop |
| The Claude session dies | The executor keeps running. `/dispatch resume` in a new session continues from the state file |

## Safety model

- The executor runs in your checkout on the current branch, as a person would. It gets
  a minimal environment: only the variable names in `env.pass` are copied from the
  coordinator's environment, plus the literal values in `env.set`. API keys in your
  shell do not reach it unless you list them.
- The coordinator never edits application code and never commits the executor's files.
  A failed gate becomes a prompt.
- Logs live under `~/.dispatch`, outside the repo, and are never scanned for secrets:
  the skill cannot know what your secrets look like, so it does not pretend to.
- The verdict is never the exit code. OpenCode's `run` exits 0 whatever happened, and
  Antigravity returns partial output with exit 0 on a print timeout. The `RESULT` line
  and the landed commit are the only signals, and claims in a commit body are checked
  against the diff by the review.
- Questions are never inferred from the model's prose. A question is the explicit
  `BLOCKED` line, or nothing.

## Config reference

| Key | Meaning |
|---|---|
| `promptDir` | Directory with the numbered prompt files |
| `order` | `overview-table` reads the dispatch table in `overview`; `filename` sorts names |
| `overview`, `reviewRules` | The rules file the trailer tells the executor to read |
| `maxRoundsPerPrompt` | Rounds before the queue pauses for you (default 3) |
| `timeoutMinutes` | Default per-run wall clock; each rung may override |
| `ladder[]` | `{kind, models[], timeoutMinutes}` in order of preference |
| `env.pass` | Names copied from the coordinator's environment |
| `env.set` | Literal variables for the executor, e.g. `OPENCODE_PERMISSION` |
| `gates.commands` | Shell commands run in order from the worktree root |
| `gates.symlink` | Paths symlinked from the checkout into the worktree (`node_modules`) |
| `gates.timeoutMinutes` | Per command |
| `review.model`, `review.checklist` | Subagent model and the review questions |
| `notify` | `osascript` or `none` |

## Scripts

| Script | Does |
|---|---|
| `run.sh <prompt> <rung> [--allow-dirty] [--note f] [--session id] [--model m]` | Preflight, compose, detach, write state |
| `status.sh [--run dir]` | Liveness, exit, HEAD delta, commits, tree, `RESULT`, session, pushed |
| `classify.sh <run-dir>` | Failure kind from the error surface: not-installed, credits, auth, rate-limit, timeout, unknown, none |
| `gates.sh <sha> [--keep]` | Detached worktree, symlinks, sequential gates, summary JSON |
| `stop.sh` | Kill the live run's process group |
| `notify.sh <title> <body>` | Desktop notification |

## Tests

```bash
bash tests/run.sh
```

The tests use fake `opencode`, `agy` and `claude` binaries that record their argv and
environment and replay canned output: success, credits error, rate limit, no `RESULT`
line, `BLOCKED`. No real CLI is called.

## Licence

MIT.
