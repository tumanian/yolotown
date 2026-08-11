#!/usr/bin/env bash
# lib/report.sh + the `yolotown status` subcommand. The unit cases build run
# dirs directly through lib/rundir.sh (the real state producer; no git, no
# agent) and assert the rendered fan-in table, its merge/cleanup sections, and
# the PASSED-WITH-WARNING seam. The integration tail drives `yolotown status`
# through real seed runs, proving it reads .yolotown/latest and reports it.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$YOLOTOWN_ROOT/lib/rundir.sh"
. "$YOLOTOWN_ROOT/lib/report.sh"

YOLOTOWN="$YOLOTOWN_ROOT/yolotown"
T="$TMP_ROOT/.yolotown-report"
mkdir -p "$T"

# build_run <run-name> — create a run under $T/.yolotown holding four tasks in
# the four terminal report verdicts (alpha passed, delta passed + a warning,
# beta failed, gamma skipped) and echo the run dir.
build_run() {
  local r
  r="$(yt_run_create "$T/.yolotown" "$1")" || { _fail "yt_run_create $1"; return 1; }
  local n
  for n in alpha beta gamma delta; do yt_status_init "$r" "$n" || _fail "init $n"; done
  yt_status_set "$r" alpha running && yt_status_set "$r" alpha passed || _fail "alpha green"
  yt_status_set "$r" beta running  && yt_status_set "$r" beta failed  || _fail "beta red"
  yt_status_set "$r" gamma skipped || _fail "gamma skipped"
  yt_status_set "$r" delta running && yt_status_set "$r" delta passed || _fail "delta green"
  mkdir -p "$r/warnings"
  printf 'strayed outside predicted lane: touched src/other.js\n' > "$r/warnings/delta"
  printf '%s\n' "$r"
}

# ---- yt_verdict maps every status word (and the warning seam) ---------------
R="$(build_run verdicts)"
assert_eq "$(yt_verdict "$R" alpha)" "PASSED"              "passed -> PASSED"
assert_eq "$(yt_verdict "$R" beta)"  "FAILED"              "failed -> FAILED"
assert_eq "$(yt_verdict "$R" gamma)" "SKIPPED"             "skipped -> SKIPPED"
assert_eq "$(yt_verdict "$R" delta)" "PASSED-WITH-WARNING" "passed + warnings/<task> -> PASSED-WITH-WARNING"
# in-flight words render honestly rather than being hidden.
RUNP="$(yt_run_create "$T/.yolotown" inflight)"
yt_status_init "$RUNP" p; assert_eq "$(yt_verdict "$RUNP" p)" "PENDING" "pending -> PENDING"
yt_status_set "$RUNP" p running; assert_eq "$(yt_verdict "$RUNP" p)" "RUNNING" "running -> RUNNING"
# an unregistered task fails loudly.
if yt_verdict "$R" ghost 2>/dev/null; then _fail "yt_verdict on an unregistered task should fail"; fi
ok "yt_verdict maps status words and the warning seam"

# ---- the warning seam is exactly the warnings/<task> file -------------------
# Without it a green task is PASSED; dropping the file (what the Stage 3 lane
# check does) upgrades the very same status word to PASSED-WITH-WARNING.
RW="$(yt_run_create "$T/.yolotown" warnseam)"
yt_status_init "$RW" solo; yt_status_set "$RW" solo running; yt_status_set "$RW" solo passed
assert_eq "$(yt_verdict "$RW" solo)" "PASSED" "green task is PASSED with no warnings file"
mkdir -p "$RW/warnings"; printf 'lane violation\n' > "$RW/warnings/solo"
assert_eq "$(yt_verdict "$RW" solo)" "PASSED-WITH-WARNING" "the warnings file alone flips the verdict"
ok "warnings/<task> is the only thing that makes PASSED-WITH-WARNING"

# ---- yt_report: the table names every task under its verdict ----------------
OUT="$(yt_report "$R" main feature/ "$T")"
assert_eq "$?" 0 "yt_report on a good run dir exits 0"
assert_contains "$OUT" "run: $R" "report names the run dir"
assert_contains "$OUT" "PASSED"              "table shows PASSED"
assert_contains "$OUT" "FAILED"              "table shows FAILED"
assert_contains "$OUT" "SKIPPED"             "table shows SKIPPED"
assert_contains "$OUT" "PASSED-WITH-WARNING" "table shows PASSED-WITH-WARNING"
assert_contains "$OUT" "alpha" "table lists alpha"
assert_contains "$OUT" "beta"  "table lists beta"
assert_contains "$OUT" "gamma" "table lists gamma"
assert_contains "$OUT" "delta" "table lists delta"
ok "table names every task under its verdict"

# ---- yt_report: log + worktree pointers on the ran tasks --------------------
assert_contains "$OUT" "log=$R/logs/alpha.log"    "passed task shows its log path"
assert_contains "$OUT" "worktree=$T/yt-alpha"     "passed task shows its worktree path"
assert_contains "$OUT" "log=$R/logs/beta.log"     "failed task shows its log path"
assert_contains "$OUT" "worktree=$T/yt-beta"      "failed task shows its worktree path"
assert_contains "$OUT" "warning: strayed outside predicted lane" "PASSED-WITH-WARNING surfaces the warning text"
# a skipped task never got a worktree: no worktree pointer for it.
assert_not_contains "$OUT" "worktree=$T/yt-gamma" "skipped task carries no worktree path"
ok "log/worktree pointers on the ran tasks, none on skipped"

# ---- yt_report: merge commands only for green branches ----------------------
assert_contains "$OUT" "git checkout main && git merge --no-ff feature/alpha" "merge command for the passed branch"
assert_contains "$OUT" "git checkout main && git merge --no-ff feature/delta" "merge command for the passed-with-warning branch"
assert_not_contains "$OUT" "merge --no-ff feature/beta"  "no merge command for a failed branch"
assert_not_contains "$OUT" "merge --no-ff feature/gamma" "no merge command for a skipped branch"
ok "merge commands emitted only for green branches"

# ---- yt_report: cleanup for leftover worktrees, none for the skipped --------
assert_contains "$OUT" "git worktree remove --force $T/yt-alpha" "cleanup removes the passed worktree"
assert_contains "$OUT" "git worktree remove --force $T/yt-beta"  "cleanup removes the failed worktree"
assert_contains "$OUT" "git worktree remove --force $T/yt-delta" "cleanup removes the warned worktree"
assert_contains "$OUT" "git branch -D feature/beta" "cleanup deletes the failed branch"
assert_not_contains "$OUT" "yt-gamma" "no cleanup for a skipped task (it never got a worktree)"
# never auto-merges: the report suggests, it does not run.
assert_contains "$OUT" "never auto-merges" "report states it never auto-merges"
ok "cleanup lists leftover worktrees, skips the never-created one"

# ---- yt_report: the summary tallies the buckets that occurred ---------------
assert_contains "$OUT" "summary: 4 tasks" "summary counts the tasks"
assert_contains "$OUT" "1 passed"               "summary tallies passed"
assert_contains "$OUT" "1 passed-with-warning"  "summary tallies passed-with-warning"
assert_contains "$OUT" "1 failed"               "summary tallies failed"
assert_contains "$OUT" "1 skipped"              "summary tallies skipped"
ok "summary tallies the buckets"

# ---- yt_report: empty run and a broken run dir ------------------------------
EMPTY="$(yt_run_create "$T/.yolotown" empty)"
OUT_EMPTY="$(yt_report "$EMPTY" main feature/ "$T")"
assert_eq "$?" 0 "yt_report on an empty run exits 0"
assert_contains "$OUT_EMPTY" "no tasks registered" "empty run says so plainly"
if yt_report "$T/nonexistent" main feature/ "$T" 2>"$T/err"; then
  _fail "yt_report on a missing run dir should fail"
fi
assert_contains "$(cat "$T/err")" "no run dir" "missing run dir fails loudly"
ok "empty run and missing run dir handled"

# ---- integration: `yolotown status` reports the latest run ------------------
# Real seed on the green path creates a one-task run and points latest at it;
# `yolotown status`, run from inside the repo, must read latest and report it.
export FAKE_CLAUDE_MODE=good
make_fixture_repo
make_bare_origin
run_seed shipit "Ship a small feature and report on it"
assert_eq "$SEED_RC" 0 "seed green run exits 0"

STATUS_OUT="$(cd "$REPO" && "$YOLOTOWN" status 2>&1)"
STATUS_RC=$?
assert_eq "$STATUS_RC" 0 "yolotown status exits 0 after a run"
assert_contains "$STATUS_OUT" "PASSED" "status reports the shipped task as PASSED"
assert_contains "$STATUS_OUT" "shipit" "status names the task"
assert_contains "$STATUS_OUT" "git merge --no-ff feature/shipit" "status emits the merge command"
assert_contains "$STATUS_OUT" "logs/shipit.log" "status points at the task log"
# it read the newest run: the run dir `latest` resolves to. (Compare by the
# run's basename, not a full path — git's toplevel canonicalises symlinks like
# macOS's /var -> /private/var, which $REPO does not.)
LATEST_RUN="$(readlink "$REPO/.yolotown/latest")"
assert_contains "$STATUS_OUT" "run: " "status prints the run dir line"
assert_contains "$STATUS_OUT" "/$LATEST_RUN" "status reports the run that latest points at"
ok "yolotown status reports the latest run"

# ---- integration: status follows latest, and a failed run reports FAILED ----
# A second seed run (crashing agent) becomes the newest run; status must now
# report that failed task, not the earlier green one.
reset_fixture
export FAKE_CLAUDE_MODE=crash
make_fixture_repo
make_bare_origin
run_seed flopit "A task whose agent crashes"
assert_eq "$SEED_RC" 1 "crashing seed run exits 1"

STATUS_OUT="$(cd "$REPO" && "$YOLOTOWN" status 2>&1)"
assert_eq "$?" 0 "yolotown status exits 0 even when the run failed"
assert_contains "$STATUS_OUT" "FAILED" "status reports the crashed task as FAILED"
assert_contains "$STATUS_OUT" "flopit" "status names the failed task"
assert_contains "$STATUS_OUT" "git worktree remove --force" "status emits cleanup for the leftover worktree"
assert_not_contains "$STATUS_OUT" "merge --no-ff feature/flopit" "no merge command for a failed task"
ok "yolotown status follows latest onto the failed run"

# ---- integration: `yolotown status` with no runs fails loudly ---------------
reset_fixture
make_fixture_repo   # a repo, but nothing has run: no .yolotown/latest
NORUN_OUT="$(cd "$REPO" && "$YOLOTOWN" status 2>&1)"
NORUN_RC=$?
[ "$NORUN_RC" -ne 0 ] || _fail "yolotown status with no runs should fail"
assert_contains "$NORUN_OUT" "no runs yet" "status with no runs explains there is nothing to report"
ok "yolotown status with no runs fails loudly"

# ---- the entrypoint rejects unknown commands and takes no status args -------
BAD_OUT="$(cd "$REPO" && "$YOLOTOWN" bogus 2>&1)"; BAD_RC=$?
assert_eq "$BAD_RC" 2 "unknown command exits 2"
assert_contains "$BAD_OUT" "unknown command" "unknown command named"
ARG_OUT="$(cd "$REPO" && "$YOLOTOWN" status extra 2>&1)"; ARG_RC=$?
[ "$ARG_RC" -ne 0 ] || _fail "status with a stray argument should fail"
assert_contains "$ARG_OUT" "takes no arguments" "status rejects stray arguments"
ok "entrypoint rejects unknown commands and stray status args"

echo "report: all cases passed"
