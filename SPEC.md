# YOLOTOWN — full context

**This file is the authoritative specification.** It is vendored into the repo
so that any agent working here can read the real source rather than a task
description compressed from it. If a task description in `tasks.txt` and this
file disagree, this file wins — say so rather than silently picking one.

It is self-contained: an agent given only this document has everything decided
so far. Execution starts at Stage 0 and proceeds through the staged backlog.
Nothing here is up for relitigation unless the human says so; open questions
are marked as such.

## 1. What YOLOTOWN is

A repo-agnostic command line tool that orchestrates headless Claude Code agents
against any git repo that has a test suite. A task list gets analyzed for
file-level conflicts. Colliding tasks trigger a gated refactor to make them
disjoint. Tasks fan out to parallel headless agents in isolated git worktrees,
each gated by the target repo's test suite. Green branches get committed and
optionally pushed; whatever CI/CD watches the remote (e.g. Vercel branch
previews) reacts on its own. The tool's contract ends at "green branch exists."

**Philosophy.** Automate everything whose failure is cheap: a leaf task that
fails dies alone at its gate, costing only its own log. Gate the one operation
whose failure is contagious: a refactor that mutates the shared baseline gets
exactly one human approval. The test suite is the acceptance gate; green means
mechanically done. The human is never removed from merging: yolotown never
auto-merges to the base branch.

**Bootstrap strategy.** YOLOTOWN builds YOLOTOWN. A hand-reviewed minimal seed
(Stage 0) is the only part built by an outside tool. Every subsequent feature is
a task dispatched through the tool itself, gated by the tool's own growing test
suite. This is the self-hosting compiler pattern: the seed is the stage-0
compiler, the backlog is the language being implemented in itself.

## 2. Fixed design decisions

- **Standalone repo.** YOLOTOWN lives in its own repository. Target repos
  consume it. Nothing in the tool may assume any specific repo, language, or
  framework.
- **Config, not convention.** All repo specifics live in `.yolotown.conf` at the
  target repo's root: plain shell-sourceable key=value. Keys and defaults:
  - `TEST_CMD` (required, no default): the acceptance gate command, run in each
    worktree; exit code decides everything.
  - `ENV_FILES` (default empty): space-separated git-ignored files copied into
    each worktree. Never committed.
  - `SOURCE_GLOBS` (default: `git ls-files` filtered to source-ish extensions):
    the file inventory conflict detection reads.
  - `INVARIANTS_FILE` (default: `CLAUDE.md` if present): injected into agent
    prompts.
  - `BASE_BRANCH` (default `main`), `BRANCH_PREFIX` (default `feature/`).
  - `MAX_PARALLEL` (default 3).
  - `PUSH_ON_GREEN` (default true): false means commit locally, do not push.
  - `PLANNER_MODEL` (stronger model, for conflict detection and refactor
    planning), `WORKER_MODEL` (cheaper model, for task execution), both
    optional, defaulting to the CLI's default model.
  - `CLAUDE_BIN` (default `claude`): agent binary; also the test seam.
  - Missing or invalid config fails fast, naming the offending key and showing a
    valid example.
- **CLI surface (final form).** `yolotown plan [tasks.txt]` (conflict detection
  only, prints buckets, touches nothing; the dry run), `yolotown run [tasks.txt]`
  (full pipeline), `yolotown run-one <name> "<desc>"` (single task, the
  debugging path), `yolotown status` (per-task table from the latest run),
  `yolotown clean` (prints worktree/branch removal commands; executes only with
  `--force`). A future `yolotown init` (v2, deferred): an orient-yourself step
  where an agent inspects the target repo (package manifests, CI config,
  `.gitignore`) and proposes a `.yolotown.conf` for human approval, same
  propose-then-approve pattern as the refactor gate.
- **State: flat files, no database.** SQLite was considered and rejected for v1
  as over-engineering at this scale. Each run creates
  `.yolotown/run-<UTC timestamp>/` in the target repo: `plan.json` (conflict
  detection output), `logs/<task>.log` (full agent output), `status/<task>`
  (single word: pending, running, passed, failed, skipped; transitions enforced,
  illegal transitions rejected). `.yolotown/latest` symlinks the newest run.
  Everything inspectable with `cat` and `ls`. Status writes are one word per
  file, atomic enough for this concurrency level.
- **Language.** Bash for orchestration; small node one-liners for all JSON
  parsing and generation (node is guaranteed present wherever the claude CLI
  is). No jq, no frameworks, no runtime dependencies.
- **Task input.** `tasks.txt`, one task per line: `<short-name> | <description>`.
  Names match `[a-z0-9-]+`, no duplicates, `#` comments and blank lines allowed,
  descriptions may reference spec files in the target repo.
- **Headless invocation.** `claude -p "<prompt>"` is non-interactive and cannot
  answer permission prompts. Pre-authorize with scoped `--allowedTools`;
  `--dangerously-skip-permissions` only where scoping is impractical, isolated
  and documented.
- **Worktrees.** `git worktree add ../yt-<name> -b <BRANCH_PREFIX><name>
  <BASE_BRANCH>`, then copy `ENV_FILES` in and verify each is git-ignored there.
  Fail fast on name collisions, with the cleanup command in the error.
- **Commit format.** `feat(<name>): <first 60 chars of task>` with a body noting
  yolotown authorship.
- **Lane checking (warn only).** At gate time, diff the files the agent actually
  touched against the plan's prediction. Straying outside the predicted lane
  yields PASSED-WITH-WARNING in the report, never a failure. Promoting this to a
  harder policy is a later decision.

## 3. The full pipeline (what `run` executes at Stage 3 maturity)

1. **Conflict detection (automated).** One headless call on `PLANNER_MODEL`:
   given the task list and the `SOURCE_GLOBS` file inventory, emit
   machine-parseable JSON mapping task -> likely files, plus a collision report
   of overlapping pairs. Three buckets: DISJOINT (fan out now),
   COLLIDING-SPLITTABLE (a shared module could be split to make them disjoint),
   INHERENTLY-COUPLED (same logic; run sequentially, each rebased on the
   previous result).
2. **Refactor stage (gated; the one human checkpoint).** For
   COLLIDING-SPLITTABLE groups, generate a refactor PLAN only: which file
   splits, into what, what moves where, why this makes the colliding tasks
   disjoint. Print it and STOP for stdin approval (approve / reject / edit). On
   approval, execute: behavior-preserving only, full suite after, commit only on
   green, never weaken or edit an existing test to pass. Red suite means revert
   and report. Never fan out on a red baseline.
3. **Fan-out (automated, parallel).** Per dispatchable task: worktree + branch
   from the possibly-refactored base, env files in, agent runs headlessly on
   `WORKER_MODEL` with the task description, the invariants instruction, and the
   finish-green instruction. Full output logged. Concurrency bounded by
   `MAX_PARALLEL` (subshells with `&` and `wait`; a worker crash is recorded as
   failed without killing the run).
4. **Gate + ship (automated, per worker).** Run `TEST_CMD` in the worktree.
   Green: add, commit, push if `PUSH_ON_GREEN`; run the lane check. Red: no
   commit, no push, worktree left intact for autopsy, FAILED with log pointer.
5. **Fan-in / report (automated).** Per-task table: PASSED /
   PASSED-WITH-WARNING / FAILED (log path, worktree path) / SKIPPED (unresolved
   coupling). Leftover worktrees listed with exact cleanup commands.
   Ready-to-run merge commands emitted for each green branch. No auto-merge,
   ever.

## 4. Hard requirements (all stages)

- Never leave the base branch red or modified: the tool writes only to
  worktrees, `.yolotown/`, and remote feature branches; the refactor stage ends
  green-or-reverted before any fan-out.
- Never weaken, delete, or edit an existing test to make a gate pass. A red gate
  means the work is wrong, not the test.
- Env files copied into every worktree, never committed anywhere.
- A failed task must be diagnosable from its log alone, without rerunning.
- Bounded parallelism everywhere; rate limits are real.
- Refuse to start on a dirty base branch or a red base suite, even for a single
  task.
- Fail fast and loud on bad input; never guess.
- Runnable from a plain macOS/Linux shell; git, node, and the claude CLI are the
  only assumed binaries.

## 5. Testing architecture

Mock exactly one thing: the agent. Everything else is real.

- **Fixture target repo**: each test creates a throwaway git repo in a temp dir
  with committed source files, a `.yolotown.conf`, a git-ignored `.env`, and a
  `TEST_CMD` the test fully controls (a committed check script the test can make
  pass or fail). Real commands, real exit codes.
- **Fake origin**: `git init --bare` in a second temp dir, wired as the
  fixture's origin. Pushes are real pushes over the filesystem; `PUSH_ON_GREEN`
  is testable end to end offline.
- **Claude shim**: a fake executable substituted via `CLAUDE_BIN`, behavior
  selected by `FAKE_CLAUDE_MODE`: `good` (makes an edit keeping the gate green,
  prints plausible agent output), `bad` (edit turning the gate red), `noop`
  (changes nothing, exits 0), `crash` (exits nonzero). The real CLI is never
  called in the default suite.
- **Live smoke test**: opt-in via `RUN_LIVE=1`, skipped by default, runs the
  real claude CLI once on a trivial task. The only test that costs tokens;
  exists to catch CLI flag drift the shim cannot.
- **Core assertions**: green path yields exactly one commit on the right branch,
  pushed to the bare origin, log captured; red path yields no commit, worktree
  intact, log pointing at the failure; env file present in the worktree but
  absent from `git ls-files` there; agent crash yields a FAILED task, not a
  crashed orchestrator; collisions and missing config fail fast with the right
  messages.
- Test harness is plain bash asserts or `node --test`; no frameworks; temp dirs
  cleaned up.

> **Note (2026-08-10):** this repo has since added a second mock seam, `GH_BIN`
> -> `tests/fake-gh`, because `gh repo create` makes a real GitHub repo. The
> governing rule in `CLAUDE.md` was broadened to "mock external binaries whose
> real invocation is unsafe or costly." git/worktree/push operations stay real.

## 6. The staged roadmap

**Stage 0 — the seed (built by an outside tool, e.g. Cursor; the only
non-self-hosted part).** Deliverables: `seed.sh` (one task, one agent, one
worktree, gate, commit/push on green, full logging, all fail-fast behaviors),
the test suite per section 5, `CLAUDE.md` for the yolotown repo itself
(invariants future self-building agents obey: bash + node one-liners only, no
new dependencies, flat-file state, never weaken tests, every feature ships with
tests in the same branch), `.yolotown.conf` for yolotown itself
(`TEST_CMD="./test.sh"`), and a README. The seed is small enough to review line
by line. Build process: three phases with human approval gates; the design phase
presents four pieces one at a time for individual confirmation (repo layout;
`seed.sh` flow including the exact worker prompt and CLI flags; test
architecture; worktree lifecycle and failure modes), consolidating into
`DESIGN.md` before implementation.

**Stage 1 — serial self-build (the seed's first meal).** Tasks run ONE at a
time: seed a task, review the green branch, merge, next. Serial means tasks may
touch the same files; each starts from the previous merge, so the disjointness
discipline is not yet required. The human is the conflict detector by writing
the order. Backlog, in dependency order, every task shipping its own tests:

1. `config-loader` — extract config handling into `lib/config.sh` with all
   defaults and fail-fast validation.
2. `tasks-parser` — `lib/tasks.sh` implementing the `tasks.txt` format rules
   with line-numbered errors.
3. `run-dir` — `lib/rundir.sh`: run directories, the status state machine with
   enforced transitions, the `latest` symlink; seed logs move into the run dir.
4. `report` — the fan-in table, cleanup and merge command emission, and the
   `status` subcommand reading `.yolotown/latest`.
5. `cli` — the `yolotown` entrypoint with subcommand dispatch; `run` iterates a
   tasks file serially, continuing past failures; `run-one` preserves
   single-task mode; `clean` with `--force`.
6. `fan-out` — bounded parallel workers via subshells honoring `MAX_PARALLEL`
   (`--parallel N` override, `--serial` fallback), per-worker status files,
   crash containment, then the fan-in report. Tests prove the concurrency bound
   with shim sleeps.

**Stage 2 — parallel, hand-curated.** The fan-out from Stage 1 runs multiple
agents, but the human still writes tasks to be disjoint. The tool now pays for
itself while building itself.

**Stage 3 — full pipeline (dispatched BY yolotown, in parallel).** Backlog
written as its own tasks file: conflict detection on `PLANNER_MODEL` with the
`plan.json` contract, the `plan` subcommand, the gated refactor stage with stdin
approval, lane-violation warnings, sequential execution of the
INHERENTLY-COUPLED bucket. Graduation test: yolotown runs `plan` on its own
remaining backlog and buckets it correctly.

**After Stage 3 — first external targets.** `paper-reader` (a modular ES-module
app, ~13 modules, characterization suite of 116+ assertions via `npm test`,
`CLAUDE.md` invariants, Vercel branch previews, `.env` that must travel to
worktrees) is the first target and the standing integration testbed. The
personal blog prototype is the first production run on a second repo, which is
what proves generality: the blog is hand-built only to a minimal yolotown-ready
skeleton (framework scaffold, first characterization tests, `CLAUDE.md`,
`.yolotown.conf`), then its feature backlog (RSS, tag pages, dark mode, OG
images, reading time), including one deliberately colliding pair to exercise the
refactor gate, is dispatched through yolotown. v2's `init` command lands after
that, once real second-repo friction shows what orientation must detect.

## 7. Open questions (decided later, not now)

- Whether lane violations ever become blocking rather than warn-only.
- Whether resumability of interrupted runs (rerun pending/failed only) is worth
  building before Stage 3, and which interruption states are declared
  non-resumable in v1.
- v2 `init` scope and its orientation prompt.
- Whether SQLite returns as an optional state backend if run history analytics
  (flaky tasks, repeat colliders) prove wanted.

## 8. Working agreements for any agent executing this

- Phased delivery with explicit human approval gates; design pieces presented
  one at a time, never batched; edits that invalidate an approved piece cause
  that piece to be re-presented.
- Deviations from approved designs are flagged in a DEVIATIONS section with
  one-line reasons, never silent.
- When something breaks, trace the root cause through commit history rather than
  layering patches on symptoms.
- Statement over explanation; fail loud; keep it inspectable with `cat`.

## 9. Known deviations in the current implementation

Live list of places the code knowingly differs from this spec. Each is either
scheduled for correction or explicitly accepted.

- **`.yolotown/logs/<name>-<ts>.log` retained** as a symlink into the run dir
  for discoverability. Not in the spec's layout; harmless, revisit when `clean`
  learns to prune old runs.
