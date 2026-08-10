# YOLOTOWN

A repo-agnostic command line tool that orchestrates headless Claude Code
agents against any git repo that has a test suite. Tasks fan out to parallel
agents in isolated git worktrees, each gated by the target repo's own tests.
Green branches get committed and optionally pushed. The tool's contract ends
at "green branch exists" — it never merges to your base branch.

**Current state: Stage 0 (the seed).** `seed.sh` runs exactly one task
through one agent in one worktree. The staged roadmap (serial self-build →
parallel fan-out → conflict detection and the gated refactor stage) is built
*by* the seed, task by task, gated by this repo's own test suite. See
[DESIGN.md](DESIGN.md) for the approved seed design.

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
| `WORKER_MODEL` | CLI default | model for task execution |
| `CLAUDE_BIN` | `claude` | agent binary; also the test seam |

Keys used by later stages (`MAX_PARALLEL`, `SOURCE_GLOBS`, `PLANNER_MODEL`)
are accepted and ignored by the seed.

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

## Known limitations (Stage 0)

- No agent timeout: a hung agent hangs the run (Ctrl-C is safe; worktrees
  are never auto-deleted once an agent has run).
- No resumability of interrupted runs.
- One task per invocation; the task-list pipeline arrives in Stage 1.
