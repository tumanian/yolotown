#!/usr/bin/env bash
# setup.sh: ensures an "origin" remote exists. Already-configured is a
# no-op; missing prompts to reuse an existing remote or create one via gh
# (mocked through GH_BIN -> tests/fake-gh, never the real gh CLI).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- case 1: origin already configured ---------------------------------------
make_fixture_repo
make_bare_origin
run_setup
assert_eq "$SETUP_RC" 0 "already-configured origin exits 0"
assert_contains "$SETUP_OUT" "already configured" "reports the existing remote"
assert_contains "$SETUP_OUT" "$ORIGIN" "reports the actual URL"
ok "origin already configured: no-op"

# ---- case 2: no origin, user has one, provides a URL --------------------------
reset_fixture
make_fixture_repo
run_setup_with_input $'y\nhttps://example.com/someone/repo.git\n'
assert_eq "$SETUP_RC" 0 "providing a URL exits 0"
assert_eq "$(git -C "$REPO" remote get-url origin)" "https://example.com/someone/repo.git" "origin set to the given URL"
ok "user provides an existing remote URL"

# ---- case 3: no origin, user says yes but gives an empty URL ------------------
reset_fixture
make_fixture_repo
run_setup_with_input $'y\n\n'
assert_eq "$SETUP_RC" 1 "empty URL exits 1"
assert_contains "$SETUP_OUT" "no URL given" "error names the problem"
if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
  _fail "no remote should be added on an empty URL"
fi
ok "empty URL refused"

# ---- case 4: no origin, declines own remote, gh not available ------------------
reset_fixture
make_fixture_repo
export GH_BIN=/nonexistent/gh
run_setup_with_input $'n\n'
unset GH_BIN
assert_eq "$SETUP_RC" 1 "no gh available exits 1"
assert_contains "$SETUP_OUT" "no remote configured" "explains nothing was configured"
assert_contains "$SETUP_OUT" "PUSH_ON_GREEN" "mentions the local-only escape hatch"
ok "gh unavailable: fails with manual instructions"

# ---- case 5: no origin, declines own remote, gh available, declines creation ---
reset_fixture
make_fixture_repo
export GH_BIN="$FAKE_GH"
run_setup_with_input $'n\nn\n'
assert_eq "$SETUP_RC" 1 "declining gh creation exits 1"
assert_contains "$SETUP_OUT" "no remote configured" "explains nothing was configured"
if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
  _fail "no remote should be added when the user declines both options"
fi
ok "declines both: no remote configured"

# ---- case 6: no origin, declines own remote, creates via gh (default visibility)
reset_fixture
make_fixture_repo
export FAKE_GH_MODE=good
export FAKE_GH_ARGV_FILE="$TMP_ROOT/gh-argv"
run_setup_with_input $'n\ny\n\n'
assert_eq "$SETUP_RC" 0 "gh creation exits 0"
assert_contains "$SETUP_OUT" "created GitHub repo" "reports success"
origin_url="$(git -C "$REPO" remote get-url origin)"
assert_contains "$origin_url" "fake-owner" "origin points at the fake-created repo"
argv="$(cat "$FAKE_GH_ARGV_FILE")"
assert_contains "$argv" "repo" "invoked gh repo"
assert_contains "$argv" "create" "invoked gh repo create"
assert_contains "$argv" "--source=." "passed --source=."
assert_contains "$argv" "--remote=origin" "passed --remote=origin"
assert_contains "$argv" "--private" "defaulted to private visibility"
ok "creates via gh with default (private) visibility"

# ---- case 7: explicit public visibility ----------------------------------------
reset_fixture
make_fixture_repo
run_setup_with_input $'n\ny\npublic\n'
assert_eq "$SETUP_RC" 0 "explicit public visibility exits 0"
argv="$(cat "$FAKE_GH_ARGV_FILE")"
assert_contains "$argv" "--public" "passed --public"
ok "explicit public visibility"

# ---- case 8: invalid visibility ------------------------------------------------
reset_fixture
make_fixture_repo
run_setup_with_input $'n\ny\nmaybe\n'
assert_eq "$SETUP_RC" 1 "invalid visibility exits 1"
assert_contains "$SETUP_OUT" "must be \"public\" or \"private\"" "error names the valid values"
ok "invalid visibility refused"

# ---- case 9: gh repo create itself fails -----------------------------------------
reset_fixture
make_fixture_repo
export FAKE_GH_MODE=fail
run_setup_with_input $'n\ny\n\n'
assert_eq "$SETUP_RC" 1 "gh failure exits 1"
assert_contains "$SETUP_OUT" "gh repo create failed" "error names the gh failure"
if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
  _fail "no remote should be added when gh repo create fails"
fi
unset FAKE_GH_MODE FAKE_GH_ARGV_FILE GH_BIN
ok "gh repo create failure surfaced, no remote added"

echo "setup: all cases passed"
