<!-- yolotown: a CLI that orchestrates headless Claude Code agents to build features in isolated git worktrees, each gated by the target repo's own test suite. -->
# YOLOTOWN

A repo-agnostic command line tool that orchestrates headless Claude Code
agents against any git repo that has a test suite. Tasks fan out to parallel
agents in isolated git worktrees, each gated by the target repo's own tests.
Green branches get committed and optionally pushed. The tool's contract ends
at "green branch exists" — it never merges to your base branch.

**Current state: Stage 1 (self-build).** `seed.sh` still runs exactly one task
through one agent in one worktree; the `yolotown` entrypoint wraps that core in
a backlog pipeline that fans tasks out to bounded parallel workers. What's left
of the roadmap (conflict detection and the gated refactor stage) is built *by*
the tool, task by task, gated by this repo's own test suite. See
[DESIGN.md](DESIGN.md) for the approved seed design and [SPEC.md](SPEC.md) for
the whole plan.

## Requirements

A plain macOS/Linux shell with `git`, `node`, and the `claude` CLI. Nothing
else — no jq, no frameworks, no package installs. `gh` is optional, used
only by `setup.sh` to create a GitHub remote on request.

## Quickstart

In the target repo's root, create `.yolotown.conf`:

```sh
TEST_CMD="npm test"
```

If `PUSH_ON_GREEN` is enabled (the default) and the repo has no `origin`
remote yet, run `setup.sh` once to add or create one:

```sh
/path/to/yolotown/setup.sh
```

It asks whether you already have a remote to use, and otherwise offers to
create a GitHub repo via `gh` (if installed). Skip this and set
`PUSH_ON_GREEN="false"` if you want to stay local.

Make sure you're on the base branch, clean, with a green suite. Then:

```sh
/path/to/yolotown/seed.sh add-rss "Add an RSS feed at /rss.xml per docs/rss-spec.md"
```

The seed will: verify the base is clean and green → create the worktree
`../yt-add-rss` on branch `feature/add-rss` → run a headless claude agent in
it → run `TEST_CMD` as the gate → on green, commit (and push if configured)
and print the merge command; on red, leave everything in place for autopsy
and point you at the log. Full agent output lands in
`.yolotown/logs/<task>-<timestamp>.log`.

The seed never merges, never deletes your work, and refuses to start on a
dirty or red base.

## Running a backlog

Write the tasks one per line in `tasks.txt` as `<short-name> | <description>`
(`#` comments and blank lines are fine), then:

```sh
/path/to/yolotown/yolotown plan            # conflict detection only; dispatches nothing
/path/to/yolotown/yolotown run             # dispatch the backlog
/path/to/yolotown/yolotown status          # the latest run's table again
/path/to/yolotown/yolotown clean --force   # remove the leftover worktrees
```

`run` checks the base once (clean, on `BASE_BRANCH`, green suite, agent
reachable), then gives each task its own worktree, branch, log and gate. A
failed task dies alone: the run continues, and the fan-in report at the end
lists every task with its log, its worktree, and a ready-to-run merge command
for each green branch.

Tasks run **at most `MAX_PARALLEL` at a time** (default 3, because rate limits
are real). A freed slot is refilled immediately, so N workers stay busy until
the backlog runs out:

```sh
yolotown run --parallel 6 tasks.txt   # override MAX_PARALLEL for this run
yolotown run --serial tasks.txt       # one at a time, agent output streamed live
```

Parallel workers write to `.yolotown/run-<ts>/logs/<task>.log` rather than the
terminal — N agents talking at once is noise — and the terminal gets one line
per dispatch and per completion. `--serial` is the debugging fallback: same
pipeline, one task at a time, output live. Inside a run dir, `status/<task>`
holds the state word and `results/<task>` holds the finished worker's exit code
and reason, so a run is inspectable with `cat` while it is still in flight.

Only the tasks are parallel, never the git plumbing that isn't safe to share:
worktree creation is serialized behind `.yolotown/worktree.lock`, since
concurrent `git worktree add` invocations trip over each other's half-written
metadata.

If `BASE_BRANCH` (default `main`) doesn't exist yet, the seed asks for
confirmation before creating it at the tip of your current `HEAD`. If the
repo has no commits at all, there's nothing to point a branch at — make an
initial commit first.

## Configuration (`.yolotown.conf`)

Plain shell-sourceable `key=value` at the target repo root.

| key | default | meaning |
|---|---|---|
| `TEST_CMD` | *(required)* | the acceptance gate; its exit code decides everything |
| `ENV_FILES` | empty | space-separated git-ignored files copied into each worktree |
| `SOURCE_GLOBS` | source-ish extensions | git pathspecs; the file inventory conflict detection reads |
| `INVARIANTS_FILE` | `CLAUDE.md` if present | injected into agent prompts |
| `BASE_BRANCH` | `main` | branch worktrees are cut from |
| `BRANCH_PREFIX` | `feature/` | prefix for task branches |
| `PUSH_ON_GREEN` | `true` | `false` = commit locally, don't push |
| `MAX_PARALLEL` | `3` | workers `yolotown run` keeps in flight at once |
| `PLANNER_MODEL` | CLI default | model for conflict detection and refactor planning |
| `WORKER_MODEL` | CLI default | model for task execution |
| `CLAUDE_BIN` | `claude` | agent binary; also the test seam |

`SOURCE_GLOBS` is handed straight to `git ls-files`, so its globs match at any
depth (`*.js` finds `src/a.js`) and the default is literally "every tracked
file with a source-ish extension" — see `YT_SOURCE_GLOBS_DEFAULT` in
`lib/config.sh`. A repo whose entrypoints carry no extension names them
explicitly; this one does, in its own `.yolotown.conf`. Setting the key to the
empty string is refused rather than read as "every file".

## Conflict detection (`lib/plan.sh`)

One headless call on `PLANNER_MODEL` turns the backlog plus that inventory into
`<run-dir>/plan.json`: each task mapped to the files it will likely touch and
sorted into exactly one of `DISJOINT`, `COLLIDING-SPLITTABLE` or
`INHERENTLY-COUPLED`, plus the collision report of overlapping groups.

An answer that is unparseable, incomplete, or self-contradictory is a hard
failure that names what was wrong and writes no `plan.json`. There is no
fallback to "everything is disjoint" — that would be the most dangerous failure
this tool could have, because it green-lights a fan-out of tasks that overwrite
each other. The plan is even cross-examined against itself: two tasks predicting
the same file with no collision reporting them together is rejected.

`yolotown plan` is that detection on its own — the dry run you do before
committing to a fan-out:

```
$ yolotown plan backlog.txt
plan: backlog.txt — 3 tasks (dry run: no worktree, no branch, nothing dispatched)

DISJOINT (1) — share no predicted file; these fan out in parallel
  gamma  src/gamma.js

COLLIDING-SPLITTABLE (2) — overlap a shared module that could be split apart first
  alpha  src/alpha.js src/shared.js
  beta   src/beta.js src/shared.js
    overlap: alpha + beta
      files:  src/shared.js
      reason: both rewrite the router

INHERENTLY-COUPLED (0) — overlap in the same logic; run sequentially, each rebased on the previous
  (none)

summary: 3 tasks — 1 DISJOINT, 2 COLLIDING-SPLITTABLE, 0 INHERENTLY-COUPLED
```

It dispatches nothing: no worktree, no branch, no task agent, no status
transition. The one thing it writes is the `plan.json` above, in a run dir with
no tasks registered in it. Because it only reads the index, it answers on a
dirty tree and off `BASE_BRANCH` too — the states `run` refuses — which is
exactly when you want to ask.

## Lane checking (`lib/lane.sh`) — warn only

Those per-task file predictions are also a *lane*. At gate time — after the
suite is green and the commit is made — the core diffs what the agent actually
touched (`git diff --name-only <base>...HEAD` in its worktree) against what
`plan.json` predicted for that task. Anything touched that the plan didn't name
is a stray, and a stray writes `<run-dir>/warnings/<task>`:

```
$ cat .yolotown/latest/warnings/add-rss
strayed outside predicted lane: touched docs/notes.md
predicted: src/feed.js src/routes.js
touched:   src/feed.js docs/notes.md
warn only: a lane violation never fails a task (SPEC.md sections 2 and 7).
```

The report reads that file and nothing else to render `PASSED-WITH-WARNING`,
showing line 1 in the table beside the usual pointers and the usual merge
command.

**It never fails a task.** A strayed task is committed, pushed, and reported
green exactly like any other; the warning is a note for the human reviewing the
branch, not a gate. Whether lane violations ever become blocking is a decision
deliberately deferred (SPEC.md section 7), so the check has no path that can
fail a task even by accident.

**No prediction is not a violation.** `yolotown run-one` never runs conflict
detection, so its run dir has no `plan.json` and there is nothing to compare
against; the same goes for a task a plan simply doesn't name. Those are
*unchecked*, which is silent — no warning file, no `warnings/` directory, one
line in the log saying why. Warning there would mean warning on every
single-task run.

Matching is exact on repo-relative paths, with no prefix or directory
leniency: a warning that quietly forgives a whole subtree is one nobody reads.

## Testing

```sh
./test.sh              # full suite; mocks only external side-effecting binaries
RUN_LIVE=1 ./test.sh   # also run the one live smoke test (costs tokens)
KEEP_TMP=1 ./test.sh   # preserve test temp dirs for autopsy
```

Tests build throwaway fixture repos with a real gate script and a bare
filesystem origin; the agent is a shim (`tests/fake-claude`) selected via
`CLAUDE_BIN`, with behavior driven by `FAKE_CLAUDE_MODE`.

## Security / permissions decisions

- The headless agent runs with `--allowedTools "Edit" "Write" "Read" "Glob"
  "Grep" "Bash"`. `Bash` is deliberately unscoped: open-ended tasks
  legitimately need arbitrary commands, and per-command scoping is
  impractical. Isolation comes from the worktree plus the prompt's
  prohibition on git write operations. `--dangerously-skip-permissions` is
  **not** used.
- `ENV_FILES` are copied into worktrees and verified git-ignored there; a
  file that would be committed aborts the run.

## Known limitations

- No agent timeout: a hung agent holds its worker slot for as long as it
  hangs (Ctrl-C is safe; worktrees are never auto-deleted once an agent has
  run).
- No resumability of interrupted runs.
- Conflict detection is not wired into `run` yet: `plan` buckets a backlog on
  demand, but `run` still assumes you wrote the tasks so they don't collide.
  The gated refactor stage and that wiring are the rest of Stage 3.
