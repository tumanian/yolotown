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
/path/to/yolotown/yolotown plan            # parse and list; touches nothing
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
| `INVARIANTS_FILE` | `CLAUDE.md` if present | injected into agent prompts |
| `BASE_BRANCH` | `main` | branch worktrees are cut from |
| `BRANCH_PREFIX` | `feature/` | prefix for task branches |
| `PUSH_ON_GREEN` | `true` | `false` = commit locally, don't push |
| `MAX_PARALLEL` | `3` | workers `yolotown run` keeps in flight at once |
| `WORKER_MODEL` | CLI default | model for task execution |
| `CLAUDE_BIN` | `claude` | agent binary; also the test seam |

Keys used by later stages (`SOURCE_GLOBS`, `PLANNER_MODEL`) are accepted and
ignored for now.

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
- No conflict detection yet: `plan` only parses and lists, and `run` assumes
  you wrote the backlog so its tasks don't collide. Bucketing and the gated
  refactor stage are Stage 3.
