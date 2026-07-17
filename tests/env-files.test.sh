#!/usr/bin/env bash
# Env files: copied into the worktree, never tracked there, never pushed.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=good

run_seed env-task "A feature that needs the env file"
assert_eq "$SEED_RC" 0 "green path exits 0"

WT="$TMP_ROOT/yt-env-task"
assert_file_exists "$WT/.env" "env file present in worktree"
assert_eq "$(cat "$WT/.env")" "SECRET=fixture-secret" "env file content intact"

tracked="$(git -C "$WT" ls-files)"
assert_not_contains "$tracked" ".env" "env file not tracked in the worktree"

pushed_tree="$(git -C "$ORIGIN" ls-tree -r --name-only refs/heads/feature/env-task)"
assert_not_contains "$pushed_tree" ".env" "env file absent from the pushed tree"

echo "env-files: all cases passed"
