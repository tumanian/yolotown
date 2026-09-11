#!/usr/bin/env bash
# yolotown fan-out: run many tasks at once, never more than N at a time — and
# run an INHERENTLY-COUPLED group in order, never at all at once.
#
# Sourcing this file only defines functions; call yt_fanout to dispatch a batch
# of independent tasks, or yt_fanout_chains to dispatch a mix of independent
# tasks and coupled groups. It layers on the per-task core (lib/task.sh) and the
# run dir (lib/rundir.sh) and adds exactly four things: a bound, a subshell per
# unit of work, containment, and the coupled chain.
#
#   yt_fanout <run-dir> <max> <name> <desc> [<name> <desc> ...]
#     reads the same globals yt_run_task does (BASE_BRANCH, BRANCH_PREFIX,
#     ENV_FILES, TEST_CMD, CLAUDE_BIN, WORKER_MODEL, PUSH_ON_GREEN,
#     INVARIANTS_CONTENT, WORKTREE_PARENT), and needs every <name> already
#     registered pending in <run-dir> by the caller.
#     Returns 0 if every task passed, 1 if any failed.
#
#   yt_fanout_chains <run-dir> <max> <chain> [<chain> ...]
#     the same thing, one step up: the unit of dispatch is a CHAIN rather than a
#     task. A chain is one argument holding "<name><TAB><desc>" lines — exactly
#     yt_parse_tasks' own output format, so a caller slices its parsed backlog
#     into chains without reformatting anything. A one-task chain is an ordinary
#     independent task; a multi-task chain is a coupled group (below). yt_fanout
#     is the thin wrapper that turns <name> <desc> pairs into one-task chains.
#
# THE BOUND. At most <max> workers are in flight at any instant; a slot is
# refilled the moment any worker exits, not at the end of a wave. Rate limits
# are real (SPEC section 4), so the bound is the point of this file, not a
# tuning knob: MAX_PARALLEL (or --parallel N) is honored exactly. A coupled
# group is ONE worker however many tasks it holds, so the bound counts agents in
# flight whether the work is chained or not.
#
# THE COUPLED CHAIN (SPEC.md section 3.1). Conflict detection's third bucket is
# the one place tasks must NOT be parallel: INHERENTLY-COUPLED tasks touch the
# same logic by definition, so running them side by side from a shared base
# produces two branches that each ignore the other's work. A chain instead runs
# its tasks strictly in order, and cuts each one from the PREVIOUS task's branch
# rather than from BASE_BRANCH — so task 2 starts from task 1's result, sees it,
# builds on it, and is gated with it.
#
# The chain stops at its first failure. Everything after a failed task would be
# cut from a branch that does not carry the work it was supposed to build on —
# or does not exist at all — so dispatching it would burn an agent on a
# meaningless job and report a verdict about nothing. Those tasks are never
# started; they go pending -> skipped, which is exactly the state SKIPPED exists
# for, and the fan-in report renders them as such. Other chains are untouched: a
# coupled group's failure is contained to that group, exactly as a single task's
# failure is contained to that task.
#
# WHY SUBSHELLS AND FILES. A worker is `( yt_fanout_chain_worker ... ) &`. A
# subshell cannot hand variables back, so the parent learns nothing from the
# worker's memory — only from the run dir. The worker therefore drives
# status/<task> through lib/rundir.sh's state machine exactly as the serial path
# does, and leaves its outcome in results/<task>. The parent reads both back.
# That is also what makes a fanned out run inspectable mid-flight with `cat`.
#
# CRASH CONTAINMENT. Two failure classes, both contained:
#   - the task fails (agent crash, red gate, failed push): yt_run_task records
#     it and returns nonzero; the worker exits nonzero; nothing else notices
#     (and in a chain, the rest of THAT chain is skipped).
#   - the WORKER dies (SIGKILL, OOM, an interpreter fault): no result record is
#     ever written and status/<task> is stranded at "running". yt_fanout_reconcile
#     detects the missing record when it reaps the pid, forces the task to
#     failed, and synthesizes a result naming the worker's exit code. A chain
#     worker that dies strands its unstarted tasks at "pending" instead; those
#     are skipped, because they never ran.
# Either way the loop keeps dispatching. One worker's death costs one unit.
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

# yt_fanout_worker <run-dir> <name> <desc> [<base-ref>]
#   One task's whole life, meant to be run inside a subshell (directly for an
#   independent task, or by the chain worker for one link of a coupled group).
#   Runs the task through the shared core, then records the outcome for the
#   parent. <base-ref> is what the worktree is cut from, defaulting to
#   BASE_BRANCH. Returns the core's return code (0 passed, 1 failed,
#   2 committed-but-push-failed).
yt_fanout_worker() {
  local run="$1" name="$2" desc="$3" base="${4:-$BASE_BRANCH}" log="$1/logs/$2.log" rc
  # stdout dropped, stderr appended: see LIVE OUTPUT above. The core truncates
  # the log itself; an appending fd always writes at EOF, so nothing is lost.
  yt_run_task "$run" "$name" "$desc" "$base" >/dev/null 2>>"$log"
  rc=$?
  yt_result_set "$run" "$name" "$rc" "$YT_TASK_REASON" >/dev/null 2>&1
  return "$rc"
}

# ---- chains ------------------------------------------------------------------
# A chain is a single argument holding "<name><TAB><desc>" lines. These three
# helpers are the only place that encoding is read, so nothing else has to know
# it.

# yt_chain_names <chain> — print the chain's task names, one per line, in order.
yt_chain_names() {
  local name desc
  while IFS=$'\t' read -r name desc; do
    [ -n "$name" ] || continue
    printf '%s\n' "$name"
  done <<< "${1:-}"
}

# _yt_chain_count <chain> — print how many tasks the chain holds.
_yt_chain_count() {
  local n=0 name
  while IFS= read -r name; do
    [ -n "$name" ] && n=$((n + 1))
  done <<< "$(yt_chain_names "${1:-}")"
  printf '%s\n' "$n"
}

# _yt_chain_label <chain> — print the one-line name of this unit of work for the
# dispatch line: a lone task is itself, a coupled group is its order.
_yt_chain_label() {
  local out="" name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -z "$out" ]; then out="$name"; else out="$out -> $name"; fi
  done <<< "$(yt_chain_names "${1:-}")"
  printf '%s\n' "$out"
}

# _yt_chain_skip <run-dir> <name> <reason>
#   Retire a task the chain never dispatched: pending -> skipped, and the reason
#   into its own log, which is where a run is read from. No result record is
#   written, and that is deliberate: results/<task> records what a worker
#   REPORTED, and nothing ran here. The status word is the verdict, and
#   yt_fanout_reconcile reads it before it ever looks for a result.
_yt_chain_skip() {
  # log is spelled from the positionals, not from run/name: `local` expands all
  # of its assignment words before it assigns any of them, so "$run/logs/$name"
  # here would read the CALLER's variables of those names, not these.
  local run="$1" name="$2" reason="$3" log="$1/logs/$2.log"
  yt_status_set "$run" "$name" skipped >/dev/null 2>&1 || true
  {
    printf 'run: task=%s SKIPPED (never dispatched)\n' "$name"
    printf 'run: skipped: %s\n' "$reason"
  } >> "$log" 2>/dev/null || true
}

# yt_fanout_chain_worker <run-dir> <chain>
#   One chain's whole life, meant to be run inside a subshell. Tasks run in the
#   order the chain lists them, each cut from the previous task's branch (the
#   first from BASE_BRANCH), and the first failure abandons the rest of the
#   chain as SKIPPED. Returns 0 if every task in the chain passed, 1 otherwise.
#   A one-task chain is exactly yt_fanout_worker with nothing around it.
yt_fanout_chain_worker() {
  local run="$1" chain="$2"
  local -a names=() descs=()
  local name desc
  while IFS=$'\t' read -r name desc; do
    [ -n "$name" ] || continue
    names+=("$name"); descs+=("$desc")
  done <<< "$chain"

  local total="${#names[@]}"
  [ "$total" -gt 0 ] || { _yt_fanout_die "empty chain dispatched (no tasks in it)"; return 1; }

  local i=0 rc=0 base="$BASE_BRANCH" failed=""
  while [ "$i" -lt "$total" ]; do
    yt_fanout_worker "$run" "${names[$i]}" "${descs[$i]}" "$base"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      failed="${names[$i]}"
      break
    fi
    # The next task is cut from this one's branch: that IS the rebase.
    base="${BRANCH_PREFIX}${names[$i]}"
    i=$((i + 1))
  done

  [ -n "$failed" ] || return 0

  i=$((i + 1))
  while [ "$i" -lt "$total" ]; do
    _yt_chain_skip "$run" "${names[$i]}" \
      "task \"$failed\" earlier in this coupled group failed; every task after it would have been cut from that failure, so none were dispatched"
    i=$((i + 1))
  done
  return 1
}

# yt_fanout_reconcile <run-dir> <name> <worker-rc>
#   Turn one finished task into a reported outcome, and print the terse
#   per-task block (same wording as the serial path) to stdout and the task log.
#   Returns 0 if the task passed or was skipped, 1 otherwise.
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
  local rc reason st note=""

  # Tasks a coupled chain never started are settled first, because they have no
  # result record BY DESIGN and the killed-worker rule below would otherwise
  # convict a task for not reporting work it was never asked to do. "skipped" is
  # the chain worker's own verdict; "pending" means its chain worker died before
  # reaching this task, which leaves it just as undispatched.
  st="$(yt_status_get "$run" "$name" 2>/dev/null)" || st=""
  case "$st" in
    pending)
      yt_status_set "$run" "$name" skipped >/dev/null 2>&1 || true
      st="skipped"
      note="its coupled group's worker died (worker exit $wrc) before dispatching it"
      _yt_chain_skip "$run" "$name" "$note"
      ;;
    skipped)
      note="an earlier task in its coupled group failed; a task rebased on a failure is meaningless"
      ;;
  esac
  if [ "$st" = "skipped" ]; then
    [ -e "$log" ] || : > "$log" 2>/dev/null
    {
      echo ""
      echo "task $name: SKIPPED ($note)"
      echo "  log:      $log"
    } | tee -a "$log"
    return 0
  fi

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

yt_fanout_chains() {
  local run="${1:-}" max="${2:-}"
  [ $# -ge 3 ] || { _yt_fanout_die "yt_fanout_chains needs <run-dir> <max> then at least one chain"; return 1; }
  shift 2

  if [ -z "$run" ] || [ ! -d "$run/status" ]; then
    _yt_fanout_die "no run dir with a status/ directory at ${run:-<unset>}/status"
    return 1
  fi
  case "$max" in
    ""|*[!0-9]*) _yt_fanout_die "max workers must be a positive integer (got \"$max\")"; return 1 ;;
  esac
  [ "$max" -ge 1 ] || { _yt_fanout_die "max workers must be at least 1 (got \"$max\")"; return 1; }

  local -a chains=("$@")
  local total="${#chains[@]}"

  # An empty chain would be dispatched as a worker with nothing to do and reaped
  # against no tasks: refuse it here, where the caller's own list is still in
  # view, rather than in a subshell that can only complain into a log.
  local i=0
  while [ "$i" -lt "$total" ]; do
    if [ "$(_yt_chain_count "${chains[$i]}")" -eq 0 ]; then
      _yt_fanout_die "chain $((i + 1))/$total holds no tasks (a chain is \"<name><TAB><desc>\" lines, one per task)"
      return 1
    fi
    i=$((i + 1))
  done

  # pid_of[i] is chain i's live worker pid, or "" once it has been reaped (or
  # before it starts). Index-parallel arrays only: no rebuilding, so bash 3.2's
  # empty-array-under-set-u trap never comes up.
  local -a pid_of=()
  i=0
  while [ "$i" -lt "$total" ]; do pid_of+=(""); i=$((i + 1)); done

  local started=0 live=0 completed=0 failures=0 reaped p rc unit name
  while [ "$completed" -lt "$total" ]; do
    # Fill every free slot before waiting on anything.
    while [ "$started" -lt "$total" ] && [ "$live" -lt "$max" ]; do
      if [ "$(_yt_chain_count "${chains[$started]}")" -eq 1 ]; then unit="task"; else unit="coupled group"; fi
      printf 'run: dispatch %s (%s %d/%d, %d/%d workers busy)\n' \
        "$(_yt_chain_label "${chains[$started]}")" "$unit" "$((started + 1))" "$total" "$((live + 1))" "$max"
      ( yt_fanout_chain_worker "$run" "${chains[$started]}" ) &
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
        # One reported outcome per TASK, in chain order, so a coupled group
        # reads top to bottom: what passed, what failed, what was skipped.
        while IFS= read -r name; do
          [ -n "$name" ] || continue
          yt_fanout_reconcile "$run" "$name" "$rc" || failures=$((failures + 1))
        done <<< "$(yt_chain_names "${chains[$i]}")"
      fi
      i=$((i + 1))
    done
    [ "$reaped" -eq 0 ] && sleep "$YT_FANOUT_POLL"
  done

  [ "$failures" -eq 0 ]
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

  # Every pair is its own one-task chain: independent tasks are the degenerate
  # case of the chain scheduler, not a second scheduler beside it. A tab or a
  # newline in either half would forge a chain boundary, so it is refused rather
  # than silently reinterpreted — yt_parse_tasks cannot produce one anyway.
  local -a chains=()
  while [ $# -ge 2 ]; do
    case "$1$2" in
      *"$(printf '\t')"*|*"
"*) _yt_fanout_die "task \"$1\" has a tab or newline in its name or description; a chain is one \"<name><TAB><desc>\" line per task"; return 1 ;;
    esac
    chains+=("$(printf '%s\t%s' "$1" "$2")"); shift 2
  done
  [ $# -eq 0 ] || { _yt_fanout_die "trailing task name \"$1\" with no description (pass <name> <desc> pairs)"; return 1; }
  [ "${#chains[@]}" -gt 0 ] || { _yt_fanout_die "no tasks given"; return 1; }

  yt_fanout_chains "$run" "$max" "${chains[@]}"
}
