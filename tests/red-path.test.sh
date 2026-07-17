#!/usr/bin/env bash
# Red path: agent breaks the gate; no commit, no push, worktree intact for
# autopsy, log points at the failure, exit 1.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=bad

run_seed bad-task "Break everything subtly"
assert_eq "$SEED_RC" 1 "red path exits 1"

WT="$TMP_ROOT/yt-bad-task"
assert_file_exists "$WT" "worktree left intact for autopsy"

count="$(git -C "$WT" rev-list --count main..feature/bad-task)"
assert_eq "$count" 0 "no commit on a red gate"

dirty="$(git -C "$WT" status --porcelain)"
[ -n "$dirty" ] || _fail "agent's uncommitted changes should remain in the worktree"

if git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/bad-task >/dev/null; then
  _fail "nothing may be pushed on a red gate"
fi

assert_contains "$SEED_OUT" "RESULT: FAILED (gate red" "report says FAILED at the gate"
assert_contains "$SEED_OUT" ".yolotown/logs/bad-task-" "report points at the log"

logfile="$(ls "$REPO"/.yolotown/logs/bad-task-*.log)"
assert_contains "$(cat "$logfile")" "SyntaxError" "log captures the gate failure output"

echo "red-path: all cases passed"
