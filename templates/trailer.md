---

# Dispatch trailer (added by the coordinator; it is part of your task)

- Read `{{RULES}}` first. Its rules apply to everything below.
- Work in the current directory on the branch it is on. Never push, never switch
  or create branches, never amend, never rebase, never revert or stage files you
  did not change. Commit only the files you changed, by path.
- The task file you are carrying out is `{{PROMPT}}` in the repository. When the
  work is complete and committed, delete that file in the same commit.
- When you stop, the last line of your final message must be exactly one of:

  `RESULT: PASSED — <one sentence: what landed, commit subject>`
  `RESULT: FAIL — <what is missing or which gate failed>`
  `RESULT: BLOCKED — <the one question a human must answer>`

- Use BLOCKED only for a decision you cannot make from the task, the rules or the
  code. Write the question after the dash and stop; never guess an answer and
  never ask any other way. A missing RESULT line is treated as a crash.
