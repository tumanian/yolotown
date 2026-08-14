#!/usr/bin/env bash
# Regression: seed.sh must invoke the headless agent with stdin redirected from
# /dev/null (lib/task.sh), so the agent can never inherit — and stall on, or
# read — the caller's stdin. This drives the FULL seed path (not the core in
# isolation) with stdin connected to a PIPE CARRYING DATA the agent must never
# see. tests/fake-claude records what its stdin looked like: with the redirect
# it sees EOF; strip the </dev/null and it reads the pipe instead.
#
# Why the pipe-with-data matters: helpers.sh run_seed already feeds seed </dev/null,
# so through that door the agent sees EOF whether or not the core redirects —
# a naive test would pass while proving nothing. Only a data-bearing stdin that
# survives seed's happy path (which never reads stdin when the base branch
# exists) can tell the two cases apart. Confirmed teeth: removing </dev/null
# from lib/task.sh line 131 flips this file's assertion from <eof> to the data.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

STDIN_REC="$TMP_ROOT/agent-stdin-seen"
PIPE_DATA="STDIN-DATA-MUST-NOT-REACH-AGENT"

make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=good
export FAKE_CLAUDE_STDIN_FILE="$STDIN_REC"

# Invoke seed with a pipe carrying a line of data on stdin — NOT /dev/null.
# seed's happy path never reads stdin (base branch "main" exists), so the data
# flows straight through to the agent invocation, where the </dev/null redirect
# in lib/task.sh is the only thing standing between the agent and this line.
SEED_OUT="$(cd "$REPO" && printf '%s\n' "$PIPE_DATA" | "$SEED" my-task "Add the feature module" 2>&1)"
SEED_RC=$?

assert_eq "$SEED_RC" 0 "seed with a data-bearing stdin still exits 0"
assert_file_exists "$STDIN_REC" "the agent shim recorded its stdin"
assert_eq "$(cat "$STDIN_REC")" "stdin: <eof>" \
  "agent saw /dev/null (EOF), not the caller's piped stdin"
assert_not_contains "$(cat "$STDIN_REC")" "$PIPE_DATA" \
  "the caller's stdin line never reached the agent"

unset FAKE_CLAUDE_STDIN_FILE
ok "seed shields the headless agent from the caller's stdin (</dev/null)"

echo "agent-stdin: all cases passed"
