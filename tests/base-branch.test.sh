#!/usr/bin/env bash
# Base branch existence: a repo with zero commits at all is refused outright
# (nothing to branch from); a repo with commits under a different branch name
# gets a y/N confirmation to create the configured base branch there. A
# non-interactive/empty reply defaults to "no", same as an explicit decline.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- case 1: repo has zero commits at all -----------------------------------
mkdir -p "$REPO"
git init -q -b main "$REPO"
echo 'TEST_CMD="true"' > "$REPO/.yolotown.conf"
run_seed some-task "A task"
assert_eq "$SEED_RC" 1 "zero-commit repo exits 1"
assert_contains "$SEED_OUT" "no commits yet" "error explains there is nothing to branch from"
ok "zero commits: refuses outright, no prompt"

# ---- case 2: base branch missing, commits exist under another name ------------
reset_fixture
make_fixture_repo 'PUSH_ON_GREEN="false"'
git -C "$REPO" checkout -qb trunk main
git -C "$REPO" branch -D main

# non-interactive (run_seed redirects stdin from /dev/null): defaults to "no"
run_seed some-task "A task"
assert_eq "$SEED_RC" 1 "missing base branch, no input, exits 1"
assert_contains "$SEED_OUT" "does not exist" "prompt names the missing base branch"
assert_contains "$SEED_OUT" "aborted" "empty reply defaults to abort"
assert_contains "$SEED_OUT" "git branch main trunk" "error suggests the exact create command"
if git -C "$REPO" rev-parse --verify --quiet refs/heads/main >/dev/null; then
  _fail "declining (or defaulting) must not create the base branch"
fi
ok "missing base branch: no input defaults to abort, nothing created"

# explicit "n": same outcome
run_seed_with_input "n" some-task "A task"
assert_eq "$SEED_RC" 1 "explicit n exits 1"
assert_contains "$SEED_OUT" "aborted" "explicit n aborts"
ok "missing base branch: explicit n aborts"

# ---- case 3: confirm "y" creates the branch and the run proceeds to green -----
export FAKE_CLAUDE_MODE=good
run_seed_with_input "y" confirmed-task "Add the feature via a confirmed branch"
assert_eq "$SEED_RC" 0 "confirming y creates the branch and proceeds to green"
assert_contains "$SEED_OUT" "Create it now pointing at current HEAD" "prompt was shown"
assert_contains "$SEED_OUT" "RESULT: PASSED" "run completed green after creating the branch"
git -C "$REPO" rev-parse --verify --quiet refs/heads/main >/dev/null \
  || _fail "base branch main should now exist, created from trunk"
main_tip="$(git -C "$REPO" rev-parse main)"
trunk_tip="$(git -C "$REPO" rev-parse trunk)"
assert_eq "$main_tip" "$trunk_tip" "main was created pointing at trunk's tip"
ok "confirming y creates the base branch and the run proceeds"

echo "base-branch: all cases passed"
