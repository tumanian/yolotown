#!/usr/bin/env bash
# Agent reachability precheck: one probe per INVOCATION, before anything is
# created. A reachable agent lets the run proceed untouched; an unreachable one
# refuses the whole run — nonzero exit, no run dir, no worktree, no branch, and
# an error naming the fix — instead of burning one agent invocation and leaving
# one orphaned worktree per task.
#
# The probe is a separate seam in tests/fake-claude (FAKE_CLAUDE_PROBE_MODE,
# default ok) from the task agent's (FAKE_CLAUDE_MODE), so "how the task agent
# behaves" is unchanged by preflight — the last case below pins that down, and
# crash.test.sh depends on it.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

YOLOTOWN="$YOLOTOWN_ROOT/yolotown"

# The probe marker comes from the implementation itself rather than a copy, so
# the counting shim below recognizes probes even if the wording changes.
# shellcheck source=../lib/task.sh
. "$YOLOTOWN_ROOT/lib/task.sh"
export PROBE_MARKER="$YT_AGENT_PROBE_MARKER"

run_yt() {
  YT_OUT="$(cd "$REPO" && "$YOLOTOWN" "$@" </dev/null 2>&1)"
  YT_RC=$?
}

# =============================================================================
# reachable agent: the probe is silent-ish and the run proceeds as before
# =============================================================================
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=good

run_seed reach-task "Add the feature module"
assert_eq "$SEED_RC" 0 "a reachable agent still runs the task to green"
assert_contains "$SEED_OUT" "agent reachable" "preflight reports the probe passed"
assert_contains "$SEED_OUT" "RESULT: PASSED" "the run proceeded past preflight"
assert_file_exists "$TMP_ROOT/yt-reach-task" "worktree created when the agent is reachable"
ok "reachable agent: run proceeds"

# =============================================================================
# unreachable agent (seed.sh): refuse up front, create nothing, name the fix
# =============================================================================
reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=good
export FAKE_CLAUDE_PROBE_MODE=unreachable

run_seed refused-task "Add the feature module"
[ "$SEED_RC" -ne 0 ] || _fail "an unreachable agent must exit nonzero"
assert_eq "$SEED_RC" 1 "unreachable agent exits 1 (preflight refusal)"
assert_contains "$SEED_OUT" "not reachable" "error names the unreachable agent"
assert_contains "$SEED_OUT" "$FAKE_CLAUDE" "error names the offending binary"
assert_contains "$SEED_OUT" "expired or missing" "error names the likely cause"
assert_contains "$SEED_OUT" "claude logout && claude login" "error shows the exact fix"
assert_contains "$SEED_OUT" "Failed to authenticate" "error shows the probe's own output"
assert_not_contains "$SEED_OUT" "RESULT:" "refused before any task report"

assert_file_missing "$TMP_ROOT/yt-refused-task" "no worktree created on refusal"
assert_file_missing "$REPO/.yolotown" "no run dir created on refusal"
if git -C "$REPO" rev-parse --verify --quiet refs/heads/feature/refused-task >/dev/null; then
  _fail "no branch should be created on refusal"
fi
ok "unreachable agent: seed refuses, creating nothing"

# =============================================================================
# unreachable agent (yolotown run): ONE refusal for the whole backlog — not one
# wasted invocation and one orphaned worktree per task
# =============================================================================
reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=good
export FAKE_CLAUDE_PROBE_MODE=unreachable

cat > "$REPO/backlog.txt" <<'EOF'
alpha | first small feature
beta  | second small feature
EOF

run_yt run backlog.txt
[ "$YT_RC" -ne 0 ] || _fail "run with an unreachable agent must exit nonzero"
assert_contains "$YT_OUT" "not reachable" "run's error names the unreachable agent"
assert_contains "$YT_OUT" "claude logout && claude login" "run's error shows the exact fix"
assert_file_missing "$TMP_ROOT/yt-alpha" "no worktree for the first task"
assert_file_missing "$TMP_ROOT/yt-beta" "no worktree for the second task"
assert_file_missing "$REPO/.yolotown" "no run dir for the refused batch"
ok "unreachable agent: run refuses the whole batch before creating anything"

# =============================================================================
# missing binary: CLAUDE_BIN pointing at nothing is caught by the same probe
# =============================================================================
reset_fixture
MISSING_BIN="$TMP_ROOT/no-such-claude"
make_fixture_repo "CLAUDE_BIN=\"$MISSING_BIN\""
make_bare_origin
unset FAKE_CLAUDE_PROBE_MODE

run_seed missing-bin "Add the feature module"
assert_eq "$SEED_RC" 1 "a CLAUDE_BIN that does not exist exits 1"
assert_contains "$SEED_OUT" "not reachable" "error names the unreachable agent"
assert_contains "$SEED_OUT" "$MISSING_BIN" "error names the missing binary"
assert_contains "$SEED_OUT" "claude logout && claude login" "error shows the exact fix"
assert_file_missing "$TMP_ROOT/yt-missing-bin" "no worktree created"
assert_file_missing "$REPO/.yolotown" "no run dir created"
ok "missing binary: refused by the same probe"

# =============================================================================
# one probe per invocation, NOT per task: a 3-task backlog probes exactly once
# =============================================================================
reset_fixture
PROBE_COUNT="$TMP_ROOT/probe-count"
: > "$PROBE_COUNT"
export PROBE_COUNT_FILE="$PROBE_COUNT"

# A shim that counts probe invocations (any argv carrying the marker) and
# otherwise plays a good agent: a harmless edit so the gate stays green.
COUNT_SHIM="$TMP_ROOT/counting-claude"
cat > "$COUNT_SHIM" <<'EOF'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  case "$a" in
    *"$PROBE_MARKER"*) printf 'probe\n' >> "$PROBE_COUNT_FILE"; echo "ok"; exit 0 ;;
  esac
done
mkdir -p src
printf '// added by the counting shim\n' > "src/added-$$.js"
echo "counting shim: made an edit, gate stays green"
exit 0
EOF
chmod +x "$COUNT_SHIM"

make_fixture_repo "CLAUDE_BIN=\"$COUNT_SHIM\""
make_bare_origin
unset FAKE_CLAUDE_MODE

cat > "$REPO/backlog.txt" <<'EOF'
one   | first small feature
two   | second small feature
three | third small feature
EOF

run_yt run backlog.txt
assert_eq "$YT_RC" 0 "a three-task green batch still exits 0 with the probe in place"
probes="$(wc -l < "$PROBE_COUNT" | tr -d ' ')"
assert_eq "$probes" "1" "the agent was probed exactly once for the whole batch"
RUN="$REPO/.yolotown/$(readlink "$REPO/.yolotown/latest")"
assert_eq "$(cat "$RUN/status/one")" "passed" "first task still ran"
assert_eq "$(cat "$RUN/status/three")" "passed" "third task still ran"
unset PROBE_COUNT_FILE
ok "one probe per invocation, not per task"

# =============================================================================
# the two seams are independent: a crashing TASK agent still gets past preflight
# (this is the contract crash.test.sh relies on)
# =============================================================================
reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=crash

run_seed crashing-task "Trigger a simulated crash"
assert_eq "$SEED_RC" 1 "a crashing task agent still fails the task"
assert_contains "$SEED_OUT" "agent reachable" "preflight passed: the probe is not FAKE_CLAUDE_MODE"
assert_contains "$SEED_OUT" "RESULT: FAILED (agent exited nonzero" "failure is the task's, not preflight's"
assert_file_exists "$TMP_ROOT/yt-crashing-task" "worktree still created and left intact for autopsy"
ok "probe mode is independent of task-agent mode"

echo "agent-precheck: all cases passed"
