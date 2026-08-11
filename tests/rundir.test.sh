#!/usr/bin/env bash
# lib/rundir.sh: run-dir creation, the newest-run `latest` symlink, and the
# status state machine with enforced transitions. The unit cases drive the
# library directly in a scratch dir (no git, no agent); the tail integrates it
# through a real seed run to prove the log moved into the run dir and the
# machine advances on the green and red paths.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$YOLOTOWN_ROOT/lib/rundir.sh"

YTDIR="$TMP_ROOT/.yolotown"
mkdir -p "$YTDIR"

# ---- yt_run_create: run dir, pending status, latest symlink -----------------
RUN="$(yt_run_create "$YTDIR" 20260810T120000Z)"
assert_eq "$RUN" "$YTDIR/run-20260810T120000Z" "run dir named for the timestamp"
assert_file_exists "$RUN" "run dir created"
assert_file_exists "$RUN/status" "status file created"
assert_eq "$(cat "$RUN/status")" "pending" "new run is born pending"
assert_eq "$(yt_status_get "$RUN")" "pending" "yt_status_get reads pending"
assert_file_exists "$YTDIR/latest" "latest symlink created"
assert_eq "$(readlink "$YTDIR/latest")" "run-20260810T120000Z" "latest is a relative symlink to the run"
assert_eq "$(cat "$YTDIR/latest/status")" "pending" "latest resolves to the run dir"
ok "run dir, pending status, latest symlink"

# ---- latest always points at the newest run --------------------------------
RUN2="$(yt_run_create "$YTDIR" 20260810T130000Z)"
assert_eq "$(readlink "$YTDIR/latest")" "run-20260810T130000Z" "latest follows the newest run"
assert_file_exists "$RUN" "the older run dir still exists"
ok "latest tracks the newest run"

# ---- a same-timestamp collision never reuses a run dir ----------------------
DUP="$(yt_run_create "$YTDIR" 20260810T120000Z)"
assert_eq "$DUP" "$YTDIR/run-20260810T120000Z-2" "collision gets a -2 suffix"
assert_file_exists "$DUP" "the suffixed run dir was created"
assert_eq "$(cat "$RUN/status")" "pending" "the original same-ts run dir is untouched"
assert_eq "$(readlink "$YTDIR/latest")" "run-20260810T120000Z-2" "latest points at the fresh collision run"
ok "same-timestamp collision suffixed, not reused"

# ---- default timestamp: a run dir is still created --------------------------
AUTO="$(yt_run_create "$YTDIR")"
assert_file_exists "$AUTO/status" "default-timestamp run dir created"
case "$AUTO" in
  "$YTDIR"/run-*Z) ;;
  *) _fail "default-timestamp run dir should be named run-<UTC ts>Z, got $AUTO" ;;
esac
ok "default timestamp names a run dir"

# ---- legal transitions: pending -> running -> passed ------------------------
T="$TMP_ROOT/.yolotown-sm"
mkdir -p "$T"
R="$(yt_run_create "$T" run-a)"
yt_status_set "$R" running || _fail "pending -> running should be legal"
assert_eq "$(yt_status_get "$R")" "running" "advanced to running"
yt_status_set "$R" passed || _fail "running -> passed should be legal"
assert_eq "$(yt_status_get "$R")" "passed" "advanced to passed"
ok "pending -> running -> passed"

# ---- legal transitions: pending -> running -> failed ------------------------
R="$(yt_run_create "$T" run-b)"
yt_status_set "$R" running || _fail "pending -> running should be legal"
yt_status_set "$R" failed  || _fail "running -> failed should be legal"
assert_eq "$(yt_status_get "$R")" "failed" "advanced to failed"
ok "pending -> running -> failed"

# ---- legal transition: pending -> skipped -----------------------------------
R="$(yt_run_create "$T" run-c)"
yt_status_set "$R" skipped || _fail "pending -> skipped should be legal"
assert_eq "$(yt_status_get "$R")" "skipped" "advanced to skipped"
ok "pending -> skipped"

# ---- illegal transitions are rejected and leave the status untouched --------
# expect_illegal <from-status-setup...> ::: <target> — builds a fresh run,
# drives it to a starting state, then asserts the target set is refused.
assert_illegal() {
  local run="$1" target="$2" msg="$3" before
  before="$(yt_status_get "$run")"
  if yt_status_set "$run" "$target" 2>"$T/err"; then
    _fail "$msg: transition \"$before\" -> \"$target\" was accepted but should be illegal"
  fi
  assert_eq "$(yt_status_get "$run")" "$before" "$msg: status unchanged after refusal"
  assert_contains "$(cat "$T/err")" "illegal transition" "$msg: error names it an illegal transition"
}

# pending may not jump straight to a terminal verdict (must run first).
R="$(yt_run_create "$T" ill-1)"
assert_illegal "$R" passed "pending -> passed"
assert_illegal "$R" failed "pending -> failed"

# pending -> pending is a no-op, still refused (only declared edges are legal).
assert_illegal "$R" pending "pending -> pending"

# running may not be skipped, nor rewound to pending.
R="$(yt_run_create "$T" ill-2)"; yt_status_set "$R" running
assert_illegal "$R" skipped "running -> skipped"
assert_illegal "$R" pending "running -> pending"
assert_illegal "$R" running "running -> running"

# terminal states have no outgoing edges.
R="$(yt_run_create "$T" ill-3)"; yt_status_set "$R" running; yt_status_set "$R" passed
assert_illegal "$R" running "passed -> running"
assert_illegal "$R" failed  "passed -> failed"

R="$(yt_run_create "$T" ill-4)"; yt_status_set "$R" running; yt_status_set "$R" failed
assert_illegal "$R" running "failed -> running"
assert_illegal "$R" passed  "failed -> passed"

R="$(yt_run_create "$T" ill-5)"; yt_status_set "$R" skipped
assert_illegal "$R" running "skipped -> running"
ok "illegal transitions rejected, status preserved"

# ---- unknown target status is refused ---------------------------------------
R="$(yt_run_create "$T" unk-1)"
if yt_status_set "$R" bananas 2>"$T/err"; then
  _fail "an unknown status should be refused"
fi
assert_eq "$(yt_status_get "$R")" "pending" "unknown status left the run untouched"
assert_contains "$(cat "$T/err")" "unknown status" "error flags the unknown status"
assert_contains "$(cat "$T/err")" "bananas" "error quotes the offending status"
ok "unknown status refused"

# ---- get / set on a missing run dir fail loudly -----------------------------
if yt_status_get "$T/does-not-exist" 2>/dev/null; then
  _fail "yt_status_get on a missing run dir should fail"
fi
if yt_status_set "$T/does-not-exist" running 2>/dev/null; then
  _fail "yt_status_set on a missing run dir should fail"
fi
ok "missing run dir fails loudly"

# ---- integration: a green seed run moves its log into the run dir -----------
# Real seed, fake agent. Proves the run dir owns the log bytes, the machine
# ends at passed, latest points at the run, and the logs/ name still resolves.
export FAKE_CLAUDE_MODE=good
make_fixture_repo
make_bare_origin
run_seed run-green "Exercise the run dir on the green path"
assert_eq "$SEED_RC" 0 "green seed run exits 0"

RUN_GREEN="$(ls -d "$REPO"/.yolotown/run-*/)"
assert_file_exists "$RUN_GREEN" "seed created a run dir"
assert_eq "$(cat "$RUN_GREEN/status")" "passed" "run ended in passed"
assert_file_exists "${RUN_GREEN}run-green.log" "the log's bytes live in the run dir"
assert_contains "$(cat "${RUN_GREEN}run-green.log")" "created src/feature.js" "run-dir log captured agent output"
assert_contains "$SEED_OUT" "/.yolotown/run-" "report points at the run dir"

# the logs/ path is a symlink into the run dir (discoverable by name).
LOGLINK="$(ls "$REPO"/.yolotown/logs/run-green-*.log)"
[ -L "$LOGLINK" ] || _fail "logs/<name>-<ts>.log should be a symlink into the run dir"
assert_contains "$(cat "$LOGLINK")" "created src/feature.js" "logs/ symlink resolves to the run-dir log"

# latest points at this newest run.
assert_eq "$(readlink "$REPO/.yolotown/latest")" "$(basename "${RUN_GREEN%/}")" "latest points at the run"
ok "green seed run: log in run dir, status passed, latest set"

# ---- integration: a crashing agent lands the run at failed ------------------
reset_fixture
export FAKE_CLAUDE_MODE=crash
make_fixture_repo
make_bare_origin
run_seed run-red "Exercise the run dir on the failure path"
assert_eq "$SEED_RC" 1 "crashing seed run exits 1"

RUN_RED="$(ls -d "$REPO"/.yolotown/run-*/)"
assert_eq "$(cat "$RUN_RED/status")" "failed" "run ended in failed"
assert_contains "$(cat "${RUN_RED}run-red.log")" "simulated agent crash" "run-dir log captured the crash"
ok "failed seed run: status failed"

echo "rundir: all cases passed"
