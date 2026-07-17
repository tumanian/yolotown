#!/usr/bin/env bash
# Agent misbehavior: a crashing agent and a no-op agent each yield a FAILED
# task with the right reason — never a crashed orchestrator, never an empty
# commit — with the worktree left intact.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- case 1: agent exits nonzero --------------------------------------------
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=crash

run_seed crash-task "Trigger a simulated crash"
assert_eq "$SEED_RC" 1 "crash exits 1"
assert_contains "$SEED_OUT" "RESULT: FAILED (agent exited nonzero" "FAILED with crash reason"
assert_contains "$SEED_OUT" "git worktree remove --force" "orchestrator completed its report"
assert_file_exists "$TMP_ROOT/yt-crash-task" "worktree left intact"

logfile="$(ls "$REPO"/.yolotown/logs/crash-task-*.log)"
assert_contains "$(cat "$logfile")" "simulated agent crash" "agent stderr captured in log"

count="$(git -C "$TMP_ROOT/yt-crash-task" rev-list --count main..feature/crash-task)"
assert_eq "$count" 0 "no commit after a crash"
ok "agent crash contained"

# ---- case 2: agent makes no changes ------------------------------------------
reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=noop

run_seed noop-task "A task the agent ignores"
assert_eq "$SEED_RC" 1 "noop exits 1"
assert_contains "$SEED_OUT" "RESULT: FAILED (agent made no changes)" "FAILED with noop reason"
assert_file_exists "$TMP_ROOT/yt-noop-task" "worktree left intact"

count="$(git -C "$TMP_ROOT/yt-noop-task" rev-list --count main..feature/noop-task)"
assert_eq "$count" 0 "no empty commit"
ok "noop yields FAILED, not an empty commit"

echo "crash: all cases passed"
