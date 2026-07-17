#!/usr/bin/env bash
# Green path: agent makes a good edit; gate green; exactly one commit on the
# right branch, pushed to the bare origin; log captured; prompt/flags correct.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- case 1: defaults (PUSH_ON_GREEN=true, no WORKER_MODEL) -----------------
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=good
export FAKE_CLAUDE_ARGV_FILE="$TMP_ROOT/argv"

run_seed my-task "Add the feature module as described"
assert_eq "$SEED_RC" 0 "green path exits 0"

WT="$TMP_ROOT/yt-my-task"
assert_file_exists "$WT/src/feature.js" "agent edit landed in worktree"

count="$(git -C "$WT" rev-list --count main..feature/my-task)"
assert_eq "$count" 1 "exactly one commit on the feature branch"

subject="$(git -C "$WT" log -1 --format=%s feature/my-task)"
assert_eq "$subject" "feat(my-task): Add the feature module as described" "commit subject format"

body="$(git -C "$WT" log -1 --format=%b feature/my-task)"
assert_contains "$body" "yolotown" "commit body notes yolotown authorship"
assert_contains "$body" "Add the feature module as described" "commit body carries full description"

origin_tip="$(git -C "$ORIGIN" rev-parse refs/heads/feature/my-task)"
local_tip="$(git -C "$WT" rev-parse feature/my-task)"
assert_eq "$origin_tip" "$local_tip" "pushed tip matches local tip"

logfile="$(ls "$REPO"/.yolotown/logs/my-task-*.log)"
assert_file_exists "$logfile" "log file created"
assert_contains "$(cat "$logfile")" "created src/feature.js" "agent output captured in log"

assert_contains "$SEED_OUT" "RESULT: PASSED" "report says PASSED"
assert_contains "$SEED_OUT" "git merge --no-ff feature/my-task" "report emits merge command"
assert_contains "$SEED_OUT" "git worktree remove --force" "report emits cleanup commands"

argv="$(cat "$FAKE_CLAUDE_ARGV_FILE")"
assert_contains "$argv" "-p" "invoked with -p"
assert_contains "$argv" "Add the feature module as described" "prompt contains task description"
assert_contains "$argv" "./check.sh" "prompt contains TEST_CMD"
assert_contains "$argv" "FIXTURE-INVARIANT" "prompt contains invariants file content"
assert_contains "$argv" "--allowedTools" "invoked with --allowedTools"
assert_not_contains "$argv" "--model" "no --model flag when WORKER_MODEL unset"
assert_not_contains "$argv" "dangerously-skip-permissions" "never skips permissions"
ok "green path with push"

# ---- case 2: PUSH_ON_GREEN=false, WORKER_MODEL set --------------------------
reset_fixture
make_fixture_repo 'PUSH_ON_GREEN="false"' 'WORKER_MODEL="claude-sonnet-5"'
make_bare_origin

run_seed local-task "Another small feature"
assert_eq "$SEED_RC" 0 "no-push green path exits 0"

WT="$TMP_ROOT/yt-local-task"
count="$(git -C "$WT" rev-list --count main..feature/local-task)"
assert_eq "$count" 1 "commit exists locally"

if git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/local-task >/dev/null; then
  _fail "PUSH_ON_GREEN=false: branch must not reach origin"
fi
assert_contains "$SEED_OUT" "pushed: no" "report says not pushed"

argv="$(cat "$FAKE_CLAUDE_ARGV_FILE")"
assert_contains "$argv" "--model" "WORKER_MODEL passes --model"
assert_contains "$argv" "claude-sonnet-5" "WORKER_MODEL value passed through"
ok "green path without push, with model override"

echo "green-path: all cases passed"
