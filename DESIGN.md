# YOLOTOWN Stage 0 seed — approved design

Consolidated from four individually approved design pieces (2026-07-16).
The full project context lives in the YOLOTOWN spec document; this file
covers only the Stage 0 seed. Deviations from this design, if any arise
during implementation, are listed in the DEVIATIONS section at the bottom.

## Piece 1 — Repo layout

```
yolotown/
├── seed.sh                   # Stage-0 orchestrator (future run-one semantics)
├── test.sh                   # runner: executes tests/*.test.sh, nonzero on any failure
├── tests/
│   ├── helpers.sh            # fixture repo + bare origin builders, asserts, cleanup trap
│   ├── fake-claude           # agent shim, behavior via FAKE_CLAUDE_MODE
│   ├── green-path.test.sh
│   ├── red-path.test.sh
│   ├── env-files.test.sh
│   ├── crash.test.sh         # also hosts the noop case (agent-misbehavior cluster)
│   ├── fail-fast.test.sh
│   └── live-smoke.test.sh    # real claude CLI, skipped unless RUN_LIVE=1
├── CLAUDE.md                 # invariants for self-building agents
├── .yolotown.conf            # yolotown targeting itself; PUSH_ON_GREEN=false until a remote exists
├── README.md
├── DESIGN.md                 # this file
└── .gitignore                # .yolotown/
```

- No `lib/` yet: Stage 1 task 1 (config-loader) is the extraction of `lib/config.sh`.
- Worktrees live outside the repo at `../yt-<name>`.
- Test files named by scenario; runner is serial (real git in temp dirs, no harness flakiness).

## Piece 2 — seed.sh flow, worker prompt, CLI flags

Invocation, from the target repo root: `seed.sh <task-name> "<description>"`,
name matching `[a-z0-9-]+`. Bad arity/name/empty description → usage, exit 2.

Flow (each step fails fast before the next):

1. **Config.** `./.yolotown.conf` must exist; source it; `TEST_CMD` required
   (missing → error naming the key + a valid example, exit 2). Defaults:
   `ENV_FILES=""`, `INVARIANTS_FILE=CLAUDE.md` if present else none,
   `BASE_BRANCH=main`, `BRANCH_PREFIX=feature/`, `PUSH_ON_GREEN=true`,
   `WORKER_MODEL=""` (CLI default), `CLAUDE_BIN=claude`. Unused keys tolerated.
2. **Preflight.** Inside a git repo, run from its root; `BASE_BRANCH` exists;
   HEAD is checked out **on** `BASE_BRANCH` (approved clarification: the base
   gate must gate the base code); working tree clean; branch
   `<BRANCH_PREFIX><name>` and path `../yt-<name>` must not exist (collision
   errors include cleanup commands).

   **`BASE_BRANCH` missing (added after initial approval, 2026-07-17):** if
   the repo has zero commits at all, refuse outright — there is nothing to
   point a branch at; make an initial commit and re-run. Otherwise, prompt
   `y/N` to create `BASE_BRANCH` at current HEAD. An empty or non-`y` reply
   (including EOF from a non-interactive/redirected stdin) defaults to abort,
   same as an explicit decline — the seed never guesses. No `-t 0` tty check:
   piping input is exactly how tests simulate the confirmation, so `read`
   always runs; the fail-safe is EOF-defaults-to-no, not detecting a
   terminal.
3. **Base gate.** Run `TEST_CMD` at the repo root; red → refuse to start.
4. **Log.** `.yolotown/logs/<name>-<UTC-ts>.log`; everything below is tee'd there.
   (Run-dir structure + status state machine is deliberately Stage 1 scope.)
5. **Worktree.** `git worktree add ../yt-<name> -b <BRANCH_PREFIX><name>
   <BASE_BRANCH>`; copy `ENV_FILES` in; verify each with `git check-ignore`.
6. **Agent.** cd into worktree, invoke worker (below), full output logged.
   Nonzero exit → FAILED (crash), worktree intact.
7. **Gate.** `TEST_CMD` in the worktree. Green → `git add -A`, commit, push
   `-u origin` if `PUSH_ON_GREEN`. Red → no commit, worktree intact.
   **Approved addendum:** if the worktree has no changes after the agent ran,
   the task is FAILED ("agent made no changes") — never an empty commit.
8. **Report.** PASSED → branch, log, ready-to-run merge command, exit 0.
   FAILED → reason, log path, worktree path, cleanup commands, exit 1.
   Never auto-merge; never touch the base branch.

Commit format: subject `feat(<name>): <first 60 chars of description>`, body
carries the full description plus yolotown-seed authorship.

Worker prompt (exact, `<...>` substituted):

```
You are completing one software task inside an isolated git worktree.
The current directory is the worktree; it is yours alone.

TASK: <name>
DESCRIPTION: <description>

ACCEPTANCE GATE: the command `<TEST_CMD>` must exit 0. Run it yourself
before finishing. You are done only when it passes.

RULES:
- Never weaken, delete, or edit an existing test to make it pass. A red
  gate means the work is wrong, not the test.
- Do not run any git commands that commit, push, branch, or merge; the
  orchestrator owns git. Read-only git (status, diff, log) is fine.
- Work only inside the current directory.
- If the description references spec files in the repo, read them first.

REPOSITORY INVARIANTS (obey these):
<contents of INVARIANTS_FILE, or the line "None provided.">
```

CLI invocation (exact):

```bash
"$CLAUDE_BIN" -p "$PROMPT" \
  ${WORKER_MODEL:+--model "$WORKER_MODEL"} \
  --allowedTools "Edit" "Write" "Read" "Glob" "Grep" "Bash"
```

Approved decisions: `Bash` allowed unscoped (per-command scoping is
impractical for open-ended tasks; isolation = worktree + prompt's git
prohibition; documented in README; `--dangerously-skip-permissions` is NOT
used). No agent timeout in the seed (known limitation; Stage 1+ candidate).

## Piece 3 — Test architecture

Mock exactly one thing: the agent, via `CLAUDE_BIN` → `tests/fake-claude`.

- **Runner** `test.sh`: plain bash, runs each `tests/*.test.sh` in its own
  process, per-file PASS/FAIL + summary, nonzero exit on any failure.
  `RUN_LIVE=1` un-skips the smoke test; `KEEP_TMP=1` preserves temp dirs.
- **Fixture** (`helpers.sh`): temp git repo with committed `src/app.js`,
  gate `check.sh` = `node --check src/app.js && node src/app.js` (green/red is
  real: determined entirely by what the agent edited), committed `CLAUDE.md`
  (so invariant injection is assertable), `.gitignore` covering `.env` and
  `.yolotown/`, git-ignored `.env` with known content, `.yolotown.conf`
  pointing `CLAUDE_BIN` at the shim. Bare origin in a second temp dir wired
  as `origin`; pushes are real pushes over the filesystem.
- **Shim**: records full argv to `$FAKE_CLAUDE_ARGV_FILE` (prompt/flag
  assertions). Modes: `good` (adds valid `src/feature.js`, exit 0), `bad`
  (breaks `src/app.js`, exit 0), `noop` (no changes, exit 0), `crash`
  (stderr noise, exit 1).
- **Core assertions** per file: green path (exactly one commit, right
  subject/body, pushed tip matches origin, log captured, exit 0; plus a
  `PUSH_ON_GREEN=false` + `WORKER_MODEL` case), red path (no commit, origin
  untouched, worktree intact, log shows the failure, exit 1), env files
  (present in worktree, absent from `git ls-files` and the pushed tree),
  crash + noop (FAILED with right reason, orchestrator completes its report),
  fail-fast (one subcase per refusal, each asserting exit code + message),
  live smoke (real CLI, trivial task, only test that costs tokens).

## Piece 4 — Worktree lifecycle and failure modes

Phases: (1) pre-creation — all preflight before `git worktree add`, failure
creates nothing; (2) created-but-agent-not-run — the ONLY window where the
seed auto-removes its own just-created worktree+branch (env-file failures);
(3) agent-has-run — the seed never removes the worktree or branch, on any
outcome; (4) terminal — every report ends with the exact cleanup block:

```
git worktree remove --force ../yt-<name>
git branch -D <BRANCH_PREFIX><name>
git push origin --delete <BRANCH_PREFIX><name>    # only if pushed
```

| failure | when | worktree/branch | exit |
|---|---|---|---|
| bad args / bad config | preflight | never created | 2 |
| dirty base / red base / not on base branch | preflight | never created | 1 |
| branch or worktree path collision | preflight | untouched | 1 |
| env file missing or not git-ignored | pre-agent | auto-removed | 1 |
| agent exits nonzero | agent | intact | 1 |
| agent made no changes | post-agent | intact | 1 |
| gate red | gate | intact, uncommitted | 1 |
| push fails | ship | intact, commit stands (PASSED-LOCALLY) | 1 |
| Ctrl-C / kill | any | left as-is; resumability is out of scope | — |

Out of seed scope, recorded so Stage 1+ picks them up: `git worktree prune`,
resumability, agent timeout, lane checking.

## DEVIATIONS

- **Dirty check ignores untracked files** (`git status --porcelain
  --untracked-files=no`). Reason: untracked files never enter worktrees (they
  branch from committed state), and `.yolotown/` itself would otherwise make
  every second run refuse to start on repos that haven't git-ignored it.
- **`ENV_FILES` existence is validated in preflight**, before the worktree is
  created (piece 4 placed it post-create). Strictly earlier fail, same
  message; the not-git-ignored check remains post-create with auto-removal
  as approved.
