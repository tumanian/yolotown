#!/usr/bin/env bash
# Fan-out: bounded parallel workers (MAX_PARALLEL, --parallel N, --serial),
# per-worker run-dir state, and crash containment.
#
# The concurrency bound is proved, not assumed. The agent shim below is a
# stopwatch: every invocation registers itself in a shared inflight/ directory,
# samples how many agents are in flight (its own included) every 50ms while it
# holds, and deregisters on the way out. The maximum sample across a whole run
# IS the peak concurrency yolotown allowed. Two directions matter and both are
# asserted: the peak never EXCEEDS the bound (that's the rate-limit promise),
# and it actually REACHES it (otherwise "bounded" could be satisfied by a
# serial loop). To make reaching it deterministic rather than a race with the
# clock, a worker holds until it sees PROBE_EXPECT agents in flight (or times
# out) — so a correct implementation converges in milliseconds and a broken one
# still records the over-bound peak it produced.
#
# Everything else is real: real worktrees, real concurrent pushes to a real
# bare origin, a real gate per worker.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

YOLOTOWN="$YOLOTOWN_ROOT/yolotown"

# run_yt <args...> — invoke the entrypoint from the fixture repo root with
# stdin from /dev/null; sets YT_OUT and YT_RC.
run_yt() {
  YT_OUT="$(cd "$REPO" && "$YOLOTOWN" "$@" </dev/null 2>&1)"
  YT_RC=$?
}

latest_run() { printf '%s\n' "$REPO/.yolotown/$(readlink "$REPO/.yolotown/latest")"; }

# ---- the concurrency-probe agent shim ---------------------------------------
SHIM="$TMP_ROOT/probe-claude"
cat > "$SHIM" <<'SHIM_EOF'
#!/usr/bin/env bash
# Agent shim that measures concurrency. Answers the reachability probe like
# tests/fake-claude does, then: register in PROBE_DIR/inflight, sample the
# in-flight count into PROBE_DIR/samples every tick, deregister, and finally
# behave like fake-claude's "good" mode (an edit that keeps the gate green) —
# or crash, if the prompt asks for it.
set -u
for _a in "$@"; do
  case "$_a" in *yolotown-agent-reachability-probe*) echo "ok"; exit 0 ;; esac
done

DIR="${PROBE_DIR:?probe shim needs PROBE_DIR}"
mkdir -p "$DIR/inflight"
ME="$DIR/inflight/$$"
: > "$ME"

# Hold, sampling every tick. Release once PROBE_EXPECT agents are in flight,
# but never before PROBE_MIN_TICKS samples: a worker that released instantly
# could slip past an over-bound burst without ever observing it.
expect="${PROBE_EXPECT:-1}"
min_ticks="${PROBE_MIN_TICKS:-3}"
max_ticks="${PROBE_MAX_TICKS:-40}"
tick=0
while [ "$tick" -lt "$max_ticks" ]; do
  n="$(ls "$DIR/inflight" | wc -l | tr -d ' ')"
  printf '%s\n' "$n" >> "$DIR/samples"
  tick=$((tick + 1))
  [ "$tick" -ge "$min_ticks" ] && [ "$n" -ge "$expect" ] && break
  sleep 0.05
done
rm -f "$ME"

for _a in "$@"; do
  case "$_a" in *crash-me*) echo "fatal: probe shim crash requested" >&2; exit 1 ;; esac
done

mkdir -p src
printf '// added by the probe shim (%s)\n' "$$" > "src/probe-$$.js"
echo "probe shim: held then edited"
exit 0
SHIM_EOF
chmod +x "$SHIM"

# probe_reset <label> — a fresh, empty measurement dir for one run.
probe_reset() {
  export PROBE_DIR="$TMP_ROOT/probe-$1"
  rm -rf "$PROBE_DIR"
  mkdir -p "$PROBE_DIR/inflight"
  : > "$PROBE_DIR/samples"
}

# probe_peak — the largest in-flight count any agent observed during the run.
probe_peak() {
  local peak
  peak="$(LC_ALL=C sort -n "$PROBE_DIR/samples" 2>/dev/null | tail -1)"
  printf '%s\n' "${peak:-0}"
}

# probe_fixture <n-tasks> [extra conf lines...] — fixture repo + bare origin
# wired to the probe shim, plus a backlog of <n-tasks> trivial tasks named
# t1..tN. Any task whose number is listed in CRASH_TASKS gets a "crash-me"
# description, which the shim turns into a crashed agent.
probe_fixture() {
  local n="$1"; shift
  make_fixture_repo "CLAUDE_BIN=\"$SHIM\"" "$@"
  make_bare_origin
  local i=1
  : > "$REPO/backlog.txt"
  while [ "$i" -le "$n" ]; do
    case " ${CRASH_TASKS:-} " in
      *" $i "*) printf 't%d | please crash-me on task %d\n' "$i" "$i" >> "$REPO/backlog.txt" ;;
      *)        printf 't%d | small feature number %d\n'    "$i" "$i" >> "$REPO/backlog.txt" ;;
    esac
    i=$((i + 1))
  done
}

# =============================================================================
# --parallel 2: the peak is exactly 2 — never more (the bound), never less
# (real parallelism), across three waves of a six-task backlog
# =============================================================================
probe_reset two
export PROBE_EXPECT=2
CRASH_TASKS="" probe_fixture 6

run_yt run --parallel 2 backlog.txt
assert_eq "$YT_RC" 0 "a six-task all-green fan-out exits 0"
assert_eq "$(probe_peak)" 2 "--parallel 2 held exactly two agents in flight at the peak"
assert_contains "$YT_OUT" "parallel: up to 2 workers" "run announces the bound it is honoring"

RUN="$(latest_run)"
nruns="$(ls -1d "$REPO"/.yolotown/run-* | wc -l | tr -d ' ')"
assert_eq "$nruns" 1 "the whole fan-out lands in one run dir"

i=1
while [ "$i" -le 6 ]; do
  assert_eq "$(cat "$RUN/status/t$i")" "passed" "t$i reached passed"
  assert_file_exists "$RUN/logs/t$i.log"    "t$i got its own log"
  assert_file_exists "$RUN/results/t$i"     "t$i got its own per-worker result record"
  assert_contains "$(cat "$RUN/results/t$i")" "rc=0" "t$i's worker recorded a passing rc"
  assert_contains "$(cat "$RUN/logs/t$i.log")" "run: task=t$i" "t$i's log is its own, not another worker's"
  assert_contains "$(cat "$RUN/logs/t$i.log")" "probe shim: held then edited" "t$i's agent output landed in its log"
  git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/feature/t$i" >/dev/null \
    || _fail "t$i should have been pushed to origin"
  i=$((i + 1))
done

# Parallel workers do not stream to the terminal (N of them would interleave
# into noise); the log above proves nothing was lost.
assert_not_contains "$YT_OUT" "probe shim: held then edited" "parallel workers keep agent output out of the terminal"
assert_contains "$YT_OUT" "summary: 6 tasks" "the fan-in report covers the whole batch"
assert_contains "$YT_OUT" "6 passed" "the fan-in report tallies every pass"
assert_contains "$YT_OUT" "git merge --no-ff feature/t6" "the fan-in report emits merge commands"

assert_eq "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" "main" "base branch unchanged by a fan-out"
[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] || _fail "fan-out left the base tree dirty"
ok "--parallel 2: peak concurrency exactly 2, six tasks shipped, one run dir"

# =============================================================================
# high fan-out: eight workers at once, all shipping — the end-to-end shape that
# exposed the worktree race. `git worktree add` walks .git/worktrees/* and used
# to die reading a sibling another worker was still writing ("failed to read
# .git/worktrees/yt-tN/commondir"), losing a task for no reason of its own;
# lib/task.sh serializes creation now. Measured with the lock disabled, that
# race fires in roughly a third of eight-wide runs, so THIS case is coverage,
# not the guard: the lock's contract is pinned deterministically by the unit
# cases right below it.
# =============================================================================
reset_fixture
probe_reset eight
export PROBE_EXPECT=8
CRASH_TASKS="" probe_fixture 8

run_yt run --parallel 8 backlog.txt
assert_eq "$YT_RC" 0 "eight concurrent workers all shipped"
assert_eq "$(probe_peak)" 8 "the bound scales: eight agents in flight at the peak"
assert_not_contains "$YT_OUT" "git worktree add failed" "no worker lost its worktree to a concurrent add"

RUN="$(latest_run)"
i=1
while [ "$i" -le 8 ]; do
  assert_eq "$(cat "$RUN/status/t$i")" "passed" "t$i survived an eight-wide fan-out"
  assert_not_contains "$(cat "$RUN/logs/t$i.log")" "commondir" "t$i's worktree was created without tripping over a sibling"
  git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/feature/t$i" >/dev/null \
    || _fail "t$i should have been pushed by the eight-wide fan-out"
  i=$((i + 1))
done
assert_contains "$YT_OUT" "8 passed" "every one of the eight tasks passed"
assert_file_missing "$REPO/.yolotown/worktree.lock" "the worktree lock is released, not leaked"
ok "high fan-out: eight concurrent workers, no worktree race, all shipped"

# ---- the worktree lock itself: exclusion, takeover, and what it won't steal --
# Driven directly against lib/task.sh: these are the states a run cannot be
# made to reach on demand.
. "$YOLOTOWN_ROOT/lib/task.sh"
LOCK="$TMP_ROOT/wt.lock"

rm -rf "$LOCK"
_yt_wt_lock "$LOCK" || _fail "an uncontended lock should be acquired"
assert_eq "$(cat "$LOCK/pid")" "$$" "the holder stamps its own pid in the lock"
# A second acquirer must not get in while this shell (a live pid) holds it.
if env YT_WT_LOCK_TIMEOUT_TICKS=4 bash -c '. "$1/lib/task.sh"; _yt_wt_lock "$2"' _ "$YOLOTOWN_ROOT" "$LOCK"; then
  _fail "a lock held by a live process must not be acquired by a second worker"
fi
_yt_wt_unlock "$LOCK"
assert_file_missing "$LOCK" "releasing removes the lock"
_yt_wt_lock "$LOCK" || _fail "a released lock should be acquirable again"
_yt_wt_unlock "$LOCK"

# A lock held by a DEAD pid is taken over: one killed worker must not poison
# every task behind it — that contagion is the whole thing fan-out prevents.
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null
rm -rf "$LOCK"; mkdir "$LOCK"; printf '%s\n' "$DEAD" > "$LOCK/pid"
_yt_wt_lock "$LOCK" || _fail "a lock whose holder is dead must be taken over"
assert_eq "$(cat "$LOCK/pid")" "$$" "the takeover stamps the new holder"
_yt_wt_unlock "$LOCK"

# But a lock with no pid yet is NOT stolen: that is the instant between a real
# holder's mkdir and its pid write, and stealing it would put two workers in
# the critical section at once.
rm -rf "$LOCK"; mkdir "$LOCK"
if env YT_WT_LOCK_TIMEOUT_TICKS=4 bash -c '. "$1/lib/task.sh"; _yt_wt_lock "$2"' _ "$YOLOTOWN_ROOT" "$LOCK"; then
  _fail "a lock with no pid stamp yet must never be broken"
fi
rm -rf "$LOCK"
ok "worktree lock: exclusive, taken over only from a dead holder, never stolen unstamped"

# =============================================================================
# MAX_PARALLEL from .yolotown.conf is the default bound (no flag given)
# =============================================================================
reset_fixture
probe_reset conf
export PROBE_EXPECT=3
CRASH_TASKS="" probe_fixture 6 'MAX_PARALLEL="3"'

run_yt run backlog.txt
assert_eq "$YT_RC" 0 "a run honoring MAX_PARALLEL exits 0"
assert_eq "$(probe_peak)" 3 "MAX_PARALLEL=3 held exactly three agents in flight at the peak"
assert_contains "$YT_OUT" "parallel: up to 3 workers" "the conf's bound is the one announced"
assert_contains "$YT_OUT" "6 passed" "every task still shipped"
ok "MAX_PARALLEL: the conf sets the default bound"

# =============================================================================
# --serial: exactly one agent in flight, ever — and output streams live
# =============================================================================
reset_fixture
probe_reset serial
export PROBE_EXPECT=1
CRASH_TASKS="" probe_fixture 4 'MAX_PARALLEL="4"'

run_yt run --serial backlog.txt
assert_eq "$YT_RC" 0 "the serial fallback exits 0"
assert_eq "$(probe_peak)" 1 "--serial never had two agents in flight, even with MAX_PARALLEL=4"
assert_contains "$YT_OUT" "serial: one at a time" "run announces the serial fallback"
assert_contains "$YT_OUT" "probe shim: held then edited" "the serial fallback streams agent output live"
RUN="$(latest_run)"
assert_eq "$(cat "$RUN/status/t4")" "passed" "the last serial task still passed"
ok "--serial: one agent at a time, output streamed live"

# =============================================================================
# --parallel 1 overrides a higher MAX_PARALLEL (the flag wins over the conf)
# =============================================================================
reset_fixture
probe_reset one
export PROBE_EXPECT=1
CRASH_TASKS="" probe_fixture 3 'MAX_PARALLEL="3"'

run_yt run --parallel 1 backlog.txt
assert_eq "$YT_RC" 0 "--parallel 1 exits 0"
assert_eq "$(probe_peak)" 1 "--parallel 1 beat MAX_PARALLEL=3: never two in flight"
ok "--parallel N overrides MAX_PARALLEL"

# =============================================================================
# crash containment: a crashing worker kills its own task and nothing else
# =============================================================================
reset_fixture
probe_reset crash
export PROBE_EXPECT=2
CRASH_TASKS="2 3" probe_fixture 4

run_yt run --parallel 2 backlog.txt
[ "$YT_RC" -ne 0 ] || _fail "a fan-out with failed tasks must exit nonzero"
assert_eq "$(probe_peak)" 2 "the bound held even while workers were crashing"

RUN="$(latest_run)"
assert_eq "$(cat "$RUN/status/t1")" "passed" "t1 passed alongside the crashes"
assert_eq "$(cat "$RUN/status/t2")" "failed" "t2's crashed agent failed its own task"
assert_eq "$(cat "$RUN/status/t3")" "failed" "t3's crashed agent failed its own task"
assert_eq "$(cat "$RUN/status/t4")" "passed" "t4 was still dispatched after two crashes — the run never stopped"
assert_contains "$(cat "$RUN/results/t2")" "agent exited nonzero" "t2's result records the real reason"
assert_contains "$(cat "$RUN/logs/t3.log")" "probe shim crash requested" "t3's agent stderr reached its log"

git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/t1 >/dev/null || _fail "t1 should be pushed"
git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/t4 >/dev/null || _fail "t4 should be pushed"
if git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/t2 >/dev/null; then
  _fail "t2 crashed before commit and must not reach origin"
fi
# Failed tasks keep their worktree for autopsy.
git -C "$REPO" worktree list | grep -q "yt-t2" || _fail "t2's worktree should be left intact"

assert_contains "$YT_OUT" "task t2: FAILED" "the crashed task is reported by name"
assert_contains "$YT_OUT" "summary: 4 tasks" "the report still covers the whole batch"
assert_contains "$YT_OUT" "2 passed" "the report tallies the survivors"
assert_contains "$YT_OUT" "2 failed" "the report tallies the crashes"
ok "crash containment: crashed workers fail alone, the run finishes"

# =============================================================================
# crash containment, the hard case: a worker KILLED before it could record
# anything. Its task is stranded at "running" with no result — the reaper must
# convict it rather than hang, leak a false pass, or take the run down. Driven
# directly against lib/fanout.sh, because a killed worker is precisely what
# cannot be arranged through the agent seam.
# =============================================================================
. "$YOLOTOWN_ROOT/lib/rundir.sh"
. "$YOLOTOWN_ROOT/lib/fanout.sh"

BRANCH_PREFIX="feature/"
WORKTREE_PARENT="$TMP_ROOT/wt"
KILLDIR="$TMP_ROOT/.yolotown-kill"
mkdir -p "$KILLDIR"
KRUN="$(yt_run_create "$KILLDIR" killed)"
yt_status_init "$KRUN" doomed || _fail "could not register the doomed task"
yt_status_set  "$KRUN" doomed running || _fail "could not start the doomed task"

RECON_OUT="$(yt_fanout_reconcile "$KRUN" doomed 137 2>&1)"; RECON_RC=$?
assert_eq "$RECON_RC" 1 "a worker that died is reported as a failure"
assert_eq "$(yt_status_get "$KRUN" doomed)" "failed" "the stranded task is forced out of running"
assert_file_exists "$KRUN/results/doomed" "the reaper synthesizes the missing result record"
assert_contains "$(cat "$KRUN/results/doomed")" "worker died" "the synthesized result says what happened"
assert_contains "$(cat "$KRUN/results/doomed")" "137" "the synthesized result names the worker's exit code"
assert_not_contains "$(cat "$KRUN/results/doomed")" "rc=0" "a killed worker is never recorded as a pass"
assert_contains "$RECON_OUT" "task doomed: FAILED" "the killed worker is reported by name"
assert_contains "$RECON_OUT" "log:" "the report points at the log for autopsy"
assert_contains "$(cat "$KRUN/logs/doomed.log")" "task doomed: FAILED" "the verdict is appended to the task's own log"

# The healthy sibling reaped from the same loop is unaffected: containment
# means the reaper's verdict on one task never touches another.
yt_status_init "$KRUN" healthy || _fail "could not register the healthy task"
yt_status_set  "$KRUN" healthy running || _fail "could not start the healthy task"
yt_result_set  "$KRUN" healthy 0 "" || _fail "could not record the healthy result"
yt_status_set  "$KRUN" healthy passed || _fail "could not pass the healthy task"
yt_fanout_reconcile "$KRUN" healthy 0 >/dev/null 2>&1 || _fail "a passing worker is reported as a pass"
assert_eq "$(yt_status_get "$KRUN" healthy)" "passed" "the healthy task kept its verdict"
assert_eq "$(yt_status_get "$KRUN" doomed)"  "failed" "the doomed task kept its verdict"
ok "crash containment: a killed worker is convicted, not hung on or mistaken for a pass"

# ---- the result record itself: written, read back, and validated ------------
yt_status_init "$KRUN" recorded || _fail "could not register the recorded task"
yt_result_set "$KRUN" recorded 2 "push failed; commit stands
on the branch" || _fail "yt_result_set should accept a valid rc"
yt_result_get "$KRUN" recorded || _fail "yt_result_get should read back a written record"
assert_eq "$YT_RESULT_RC" "2" "the recorded rc reads back"
assert_eq "$YT_RESULT_REASON" "push failed; commit stands on the branch" "a multi-line reason is flattened to one line"
assert_eq "$(wc -l < "$KRUN/results/recorded" | tr -d ' ')" "2" "a result record is exactly two lines"
if yt_result_get "$KRUN" never-ran 2>/dev/null; then
  _fail "yt_result_get must fail for a task with no record"
fi
assert_eq "$YT_RESULT_RC" "" "a missing record leaves no stale rc behind"
if yt_result_set "$KRUN" recorded "boom" 2>/dev/null; then
  _fail "yt_result_set must reject a non-numeric rc"
fi
assert_contains "$(cat "$KRUN/results/recorded")" "rc=2" "a rejected write left the old record intact"
ok "results/<task>: two-line record, flattened reason, absence distinguishable"

# ---- yt_fanout's own argument validation ------------------------------------
if yt_fanout "$KRUN" 0 solo "a task" 2>/dev/null; then _fail "max 0 must be refused"; fi
if yt_fanout "$KRUN" two solo "a task" 2>/dev/null; then _fail "a non-numeric max must be refused"; fi
if yt_fanout "$KRUN" 2 solo 2>/dev/null; then _fail "a name with no description must be refused"; fi
if yt_fanout "$TMP_ROOT/nope" 2 solo "a task" 2>/dev/null; then _fail "a bogus run dir must be refused"; fi
FANOUT_ERR="$(yt_fanout "$KRUN" 0 solo "a task" 2>&1)"
assert_contains "$FANOUT_ERR" "at least 1" "the refusal says what a valid bound is"
ok "yt_fanout: bad bounds, odd pairs and bogus run dirs are refused"

# =============================================================================
# fail fast on a bad bound: from the flag and from the conf
# =============================================================================
reset_fixture
make_fixture_repo
printf 'solo | a task\n' > "$REPO/backlog.txt"

run_yt run --parallel 0 backlog.txt
[ "$YT_RC" -ne 0 ] || _fail "--parallel 0 must be refused"
assert_contains "$YT_OUT" "at least 1" "--parallel 0 is named and explained"
assert_contains "$YT_OUT" "--serial" "the refusal points at the serial fallback"
assert_file_missing "$REPO/.yolotown" "a refused bound creates no run dir"

run_yt run --parallel lots backlog.txt
[ "$YT_RC" -ne 0 ] || _fail "a non-numeric --parallel must be refused"
assert_contains "$YT_OUT" "positive integer" "a non-numeric bound is named"
assert_contains "$YT_OUT" "--parallel 4" "the refusal shows a valid example"

run_yt run --parallel
[ "$YT_RC" -ne 0 ] || _fail "--parallel with no value must be refused"
assert_contains "$YT_OUT" "needs a worker count" "a valueless --parallel is named"

run_yt run --parallel= backlog.txt
[ "$YT_RC" -ne 0 ] || _fail "--parallel= with an empty value must be refused, not silently defaulted"
assert_contains "$YT_OUT" "needs a worker count" "an empty --parallel= is named"

# The =-joined form reads its value from the same place: a bad one is caught
# by the same validation, which is proof the value was parsed at all.
run_yt run --parallel=0 backlog.txt
[ "$YT_RC" -ne 0 ] || _fail "--parallel=0 must be refused like --parallel 0"
assert_contains "$YT_OUT" "at least 1" "the =-joined form's value is parsed and validated"

run_yt run --bogus backlog.txt
[ "$YT_RC" -ne 0 ] || _fail "an unknown run option must be refused"
assert_contains "$YT_OUT" "unknown option" "the unknown option is named"

run_yt run backlog.txt extra.txt
[ "$YT_RC" -ne 0 ] || _fail "two tasks files must be refused"
assert_contains "$YT_OUT" "at most one tasks file" "the second tasks file is refused loudly"
ok "run: bad --parallel values and stray arguments fail fast"

# ---- MAX_PARALLEL validation lives in the config loader ---------------------
# Exercised through the loader directly (no git, no agent), so the refusal is
# attributed to the conf rather than to a run.
load_max_parallel() {
  SEED_OUT="$(cd "$1" && bash -c '
    set -uo pipefail
    . "$1/lib/config.sh"
    yt_load_config
    printf "MAX_PARALLEL=[%s]\n" "$MAX_PARALLEL"
  ' _ "$YOLOTOWN_ROOT" 2>&1)"
  SEED_RC=$?
}

CONFDIR="$TMP_ROOT/maxpar"
rm -rf "$CONFDIR"; mkdir -p "$CONFDIR"
printf 'TEST_CMD="./check.sh"\n' > "$CONFDIR/.yolotown.conf"
load_max_parallel "$CONFDIR"
assert_eq "$SEED_RC" 0 "a conf without MAX_PARALLEL loads"
assert_contains "$SEED_OUT" 'MAX_PARALLEL=[3]' "MAX_PARALLEL defaults to 3"

printf 'TEST_CMD="./check.sh"\nMAX_PARALLEL="8"\n' > "$CONFDIR/.yolotown.conf"
load_max_parallel "$CONFDIR"
assert_eq "$SEED_RC" 0 "an explicit MAX_PARALLEL loads"
assert_contains "$SEED_OUT" 'MAX_PARALLEL=[8]' "MAX_PARALLEL override wins"

printf 'TEST_CMD="./check.sh"\nMAX_PARALLEL="0"\n' > "$CONFDIR/.yolotown.conf"
load_max_parallel "$CONFDIR"
assert_eq "$SEED_RC" 2 "MAX_PARALLEL=0 exits 2"
assert_contains "$SEED_OUT" "MAX_PARALLEL" "the offending key is named"
assert_contains "$SEED_OUT" "at least 1" "the refusal says what a valid bound is"

printf 'TEST_CMD="./check.sh"\nMAX_PARALLEL="many"\n' > "$CONFDIR/.yolotown.conf"
load_max_parallel "$CONFDIR"
assert_eq "$SEED_RC" 2 "a non-numeric MAX_PARALLEL exits 2"
assert_contains "$SEED_OUT" "many" "the offending value is shown"
assert_contains "$SEED_OUT" 'MAX_PARALLEL="3"' "the refusal shows a valid example"
ok "MAX_PARALLEL: defaulted, overridable, and validated by the config loader"

echo "fan-out: all cases passed"
