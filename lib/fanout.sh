#!/usr/bin/env bash
# yolotown fan-out: run many tasks at once, never more than N at a time.
#
# Sourcing this file only defines functions; call yt_fanout to dispatch a batch.
# It layers on the per-task core (lib/task.sh) and the run dir (lib/rundir.sh)
# and adds exactly three things: a bound, a subshell per task, and containment.
#
#   yt_fanout <run-dir> <max> <name> <desc> [<name> <desc> ...]
#     reads the same globals yt_run_task does (BASE_BRANCH, BRANCH_PREFIX,
#     ENV_FILES, TEST_CMD, CLAUDE_BIN, WORKER_MODEL, PUSH_ON_GREEN,
#     INVARIANTS_CONTENT, WORKTREE_PARENT), and needs every <name> already
#     registered pending in <run-dir> by the caller.
#     Returns 0 if every task passed, 1 if any failed.
#
# THE BOUND. At most <max> workers are in flight at any instant; a slot is
# refilled the moment any worker exits, not at the end of a wave. Rate limits
# are real (SPEC section 4), so the bound is the point of this file, not a
# tuning knob: MAX_PARALLEL (or --parallel N) is honored exactly.
#
# WHY SUBSHELLS AND FILES. A worker is `( yt_fanout_worker ... ) &`. A subshell
# cannot hand variables back, so the parent learns nothing from the worker's
# memory — only from the run dir. The worker therefore drives status/<task>
# through lib/rundir.sh's state machine exactly as the serial path does, and
# leaves its outcome in results/<task>. The parent reads both back. That is
# also what makes a fanned out run inspectable mid-flight with `cat`.
#
# CRASH CONTAINMENT. Two failure classes, both contained:
#   - the task fails (agent crash, red gate, failed push): yt_run_task records
#     it and returns nonzero; the worker exits nonzero; nothing else notices.
#   - the WORKER dies (SIGKILL, OOM, an interpreter fault): no result record is
#     ever written and status/<task> is stranded at "running". yt_fanout_reconcile
#     detects the missing record when it reaps the pid, forces the task to
#     failed, and synthesizes a result naming the worker's exit code.
# Either way the loop keeps dispatching. One worker's death costs one task.
#
# LIVE OUTPUT. The serial path tees agent output to the terminal; N workers
# doing that would interleave into noise. A worker's stdout is dropped (every
# line of it is already tee'd into logs/<task>.log by the core) and its stderr
# is appended to that same log, so nothing is lost. The parent prints one line
# per dispatch and the usual terse block per completion.

: "${YT_PROG:=yolotown}"

_yt_fanout_die() { printf '%s: fan-out: %s\n' "$YT_PROG" "$*" >&2; return 1; }

# How long the reaper sleeps between liveness checks. Small enough that a
# freed slot is refilled promptly, large enough that polling costs nothing.
: "${YT_FANOUT_POLL:=0.05}"

# yt_fanout_worker <run-dir> <name> <desc>
#   One worker's whole life, meant to be run inside a subshell. Runs the task
#   through the shared core, then records the outcome for the parent. Returns
#   the core's return code (0 passed, 1 failed, 2 committed-but-push-failed).
yt_fanout_worker() {
  local run="$1" name="$2" desc="$3" log="$1/logs/$2.log" rc
  # stdout dropped, stderr appended: see LIVE OUTPUT above. The core truncates
  # the log itself; an appending fd always writes at EOF, so nothing is lost.
  yt_run_task "$run" "$name" "$desc" >/dev/null 2>>"$log"
  rc=$?
  yt_result_set "$run" "$name" "$rc" "$YT_TASK_REASON" >/dev/null 2>&1
  return "$rc"
}

# yt_fanout_reconcile <run-dir> <name> <worker-rc>
#   Turn one finished worker into a reported outcome, and print the terse
#   per-task block (same wording as the serial path) to stdout and the task log.
#   Returns 0 if the task passed, 1 otherwise.
#
#   This is the crash-containment seam. A worker that recorded a result is
#   simply reported. A worker with NO result never reached its own last line —
#   it was killed — so its task is stranded at "running": force it to failed
#   and synthesize the record, naming the exit code so the log is diagnosable
#   without a rerun. Reads BRANCH_PREFIX and WORKTREE_PARENT for the pointers.
yt_fanout_reconcile() {
  local run="$1" name="$2" wrc="$3"
  local branch="${BRANCH_PREFIX}${name}"
  local wt="$WORKTREE_PARENT/yt-${name}"
  local log="$run/logs/${name}.log"
  local rc reason

  if yt_result_get "$run" "$name"; then
    rc="$YT_RESULT_RC"
    reason="$YT_RESULT_REASON"
  else
    # Never report a killed worker as a pass, whatever the shell reported.
    rc="$wrc"
    case "$rc" in ""|*[!0-9]*|0) rc=1 ;; esac
    reason="worker died without recording a result (worker exit $wrc); marked failed by the fan-out reaper — its worktree, if any, is left for autopsy"
    yt_status_set "$run" "$name" failed >/dev/null 2>&1 || true
    yt_result_set "$run" "$name" "$rc" "$reason" >/dev/null 2>&1 || true
  fi

  [ -e "$log" ] || : > "$log" 2>/dev/null
  if [ "$rc" -eq 0 ]; then
    {
      echo ""
      echo "task $name: PASSED (branch $branch)"
    } | tee -a "$log"
    return 0
  fi
  {
    echo ""
    echo "task $name: FAILED ($reason)"
    echo "  log:      $log"
    echo "  worktree: $wt"
  } | tee -a "$log"
  return 1
}

yt_fanout() {
  local run="${1:-}" max="${2:-}"
  [ $# -ge 2 ] || { _yt_fanout_die "yt_fanout needs <run-dir> <max> then <name> <desc> pairs"; return 1; }
  shift 2

  if [ -z "$run" ] || [ ! -d "$run/status" ]; then
    _yt_fanout_die "no run dir with a status/ directory at ${run:-<unset>}/status"
    return 1
  fi
  case "$max" in
    ""|*[!0-9]*) _yt_fanout_die "max workers must be a positive integer (got \"$max\")"; return 1 ;;
  esac
  [ "$max" -ge 1 ] || { _yt_fanout_die "max workers must be at least 1 (got \"$max\")"; return 1; }

  local -a names=() descs=()
  while [ $# -ge 2 ]; do
    names+=("$1"); descs+=("$2"); shift 2
  done
  [ $# -eq 0 ] || { _yt_fanout_die "trailing task name \"$1\" with no description (pass <name> <desc> pairs)"; return 1; }
  local total="${#names[@]}"
  [ "$total" -gt 0 ] || { _yt_fanout_die "no tasks given"; return 1; }

  # pid_of[i] is task i's live worker pid, or "" once it has been reaped (or
  # before it starts). Index-parallel arrays only: no rebuilding, so bash 3.2's
  # empty-array-under-set-u trap never comes up.
  local -a pid_of=()
  local i=0
  while [ "$i" -lt "$total" ]; do pid_of+=(""); i=$((i + 1)); done

  local started=0 live=0 completed=0 failures=0 reaped p rc
  while [ "$completed" -lt "$total" ]; do
    # Fill every free slot before waiting on anything.
    while [ "$started" -lt "$total" ] && [ "$live" -lt "$max" ]; do
      printf 'run: dispatch %s (task %d/%d, %d/%d workers busy)\n' \
        "${names[$started]}" "$((started + 1))" "$total" "$((live + 1))" "$max"
      ( yt_fanout_worker "$run" "${names[$started]}" "${descs[$started]}" ) &
      pid_of[$started]=$!
      started=$((started + 1))
      live=$((live + 1))
    done

    # Reap everything that has finished. `wait` on an already-exited child
    # still returns its remembered status, so a race between the liveness
    # check and the reap cannot lose an exit code.
    reaped=0
    i=0
    while [ "$i" -lt "$started" ]; do
      p="${pid_of[$i]}"
      if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then
        wait "$p"; rc=$?
        pid_of[$i]=""
        live=$((live - 1))
        completed=$((completed + 1))
        reaped=$((reaped + 1))
        yt_fanout_reconcile "$run" "${names[$i]}" "$rc" || failures=$((failures + 1))
      fi
      i=$((i + 1))
    done
    [ "$reaped" -eq 0 ] && sleep "$YT_FANOUT_POLL"
  done

  [ "$failures" -eq 0 ]
}
