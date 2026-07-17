# YOLOTOWN invariants

Rules any agent working on this repo must obey. These are injected into the
prompts of self-building agents; violating them fails review even if the
suite is green.

- Bash for orchestration; small node one-liners for all JSON parsing and
  generation. No jq, no frameworks, no new dependencies of any kind. git,
  node, and the claude CLI are the only assumed binaries.
- Flat-file state only: `.yolotown/` run dirs, inspectable with `cat` and
  `ls`. No databases.
- Never weaken, delete, or edit an existing test to make it pass. A red gate
  means the work is wrong, not the test.
- Every feature ships with its tests in the same branch.
- Tests mock exactly one thing: the agent, via `CLAUDE_BIN` pointing at
  `tests/fake-claude`. Everything else — git, worktrees, pushes, exit
  codes — is real.
- The tool writes only to worktrees, `.yolotown/`, and remote feature
  branches. Never auto-merge to the base branch. Never leave the base branch
  red or modified.
- Fail fast and loud on bad input; never guess. Error messages name the
  offending thing and show a valid example or the exact cleanup command.
