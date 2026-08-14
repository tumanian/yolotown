#!/usr/bin/env bash
# yolotown run directories: each run gets a flat-file home under .yolotown/,
# named by the UTC time it was created. State inside a run is per task, not
# per run: status/<task> holds a single-word status, logs/<task>.log holds
# that task's log, and results/<task> holds the outcome record a finished
# worker leaves behind. A `latest` symlink always points at the newest run.
#
# Sourcing this file only defines functions; call yt_run_create to make a run,
# yt_status_init to register a task in it (born pending), yt_status_get /
# yt_status_set to drive that task's state machine, and yt_result_set /
# yt_result_get for the outcome record.
#
# Status state machine — every task is born "pending" and moves through exactly
# the edges below; every other transition (including a no-op same-state set) is
# rejected loudly:
#
#     pending ──▶ running ──▶ passed
#        │           └──────▶ failed
#        └──────────────────▶ skipped
#
#   pending  registered, not yet started
#   running  the agent / gate is in flight
#   passed   terminal: the task succeeded
#   failed   terminal: the task broke
#   skipped  terminal: the task was deliberately not started
#
# Terminal states have no outgoing edges. A task reaches "passed" only by way
# of "running" — you cannot pass something that never ran. Tasks in the same
# run hold independent states: advancing one never touches another.

# Error prefix; a CLI entrypoint can set YT_PROG to its own name.
: "${YT_PROG:=yolotown}"

_yt_run_die() { printf '%s: run: %s\n' "$YT_PROG" "$*" >&2; return 1; }

# _yt_status_known <status> — 0 if <status> is one of the five run states.
_yt_status_known() {
  case "$1" in
    pending|running|passed|failed|skipped) return 0 ;;
    *) return 1 ;;
  esac
}

# _yt_status_legal <from> <to> — 0 if <from> ─▶ <to> is an allowed edge.
_yt_status_legal() {
  case "$1:$2" in
    pending:running|pending:skipped|running:passed|running:failed) return 0 ;;
    *) return 1 ;;
  esac
}

# _yt_status_next <from> — print the legal next states for a good error message.
_yt_status_next() {
  case "$1" in
    pending) printf 'running, skipped' ;;
    running) printf 'passed, failed' ;;
    *) printf '(none: %s is terminal)' "$1" ;;
  esac
}

# _yt_task_file <run-dir> <task> — print the path to <task>'s status file,
#   validating the run dir and the task name. Prints nothing and fails (with a
#   message on stderr) if the run dir has no status/ directory or the task name
#   is empty or contains a slash. Does NOT require the file to exist; callers
#   check that themselves, as init and get/set want opposite answers.
_yt_task_file() {
  local dir="$1" task="$2"
  if [ -z "$dir" ] || [ ! -d "$dir/status" ]; then
    _yt_run_die "no run dir with a status/ directory at ${dir:-<unset>}/status"
    return 1
  fi
  if [ -z "$task" ]; then
    _yt_run_die "no task name given"
    return 1
  fi
  case "$task" in
    */*|.|..) _yt_run_die "invalid task name \"$task\" (must not contain \"/\")"; return 1 ;;
  esac
  printf '%s\n' "$dir/status/$task"
}

# yt_run_create <yolotown-dir> [timestamp]
#   Make <yolotown-dir>/run-<ts>/ with empty status/, logs/ and results/
#   subdirs, repoint <yolotown-dir>/latest at it, and print the run dir path.
#   All three are created up front so the run dir's shape is the same whether
#   its tasks ran serially or fanned out. No task status is
#   seeded here — a run holds many tasks, each registered later via
#   yt_status_init. <ts> defaults to the current UTC time (YYYYMMDDTHHMMSSZ). A
#   same-<ts> collision gets a -2, -3, ... suffix, so a run dir is never reused.
yt_run_create() {
  local ytdir="$1" ts="${2:-}"
  [ -n "$ytdir" ] || { _yt_run_die "yt_run_create: no .yolotown dir given"; return 1; }
  [ -n "$ts" ] || ts="$(date -u +%Y%m%dT%H%M%SZ)"

  mkdir -p "$ytdir" || { _yt_run_die "cannot create directory $ytdir"; return 1; }

  local base="run-$ts" dir="$ytdir/run-$ts" n=1
  while [ -e "$dir" ]; do
    n=$((n + 1))
    base="run-$ts-$n"
    dir="$ytdir/$base"
  done
  mkdir "$dir" || { _yt_run_die "cannot create run dir $dir"; return 1; }
  mkdir "$dir/status" "$dir/logs" "$dir/results" \
    || { _yt_run_die "cannot create status/, logs/ and results/ under $dir"; return 1; }

  # Relative symlink so .yolotown/ stays relocatable; -n so an existing
  # latest -> dir symlink is replaced, not descended into; -f to overwrite.
  ln -sfn "$base" "$ytdir/latest" \
    || { _yt_run_die "cannot update latest symlink in $ytdir"; return 1; }

  printf '%s\n' "$dir"
}

# yt_status_init <run-dir> <task> — register <task> in this run, born pending.
#   Writes <run-dir>/status/<task> holding "pending". Refuses (nonzero) to
#   clobber a task already registered in this run: a task is initialised once.
yt_status_init() {
  local dir="$1" task="$2" f
  f="$(_yt_task_file "$dir" "$task")" || return 1
  if [ -e "$f" ]; then
    _yt_run_die "yt_status_init: task \"$task\" already registered in $dir (status is \"$(cat "$f")\")"
    return 1
  fi
  printf 'pending\n' > "$f" \
    || { _yt_run_die "cannot write status for task \"$task\" in $dir"; return 1; }
}

# yt_status_get <run-dir> <task> — print <task>'s current status.
yt_status_get() {
  local dir="$1" task="$2" f
  f="$(_yt_task_file "$dir" "$task")" || return 1
  if [ ! -f "$f" ]; then
    _yt_run_die "yt_status_get: task \"$task\" not registered in $dir (no status/$task)"
    return 1
  fi
  cat "$f"
}

# yt_status_set <run-dir> <task> <new-status> — enforce the transition for
#   <task>, then write it. Rejects (nonzero, status left untouched) an
#   unregistered task, an unknown target status, or an illegal edge, naming
#   what was refused and the legal next states.
yt_status_set() {
  local dir="$1" task="$2" to="$3" f from
  f="$(_yt_task_file "$dir" "$task")" || return 1
  if [ ! -f "$f" ]; then
    _yt_run_die "yt_status_set: task \"$task\" not registered in $dir (no status/$task)"
    return 1
  fi
  if ! _yt_status_known "$to"; then
    _yt_run_die "unknown status \"$to\" (valid: pending running passed failed skipped)"
    return 1
  fi
  from="$(cat "$f")"
  if ! _yt_status_legal "$from" "$to"; then
    _yt_run_die "illegal transition \"$from\" -> \"$to\" for task \"$task\" in $dir (legal next from \"$from\": $(_yt_status_next "$from"))"
    return 1
  fi
  printf '%s\n' "$to" > "$f"
}

# ---- per-task result records -------------------------------------------------
# status/<task> answers "what state is this task in"; results/<task> answers
# "what did its worker actually report". The status word is enough for a serial
# run, where the caller keeps the outcome in its own shell variables. A fanned
# out worker runs in a subshell and cannot hand variables back to the parent, so
# it leaves the outcome here instead — two key=value lines, greppable and
# cat-able like everything else in a run dir:
#
#     rc=1
#     reason=agent exited nonzero (1)
#
# rc is the task's exit code (0 passed, nonzero failed) and reason is a
# single-line human explanation, empty on success. The record's ABSENCE is
# itself a signal: a worker that was killed never wrote one, which is how the
# fan-out reaper tells "failed" from "died" (see lib/fanout.sh).

# _yt_result_file <run-dir> <task> — print the path to <task>'s result file,
#   validating the run dir (must have results/) and the task name, exactly as
#   _yt_task_file does for status/. Does NOT require the file to exist.
_yt_result_file() {
  local dir="$1" task="$2"
  if [ -z "$dir" ] || [ ! -d "$dir/results" ]; then
    _yt_run_die "no run dir with a results/ directory at ${dir:-<unset>}/results"
    return 1
  fi
  if [ -z "$task" ]; then
    _yt_run_die "no task name given"
    return 1
  fi
  case "$task" in
    */*|.|..) _yt_run_die "invalid task name \"$task\" (must not contain \"/\")"; return 1 ;;
  esac
  printf '%s\n' "$dir/results/$task"
}

# yt_result_set <run-dir> <task> <rc> [reason]
#   Record <task>'s outcome. <rc> must be a non-negative integer; <reason> is
#   flattened to one line (newlines and tabs become spaces) so the record stays
#   two lines exactly. Overwrites any earlier record for the task: the last
#   word on a task is the one that counts.
yt_result_set() {
  local dir="$1" task="$2" rc="$3" reason="${4:-}" f
  f="$(_yt_result_file "$dir" "$task")" || return 1
  case "$rc" in
    ""|*[!0-9]*) _yt_run_die "yt_result_set: rc must be a non-negative integer (got \"$rc\") for task \"$task\""; return 1 ;;
  esac
  reason="$(printf '%s' "$reason" | tr '\n\t' '  ')"
  printf 'rc=%s\nreason=%s\n' "$rc" "$reason" > "$f" \
    || { _yt_run_die "cannot write result for task \"$task\" in $dir"; return 1; }
}

# yt_result_get <run-dir> <task>
#   Load <task>'s result into YT_RESULT_RC and YT_RESULT_REASON and return 0.
#   Returns 1 with NO message when the task has no record — absence is an
#   expected answer here (an unfinished or killed worker), not an error — and
#   leaves the two globals empty so a caller cannot read a stale outcome.
yt_result_get() {
  local dir="$1" task="$2" f line
  YT_RESULT_RC=""
  YT_RESULT_REASON=""
  f="$(_yt_result_file "$dir" "$task" 2>/dev/null)" || return 1
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      rc=*)     YT_RESULT_RC="${line#rc=}" ;;
      reason=*) YT_RESULT_REASON="${line#reason=}" ;;
    esac
  done < "$f"
  # A record without a usable rc is a corrupt record, not a result.
  case "$YT_RESULT_RC" in
    ""|*[!0-9]*) YT_RESULT_RC=""; YT_RESULT_REASON=""; return 1 ;;
  esac
  return 0
}
