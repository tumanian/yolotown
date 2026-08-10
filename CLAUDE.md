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
- Tests mock only external binaries whose real invocation is unsafe or
  costly in a test run — never local git/filesystem operations, which stay
  real. Today that's the agent, via `CLAUDE_BIN` pointing at
  `tests/fake-claude` (real calls cost tokens and are nondeterministic), and
  `gh`, via `GH_BIN` pointing at `tests/fake-gh` (real calls create actual
  GitHub repos). Everything else — git, worktrees, pushes, exit codes — is
  real. Don't add a new mock seam for a binary whose test invocations are
  already safe and free.
- The tool writes only to worktrees, `.yolotown/`, and remote feature
  branches. Never auto-merge to the base branch. Never leave the base branch
  red or modified.
- Fail fast and loud on bad input; never guess. Error messages name the
  offending thing and show a valid example or the exact cleanup command.
