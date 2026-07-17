#!/usr/bin/env bash
# lib/config.sh: defaults, overrides, and every fail-fast refusal.
# Exercises the loader directly, in a scratch dir — no git, no agent needed.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

CONF_DIR="$TMP_ROOT/confdir"

# fresh_conf_dir [conf content] — scratch dir with an optional .yolotown.conf.
# CONF_DIR is re-resolved through pwd so it matches the $PWD the loader reports
# (TMPDIR may carry a trailing slash; the loader's path is cd-normalized).
fresh_conf_dir() {
  rm -rf "$CONF_DIR"
  mkdir -p "$CONF_DIR"
  CONF_DIR="$(cd "$CONF_DIR" && pwd)"
  [ $# -eq 0 ] || printf '%s\n' "$1" > "$CONF_DIR/.yolotown.conf"
}

# load_config — runs yt_load_config in CONF_DIR and dumps the resulting config
# as key=value lines. Sets SEED_RC (loader exit code) and SEED_OUT (dump or
# error message), so helpers.sh's asserts report usefully on failure.
load_config() {
  SEED_OUT="$(cd "$CONF_DIR" && bash -c '
    set -uo pipefail
    . "$1/lib/config.sh"
    yt_load_config
    for k in TEST_CMD ENV_FILES INVARIANTS_FILE BASE_BRANCH \
             BRANCH_PREFIX PUSH_ON_GREEN WORKER_MODEL CLAUDE_BIN; do
      printf "%s=[%s]\n" "$k" "${!k}"
    done
  ' _ "$YOLOTOWN_ROOT" 2>&1)"
  SEED_RC=$?
}

# ---- defaults ------------------------------------------------------------------
fresh_conf_dir 'TEST_CMD="./check.sh"'
load_config
assert_eq "$SEED_RC" 0 "minimal conf loads"
assert_contains "$SEED_OUT" 'TEST_CMD=[./check.sh]'   "TEST_CMD comes from the conf"
assert_contains "$SEED_OUT" 'ENV_FILES=[]'            "ENV_FILES defaults empty"
assert_contains "$SEED_OUT" 'INVARIANTS_FILE=[]'      "INVARIANTS_FILE empty with no CLAUDE.md"
assert_contains "$SEED_OUT" 'BASE_BRANCH=[main]'      "BASE_BRANCH defaults to main"
assert_contains "$SEED_OUT" 'BRANCH_PREFIX=[feature/]' "BRANCH_PREFIX defaults to feature/"
assert_contains "$SEED_OUT" 'PUSH_ON_GREEN=[true]'    "PUSH_ON_GREEN defaults to true"
assert_contains "$SEED_OUT" 'WORKER_MODEL=[]'         "WORKER_MODEL defaults empty (CLI default)"
assert_contains "$SEED_OUT" 'CLAUDE_BIN=[claude]'     "CLAUDE_BIN defaults to claude"
ok "defaults"

# ---- conf overrides every default -------------------------------------------------
fresh_conf_dir 'TEST_CMD="npm test"
ENV_FILES=".env .env.local"
BASE_BRANCH="trunk"
BRANCH_PREFIX="yt/"
PUSH_ON_GREEN="false"
WORKER_MODEL="claude-opus-4-8"
CLAUDE_BIN="/usr/local/bin/claude"'
load_config
assert_eq "$SEED_RC" 0 "full conf loads"
assert_contains "$SEED_OUT" 'TEST_CMD=[npm test]'                "TEST_CMD override"
assert_contains "$SEED_OUT" 'ENV_FILES=[.env .env.local]'        "ENV_FILES override keeps both entries"
assert_contains "$SEED_OUT" 'BASE_BRANCH=[trunk]'                "BASE_BRANCH override"
assert_contains "$SEED_OUT" 'BRANCH_PREFIX=[yt/]'                "BRANCH_PREFIX override"
assert_contains "$SEED_OUT" 'PUSH_ON_GREEN=[false]'              "PUSH_ON_GREEN=false accepted"
assert_contains "$SEED_OUT" 'WORKER_MODEL=[claude-opus-4-8]'     "WORKER_MODEL override"
assert_contains "$SEED_OUT" 'CLAUDE_BIN=[/usr/local/bin/claude]' "CLAUDE_BIN override"
ok "conf overrides defaults"

# ---- unknown keys are tolerated -----------------------------------------------------
# Later stages own these; the seed must accept and ignore them.
fresh_conf_dir 'TEST_CMD="./check.sh"
MAX_PARALLEL="4"
SOURCE_GLOBS="src/**"
PLANNER_MODEL="claude-opus-4-8"'
load_config
assert_eq "$SEED_RC" 0 "unknown keys do not fail the load"
assert_contains "$SEED_OUT" 'TEST_CMD=[./check.sh]' "known keys still load alongside unknown ones"
ok "unknown keys tolerated"

# ---- missing .yolotown.conf ------------------------------------------------------------
fresh_conf_dir
load_config
assert_eq "$SEED_RC" 2 "missing conf exits 2"
assert_contains "$SEED_OUT" ".yolotown.conf" "error names the missing file"
assert_contains "$SEED_OUT" "$CONF_DIR"      "error names the directory it looked in"
assert_contains "$SEED_OUT" 'TEST_CMD="npm test"' "error shows a valid example"
ok "missing conf"

# ---- conf without TEST_CMD ---------------------------------------------------------------
fresh_conf_dir 'BASE_BRANCH="main"'
load_config
assert_eq "$SEED_RC" 2 "missing TEST_CMD exits 2"
assert_contains "$SEED_OUT" "TEST_CMD is required" "error names the offending key"
assert_contains "$SEED_OUT" 'TEST_CMD="npm test"'  "error shows a valid example"
ok "missing TEST_CMD"

# ---- empty TEST_CMD is the same as missing -------------------------------------------------
fresh_conf_dir 'TEST_CMD=""'
load_config
assert_eq "$SEED_RC" 2 "empty TEST_CMD exits 2"
assert_contains "$SEED_OUT" "TEST_CMD is required" "empty value is treated as missing"
ok "empty TEST_CMD"

# ---- unsourceable conf ------------------------------------------------------------------------
fresh_conf_dir 'TEST_CMD="unterminated'
load_config
assert_eq "$SEED_RC" 2 "unsourceable conf exits 2"
assert_contains "$SEED_OUT" "failed to source" "error says the conf could not be sourced"
ok "unsourceable conf"

# ---- invalid PUSH_ON_GREEN ----------------------------------------------------------------------
fresh_conf_dir 'TEST_CMD="./check.sh"
PUSH_ON_GREEN="yes"'
load_config
assert_eq "$SEED_RC" 2 "invalid PUSH_ON_GREEN exits 2"
assert_contains "$SEED_OUT" "PUSH_ON_GREEN" "error names the offending key"
assert_contains "$SEED_OUT" "yes"           "error shows the offending value"
ok "invalid PUSH_ON_GREEN"

# ---- INVARIANTS_FILE defaults to CLAUDE.md when present -------------------------------------------
fresh_conf_dir 'TEST_CMD="./check.sh"'
printf 'invariants\n' > "$CONF_DIR/CLAUDE.md"
load_config
assert_eq "$SEED_RC" 0 "conf with CLAUDE.md loads"
assert_contains "$SEED_OUT" 'INVARIANTS_FILE=[CLAUDE.md]' "INVARIANTS_FILE defaults to CLAUDE.md when it exists"
ok "INVARIANTS_FILE defaults to CLAUDE.md"

# ---- explicit INVARIANTS_FILE wins over CLAUDE.md ---------------------------------------------------
fresh_conf_dir 'TEST_CMD="./check.sh"
INVARIANTS_FILE="RULES.md"'
printf 'invariants\n' > "$CONF_DIR/CLAUDE.md"
printf 'rules\n'      > "$CONF_DIR/RULES.md"
load_config
assert_eq "$SEED_RC" 0 "explicit INVARIANTS_FILE loads"
assert_contains "$SEED_OUT" 'INVARIANTS_FILE=[RULES.md]' "explicit INVARIANTS_FILE is not overridden by CLAUDE.md"
ok "explicit INVARIANTS_FILE wins"

# ---- INVARIANTS_FILE pointing at nothing ---------------------------------------------------------------
fresh_conf_dir 'TEST_CMD="./check.sh"
INVARIANTS_FILE="nope.md"'
load_config
assert_eq "$SEED_RC" 2 "nonexistent INVARIANTS_FILE exits 2"
assert_contains "$SEED_OUT" "INVARIANTS_FILE" "error names the offending key"
assert_contains "$SEED_OUT" "nope.md"         "error names the offending file"
ok "nonexistent INVARIANTS_FILE"

# ---- seed.sh actually delegates to the library ------------------------------------------------------------
# Guards the extraction itself: seed.sh must source lib/config.sh rather than
# re-inlining defaults/validation.
assert_file_exists "$YOLOTOWN_ROOT/lib/config.sh" "lib/config.sh exists"
SEED_SRC="$(cat "$YOLOTOWN_ROOT/seed.sh")"
assert_contains     "$SEED_SRC" "lib/config.sh" "seed.sh sources lib/config.sh"
assert_contains     "$SEED_SRC" "yt_load_config" "seed.sh calls yt_load_config"
assert_not_contains "$SEED_SRC" 'BRANCH_PREFIX="feature/"' "seed.sh no longer inlines config defaults"
ok "seed.sh delegates to lib/config.sh"

echo "config: all cases passed"
