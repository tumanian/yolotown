#!/usr/bin/env bash
# Fail-fast: every refusal path exits nonzero with the right message and
# touches nothing it shouldn't.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
export FAKE_CLAUDE_MODE=good

# ---- missing .yolotown.conf ---------------------------------------------------
make_fixture_repo
git -C "$REPO" rm -q .yolotown.conf
git -C "$REPO" commit -qm "drop conf"
run_seed some-task "A task"
assert_eq "$SEED_RC" 2 "missing conf exits 2"
assert_contains "$SEED_OUT" ".yolotown.conf" "error names the missing file"
assert_contains "$SEED_OUT" "TEST_CMD=" "error shows a valid example"
ok "missing conf"

# ---- conf without TEST_CMD ----------------------------------------------------
reset_fixture
FIXTURE_CONF="CLAUDE_BIN=\"$FAKE_CLAUDE\"" make_fixture_repo
run_seed some-task "A task"
assert_eq "$SEED_RC" 2 "missing TEST_CMD exits 2"
assert_contains "$SEED_OUT" "TEST_CMD is required" "error names the offending key"
assert_contains "$SEED_OUT" "TEST_CMD=\"npm test\"" "error shows a valid example"
ok "missing TEST_CMD"

# ---- invalid PUSH_ON_GREEN ------------------------------------------------------
reset_fixture
make_fixture_repo 'PUSH_ON_GREEN="yes"'
run_seed some-task "A task"
assert_eq "$SEED_RC" 2 "invalid PUSH_ON_GREEN exits 2"
assert_contains "$SEED_OUT" "PUSH_ON_GREEN" "error names the offending key"
ok "invalid PUSH_ON_GREEN"

# ---- bad task name ---------------------------------------------------------------
reset_fixture
make_fixture_repo
run_seed "Bad_Name" "A task"
assert_eq "$SEED_RC" 2 "bad task name exits 2"
assert_contains "$SEED_OUT" "invalid" "error says the name is invalid"
ok "bad task name"

# ---- missing description -----------------------------------------------------------
run_seed only-a-name
assert_eq "$SEED_RC" 2 "missing description exits 2"
assert_contains "$SEED_OUT" "usage:" "prints usage"
ok "missing description"

# ---- dirty base ---------------------------------------------------------------------
reset_fixture
make_fixture_repo
echo "// uncommitted" >> "$REPO/src/app.js"
run_seed some-task "A task"
assert_eq "$SEED_RC" 1 "dirty base exits 1"
assert_contains "$SEED_OUT" "dirty" "error says the tree is dirty"
ok "dirty base"

# ---- red base suite -------------------------------------------------------------------
reset_fixture
make_fixture_repo
printf 'not valid js {{{\n' > "$REPO/src/app.js"
git -C "$REPO" commit -qam "break the base"
run_seed some-task "A task"
assert_eq "$SEED_RC" 1 "red base exits 1"
assert_contains "$SEED_OUT" "base suite is red" "error names the red base"
assert_file_missing "$TMP_ROOT/yt-some-task" "no worktree created on red base"
ok "red base suite"

# ---- not on base branch ----------------------------------------------------------------
reset_fixture
make_fixture_repo
git -C "$REPO" checkout -qb other
run_seed some-task "A task"
assert_eq "$SEED_RC" 1 "wrong branch exits 1"
assert_contains "$SEED_OUT" "not base branch" "error names the checkout mismatch"
ok "not on base branch"

# ---- branch collision -------------------------------------------------------------------
reset_fixture
make_fixture_repo
git -C "$REPO" branch feature/some-task
run_seed some-task "A task"
assert_eq "$SEED_RC" 1 "branch collision exits 1"
assert_contains "$SEED_OUT" "already exists" "error names the collision"
assert_contains "$SEED_OUT" "git branch -D feature/some-task" "error includes cleanup command"
ok "branch collision"

# ---- worktree path collision ---------------------------------------------------------------
reset_fixture
make_fixture_repo
mkdir -p "$TMP_ROOT/yt-some-task"
run_seed some-task "A task"
assert_eq "$SEED_RC" 1 "worktree collision exits 1"
assert_contains "$SEED_OUT" "already exists" "error names the collision"
assert_contains "$SEED_OUT" "git worktree remove --force" "error includes cleanup command"
ok "worktree path collision"

# ---- env file missing -------------------------------------------------------------------------
reset_fixture
make_fixture_repo
rm "$REPO/.env"
run_seed some-task "A task"
assert_eq "$SEED_RC" 1 "missing env file exits 1"
assert_contains "$SEED_OUT" "\".env\" not found" "error names the missing env file"
assert_file_missing "$TMP_ROOT/yt-some-task" "no worktree created"
ok "env file missing"

# ---- env file not git-ignored (fresh worktree auto-removed) --------------------------------------
reset_fixture
FIXTURE_GITIGNORE=".yolotown/" make_fixture_repo
run_seed some-task "A task"
assert_eq "$SEED_RC" 1 "unignored env file exits 1"
assert_contains "$SEED_OUT" "not git-ignored" "error names the rule"
assert_file_missing "$TMP_ROOT/yt-some-task" "fresh worktree auto-removed"
if git -C "$REPO" rev-parse --verify --quiet refs/heads/feature/some-task >/dev/null; then
  _fail "fresh branch should be auto-removed with the worktree"
fi
ok "env file not git-ignored"

echo "fail-fast: all cases passed"
