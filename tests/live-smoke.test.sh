#!/usr/bin/env bash
# Live smoke test: runs the REAL claude CLI once on a trivial task. The only
# test that costs tokens; exists to catch CLI flag drift the shim cannot.
# Opt-in: RUN_LIVE=1 ./test.sh
set -u

if [ "${RUN_LIVE:-0}" != "1" ]; then
  echo "live-smoke: SKIPPED (set RUN_LIVE=1 to run the real claude CLI)"
  exit 0
fi

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_fixture_repo 'CLAUDE_BIN="claude"' 'PUSH_ON_GREEN="false"'

run_seed add-comment "Add a single-line JS comment at the top of src/app.js. Do not change anything else."
assert_eq "$SEED_RC" 0 "live green path exits 0"

WT="$TMP_ROOT/yt-add-comment"
count="$(git -C "$WT" rev-list --count main..feature/add-comment)"
assert_eq "$count" 1 "exactly one commit from the live agent"

echo "live-smoke: passed"
