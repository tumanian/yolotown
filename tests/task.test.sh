#!/usr/bin/env bash
# lib/task.sh — the shared per-task execution core. seed.sh and `yolotown run`
# are both thin wrappers over yt_run_task; these tests drive the core directly.
# They prove the pipeline (green/red/noop/crash), the 0/1/2 return contract (it
# RETURNS, never exits, so a caller can continue past a failure), that the caller
# owns the run dir (the core never creates one), and the </dev/null stdin seam
# that unified the two former copies — the one deliberate behavior change.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

. "$YOLOTOWN_ROOT/lib/config.sh"
. "$YOLOTOWN_ROOT/lib/rundir.sh"
. "$YOLOTOWN_ROOT/lib/task.sh"

# prepare_core — cd into the freshly built fixture, load its config into the
# globals yt_run_task reads, point worktrees at the temp root, and hand back a
# fresh run dir in RUN. Mirrors exactly what a wrapper (seed.sh / cmd_run) does
# before calling the core.
prepare_core() {
  cd "$REPO" || _fail "cannot cd into fixture $REPO"
  yt_load_config
  WORKTREE_PARENT="$(dirname "$REPO")"
  if [ -n "$INVARIANTS_FILE" ]; then
    INVARIANTS_CONTENT="$(cat "$INVARIANTS_FILE")"
  else
    INVARIANTS_CONTENT="None provided."
  fi
  RUN="$(yt_run_create "$REPO/.yolotown" "$(date -u +%Y%m%dT%H%M%SZ)")" \
    || _fail "could not create run dir under $REPO/.yolotown"
}

count_run_dirs() { ls -1d "$REPO"/.yolotown/run-* 2>/dev/null | wc -l | tr -d ' '; }

# =============================================================================
# green path: agent edits, gate green — status passed, one commit, pushed, and
# the YT_TASK_* pointers are published for the caller's report.
# =============================================================================
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=good
prepare_core
yt_status_init "$RUN" alpha || _fail "could not register alpha"

yt_run_task "$RUN" alpha "Add the feature module"
rc=$?
assert_eq "$rc" 0 "green core returns 0"
assert_eq "$(cat "$RUN/status/alpha")" "passed" "green leaves status passed"
assert_eq "$YT_TASK_BRANCH" "feature/alpha" "YT_TASK_BRANCH published"
assert_eq "$YT_TASK_WT" "$TMP_ROOT/yt-alpha" "YT_TASK_WT published"
assert_eq "$YT_TASK_LOG" "$RUN/logs/alpha.log" "YT_TASK_LOG points into the run dir"
assert_eq "$YT_TASK_PUSHED" "yes" "YT_TASK_PUSHED is yes after a real push"
assert_eq "$YT_TASK_REASON" "" "no failure reason on success"

count="$(git -C "$TMP_ROOT/yt-alpha" rev-list --count main..feature/alpha)"
assert_eq "$count" 1 "exactly one commit on the feature branch"
git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/alpha >/dev/null \
  || _fail "green core should push to origin"
assert_eq "$(count_run_dirs)" 1 "the core never created its own run dir (caller owns it)"
ok "green: passed, committed, pushed, pointers published, no extra run dir"

# =============================================================================
# PUSH_ON_GREEN=false: commit stays local, YT_TASK_PUSHED stays no, still 0.
# =============================================================================
reset_fixture
make_fixture_repo 'PUSH_ON_GREEN="false"'
make_bare_origin
export FAKE_CLAUDE_MODE=good
prepare_core
yt_status_init "$RUN" localt || _fail "could not register localt"

yt_run_task "$RUN" localt "A local-only feature"
rc=$?
assert_eq "$rc" 0 "no-push green core returns 0"
assert_eq "$YT_TASK_PUSHED" "no" "YT_TASK_PUSHED is no when PUSH_ON_GREEN=false"
count="$(git -C "$TMP_ROOT/yt-localt" rev-list --count main..feature/localt)"
assert_eq "$count" 1 "commit exists locally"
if git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/localt >/dev/null; then
  _fail "PUSH_ON_GREEN=false must not reach origin"
fi
ok "no-push: committed locally, not pushed"

# =============================================================================
# red gate: agent breaks the suite — returns 1, status failed, no commit,
# worktree left intact for autopsy, reason names the gate.
# =============================================================================
reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=bad
prepare_core
yt_status_init "$RUN" redt || _fail "could not register redt"

yt_run_task "$RUN" redt "Break the gate"
rc=$?
assert_eq "$rc" 1 "red gate returns 1"
assert_eq "$(cat "$RUN/status/redt")" "failed" "red gate leaves status failed"
assert_contains "$YT_TASK_REASON" "gate red" "reason names the red gate"
assert_file_exists "$TMP_ROOT/yt-redt" "failed task's worktree left intact for autopsy"
count="$(git -C "$TMP_ROOT/yt-redt" rev-list --count main..feature/redt)"
assert_eq "$count" 0 "no commit on a red gate"
if git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/redt >/dev/null; then
  _fail "nothing may reach origin on a red gate"
fi
ok "red: returns 1, failed, no commit, worktree intact"

# =============================================================================
# crash and noop: each a distinct FAILED reason, each returns 1 (never exits).
# =============================================================================
reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=crash
prepare_core
yt_status_init "$RUN" crasht || _fail "could not register crasht"
yt_run_task "$RUN" crasht "Trigger a crash"
rc=$?
assert_eq "$rc" 1 "crash returns 1"
assert_eq "$(cat "$RUN/status/crasht")" "failed" "crash leaves status failed"
assert_contains "$YT_TASK_REASON" "agent exited nonzero" "crash reason names the nonzero exit"

reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=noop
prepare_core
yt_status_init "$RUN" noopt || _fail "could not register noopt"
yt_run_task "$RUN" noopt "A task the agent ignores"
rc=$?
assert_eq "$rc" 1 "noop returns 1"
assert_contains "$YT_TASK_REASON" "agent made no changes" "noop reason names the empty change set"
count="$(git -C "$TMP_ROOT/yt-noopt" rev-list --count main..feature/noopt)"
assert_eq "$count" 0 "noop makes no empty commit"
ok "crash and noop: distinct reasons, both return 1"

# =============================================================================
# stdin seam: the agent is run with </dev/null, so it must NOT inherit the
# caller's stdin — the deliberate, documented change that stopped seed.sh from
# stalling. A probe shim reports what its stdin looked like; feeding the call a
# line that the agent must never see proves the redirect is wired in the core.
# =============================================================================
reset_fixture
STDIN_PROBE="$TMP_ROOT/stdin-probe"
PROBE_SHIM="$TMP_ROOT/stdin-probe-claude"
cat > "$PROBE_SHIM" <<'EOF'
#!/usr/bin/env bash
set -u
# Report whether stdin carried anything. With </dev/null this is an instant EOF;
# without it, the agent would inherit (and could read) the caller's stdin.
if IFS= read -r -t 2 line; then
  printf 'AGENT-STDIN: %s\n' "$line" > "$STDIN_PROBE_FILE"
else
  printf 'AGENT-STDIN: <eof>\n' > "$STDIN_PROBE_FILE"
fi
# Harmless edit so the gate stays green and we exercise the full green path.
mkdir -p src
printf '// stdin-probe edit\n' > "src/probe.js"
echo "stdin-probe: made an edit"
exit 0
EOF
chmod +x "$PROBE_SHIM"

make_fixture_repo "CLAUDE_BIN=\"$PROBE_SHIM\""
make_bare_origin
unset FAKE_CLAUDE_MODE
export STDIN_PROBE_FILE="$STDIN_PROBE"
prepare_core
yt_status_init "$RUN" probe || _fail "could not register probe"

# Give the CALL a real stdin line; the core must shield the agent from it.
yt_run_task "$RUN" probe "prove stdin is /dev/null" < <(printf 'SHOULD-NOT-REACH-AGENT\n')
rc=$?
assert_eq "$rc" 0 "stdin-probe green path returns 0"
assert_eq "$(cat "$STDIN_PROBE")" "AGENT-STDIN: <eof>" "agent saw /dev/null, not the caller's stdin"
unset STDIN_PROBE_FILE
ok "stdin: the agent is shielded from the caller's stdin (</dev/null)"

# =============================================================================
# shared run dir + continue-past-failure: two tasks registered up front in ONE
# caller-created run dir; the core runs each and RETURNS (the script keeps
# going), so a green task and a crashing one both land their status in the same
# run — exactly the batch contract seed.sh could not express.
# =============================================================================
reset_fixture
make_fixture_repo
make_bare_origin
prepare_core
yt_status_init "$RUN" one || _fail "could not register one"
yt_status_init "$RUN" two || _fail "could not register two"

export FAKE_CLAUDE_MODE=good
yt_run_task "$RUN" one "first small feature"; rc1=$?
export FAKE_CLAUDE_MODE=crash
yt_run_task "$RUN" two "second, which crashes"; rc2=$?

assert_eq "$rc1" 0 "first task passed (and the core returned, not exited)"
assert_eq "$rc2" 1 "second task failed (the core returned again — the batch continued)"
assert_eq "$(cat "$RUN/status/one")" "passed" "first task recorded passed"
assert_eq "$(cat "$RUN/status/two")" "failed" "second task recorded failed"
assert_eq "$(count_run_dirs)" 1 "both tasks shared the one run dir the caller created"
ok "batch: two tasks, one run dir, continues past the failure"

echo "task: all cases passed"
