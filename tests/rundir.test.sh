#!/usr/bin/env bash
# lib/rundir.sh: run-dir creation, the newest-run `latest` symlink, and the
# per-task status state machine with enforced transitions. State inside a run
# is per task now: status/<task> (a directory, one single-word file per task)
# and logs/<task>.log. The unit cases drive the library directly in a scratch
# dir (no git, no agent); the tail integrates it through a real seed run to
# prove the log moved into the run dir's logs/ and the machine advances on the
# green and red paths.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$YOLOTOWN_ROOT/lib/rundir.sh"

YTDIR="$TMP_ROOT/.yolotown"
mkdir -p "$YTDIR"

# ---- yt_run_create: run dir, empty status/ + logs/, latest symlink ----------
# A run is no longer born with a status file: a run holds many tasks, each
# registered later. So the fresh run dir has empty status/ and logs/ subdirs.
RUN="$(yt_run_create "$YTDIR" 20260810T120000Z)"
assert_eq "$RUN" "$YTDIR/run-20260810T120000Z" "run dir named for the timestamp"
assert_file_exists "$RUN" "run dir created"
[ -d "$RUN/status" ] || _fail "status/ should be a directory, one file per task"
[ -d "$RUN/logs" ]   || _fail "logs/ should be a directory, one file per task"
assert_eq "$(ls -A "$RUN/status")" "" "status/ starts empty (no tasks registered yet)"
assert_file_exists "$YTDIR/latest" "latest symlink created"
assert_eq "$(readlink "$YTDIR/latest")" "run-20260810T120000Z" "latest is a relative symlink to the run"
[ -d "$YTDIR/latest/status" ] || _fail "latest resolves to the run dir (status/ visible through it)"
ok "run dir, empty per-task status/, latest symlink"

# ---- latest always points at the newest run --------------------------------
RUN2="$(yt_run_create "$YTDIR" 20260810T130000Z)"
assert_eq "$(readlink "$YTDIR/latest")" "run-20260810T130000Z" "latest follows the newest run"
assert_file_exists "$RUN" "the older run dir still exists"
ok "latest tracks the newest run"

# ---- a same-timestamp collision never reuses a run dir ----------------------
DUP="$(yt_run_create "$YTDIR" 20260810T120000Z)"
assert_eq "$DUP" "$YTDIR/run-20260810T120000Z-2" "collision gets a -2 suffix"
assert_file_exists "$DUP" "the suffixed run dir was created"
assert_file_exists "$RUN/status" "the original same-ts run dir is untouched"
assert_eq "$(readlink "$YTDIR/latest")" "run-20260810T120000Z-2" "latest points at the fresh collision run"
ok "same-timestamp collision suffixed, not reused"

# ---- default timestamp: a run dir is still created --------------------------
AUTO="$(yt_run_create "$YTDIR")"
[ -d "$AUTO/status" ] || _fail "default-timestamp run dir should have a status/ dir"
case "$AUTO" in
  "$YTDIR"/run-*Z) ;;
  *) _fail "default-timestamp run dir should be named run-<UTC ts>Z, got $AUTO" ;;
esac
ok "default timestamp names a run dir"

# ---- yt_status_init: a registered task is born pending ----------------------
T="$TMP_ROOT/.yolotown-sm"
mkdir -p "$T"
R="$(yt_run_create "$T" born)"
yt_status_init "$R" solo || _fail "yt_status_init should register a task"
assert_file_exists "$R/status/solo" "status/<task> file created"
assert_eq "$(cat "$R/status/solo")" "pending" "new task is born pending"
assert_eq "$(yt_status_get "$R" solo)" "pending" "yt_status_get reads pending"
# re-initialising an already-registered task is refused, status preserved.
yt_status_set "$R" solo running
if yt_status_init "$R" solo 2>"$T/err"; then
  _fail "re-init of an existing task should be refused"
fi
assert_eq "$(yt_status_get "$R" solo)" "running" "refused re-init left the task untouched"
assert_contains "$(cat "$T/err")" "already registered" "re-init error explains the refusal"
ok "yt_status_init registers a task, born pending, once"

# ---- two tasks in one run hold independent states ---------------------------
# The core of per-task state: advancing (or failing to advance) one task never
# touches another registered in the same run.
R="$(yt_run_create "$T" two)"
yt_status_init "$R" alpha || _fail "init alpha"
yt_status_init "$R" beta  || _fail "init beta"
assert_file_exists "$R/status/alpha" "alpha has its own status file"
assert_file_exists "$R/status/beta"  "beta has its own status file"

# advance alpha to running; beta must stay pending.
yt_status_set "$R" alpha running || _fail "alpha pending -> running should be legal"
assert_eq "$(yt_status_get "$R" alpha)" "running" "alpha advanced to running"
assert_eq "$(yt_status_get "$R" beta)"  "pending" "beta stays pending while alpha runs"

# alpha finishes green; beta independently walks the failure path.
yt_status_set "$R" alpha passed  || _fail "alpha running -> passed should be legal"
yt_status_set "$R" beta running  || _fail "beta pending -> running should be legal"
yt_status_set "$R" beta failed   || _fail "beta running -> failed should be legal"
assert_eq "$(yt_status_get "$R" alpha)" "passed" "alpha independently reached passed"
assert_eq "$(yt_status_get "$R" beta)"  "failed" "beta independently reached failed"

# an illegal edge on one task leaves the other untouched.
if yt_status_set "$R" alpha running 2>/dev/null; then
  _fail "passed -> running on alpha should be illegal"
fi
assert_eq "$(yt_status_get "$R" beta)" "failed" "a rejected set on alpha leaves beta untouched"

# status/ holds exactly one file per task.
listed="$(ls "$R/status" | sort | tr '\n' ' ')"
assert_eq "$listed" "alpha beta " "status/ holds one file per task"
ok "two tasks in one run hold independent states"

# ---- state-machine cases: one task per fresh run ---------------------------
# fresh <run-name> — create a run dir under $T with a single task "t" born
# pending, and echo the run dir; keeps each transition case isolated.
fresh() {
  local r
  r="$(yt_run_create "$T" "$1")" || { _fail "yt_run_create $1 failed"; return 1; }
  yt_status_init "$r" t || { _fail "yt_status_init t in $1 failed"; return 1; }
  printf '%s\n' "$r"
}

# ---- legal transitions: pending -> running -> passed ------------------------
R="$(fresh sm-a)"
yt_status_set "$R" t running || _fail "pending -> running should be legal"
assert_eq "$(yt_status_get "$R" t)" "running" "advanced to running"
yt_status_set "$R" t passed || _fail "running -> passed should be legal"
assert_eq "$(yt_status_get "$R" t)" "passed" "advanced to passed"
ok "pending -> running -> passed"

# ---- legal transitions: pending -> running -> failed ------------------------
R="$(fresh sm-b)"
yt_status_set "$R" t running || _fail "pending -> running should be legal"
yt_status_set "$R" t failed  || _fail "running -> failed should be legal"
assert_eq "$(yt_status_get "$R" t)" "failed" "advanced to failed"
ok "pending -> running -> failed"

# ---- legal transition: pending -> skipped -----------------------------------
R="$(fresh sm-c)"
yt_status_set "$R" t skipped || _fail "pending -> skipped should be legal"
assert_eq "$(yt_status_get "$R" t)" "skipped" "advanced to skipped"
ok "pending -> skipped"

# ---- illegal transitions are rejected and leave the status untouched --------
# assert_illegal <run> <task> <target> <msg> — assert the target set is refused
# and the task's status is preserved.
assert_illegal() {
  local run="$1" task="$2" target="$3" msg="$4" before
  before="$(yt_status_get "$run" "$task")"
  if yt_status_set "$run" "$task" "$target" 2>"$T/err"; then
    _fail "$msg: transition \"$before\" -> \"$target\" was accepted but should be illegal"
  fi
  assert_eq "$(yt_status_get "$run" "$task")" "$before" "$msg: status unchanged after refusal"
  assert_contains "$(cat "$T/err")" "illegal transition" "$msg: error names it an illegal transition"
}

# pending may not jump straight to a terminal verdict (must run first).
R="$(fresh ill-1)"
assert_illegal "$R" t passed "pending -> passed"
assert_illegal "$R" t failed "pending -> failed"

# pending -> pending is a no-op, still refused (only declared edges are legal).
assert_illegal "$R" t pending "pending -> pending"

# running may not be skipped, nor rewound to pending.
R="$(fresh ill-2)"; yt_status_set "$R" t running
assert_illegal "$R" t skipped "running -> skipped"
assert_illegal "$R" t pending "running -> pending"
assert_illegal "$R" t running "running -> running"

# terminal states have no outgoing edges.
R="$(fresh ill-3)"; yt_status_set "$R" t running; yt_status_set "$R" t passed
assert_illegal "$R" t running "passed -> running"
assert_illegal "$R" t failed  "passed -> failed"

R="$(fresh ill-4)"; yt_status_set "$R" t running; yt_status_set "$R" t failed
assert_illegal "$R" t running "failed -> running"
assert_illegal "$R" t passed  "failed -> passed"

R="$(fresh ill-5)"; yt_status_set "$R" t skipped
assert_illegal "$R" t running "skipped -> running"
ok "illegal transitions rejected, status preserved"

# ---- unknown target status is refused ---------------------------------------
R="$(fresh unk-1)"
if yt_status_set "$R" t bananas 2>"$T/err"; then
  _fail "an unknown status should be refused"
fi
assert_eq "$(yt_status_get "$R" t)" "pending" "unknown status left the task untouched"
assert_contains "$(cat "$T/err")" "unknown status" "error flags the unknown status"
assert_contains "$(cat "$T/err")" "bananas" "error quotes the offending status"
ok "unknown status refused"

# ---- get / set on a missing run dir fail loudly -----------------------------
if yt_status_get "$T/does-not-exist" t 2>/dev/null; then
  _fail "yt_status_get on a missing run dir should fail"
fi
if yt_status_set "$T/does-not-exist" t running 2>/dev/null; then
  _fail "yt_status_set on a missing run dir should fail"
fi
ok "missing run dir fails loudly"

# ---- get / set on an unregistered task fail loudly --------------------------
# The run dir exists, but the task was never yt_status_init'd.
R="$(yt_run_create "$T" ghost-run)"
if yt_status_get "$R" ghost 2>/dev/null; then
  _fail "yt_status_get on an unregistered task should fail"
fi
if yt_status_set "$R" ghost running 2>/dev/null; then
  _fail "yt_status_set on an unregistered task should fail"
fi
ok "unregistered task fails loudly"

# ---- integration: a green seed run moves its log into the run dir -----------
# Real seed, fake agent. Proves the run dir owns the log bytes under logs/, the
# task's machine ends at passed under status/<task>, latest points at the run,
# and the logs/ discoverability name still resolves.
export FAKE_CLAUDE_MODE=good
make_fixture_repo
make_bare_origin
run_seed run-green "Exercise the run dir on the green path"
assert_eq "$SEED_RC" 0 "green seed run exits 0"

RUN_GREEN="$(ls -d "$REPO"/.yolotown/run-*/)"
assert_file_exists "$RUN_GREEN" "seed created a run dir"
assert_file_exists "${RUN_GREEN}status/run-green" "the task has its own status file"
assert_eq "$(cat "${RUN_GREEN}status/run-green")" "passed" "task ended in passed"
assert_file_exists "${RUN_GREEN}logs/run-green.log" "the log's bytes live in the run dir's logs/"
assert_contains "$(cat "${RUN_GREEN}logs/run-green.log")" "created src/feature.js" "run-dir log captured agent output"
assert_contains "$SEED_OUT" "/.yolotown/run-" "report points at the run dir"

# the logs/ path is a symlink into the run dir (discoverable by name).
LOGLINK="$(ls "$REPO"/.yolotown/logs/run-green-*.log)"
[ -L "$LOGLINK" ] || _fail "logs/<name>-<ts>.log should be a symlink into the run dir"
assert_contains "$(cat "$LOGLINK")" "created src/feature.js" "logs/ symlink resolves to the run-dir log"

# latest points at this newest run.
assert_eq "$(readlink "$REPO/.yolotown/latest")" "$(basename "${RUN_GREEN%/}")" "latest points at the run"
ok "green seed run: log in run dir logs/, task status passed, latest set"

# ---- integration: a crashing agent lands the task at failed -----------------
reset_fixture
export FAKE_CLAUDE_MODE=crash
make_fixture_repo
make_bare_origin
run_seed run-red "Exercise the run dir on the failure path"
assert_eq "$SEED_RC" 1 "crashing seed run exits 1"

RUN_RED="$(ls -d "$REPO"/.yolotown/run-*/)"
assert_eq "$(cat "${RUN_RED}status/run-red")" "failed" "task ended in failed"
assert_contains "$(cat "${RUN_RED}logs/run-red.log")" "simulated agent crash" "run-dir log captured the crash"
ok "failed seed run: task status failed"

echo "rundir: all cases passed"
