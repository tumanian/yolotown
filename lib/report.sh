#!/usr/bin/env bash
# yolotown fan-in report: render a per-task table for a run dir, plus the
# ready-to-run merge commands for its green branches and the cleanup commands
# for its leftover worktrees. Consumed by the `status` subcommand today and by
# the fan-out stage's end-of-run report later.
#
# Sourcing this file only defines functions; call yt_report to render.
#
# The report is a pure reader of a run dir's flat state plus a little config.
# It reads exactly two things under the run dir:
#
#   status/<task>    the single-word state machine word (from lib/rundir.sh):
#                    pending | running | passed | failed | skipped
#   warnings/<task>  optional; its presence upgrades a "passed" task to
#                    PASSED-WITH-WARNING and its first line is shown. This is
#                    the seam the Stage 3 lane check writes to — warn-only lane
#                    violations never touch the state machine, they drop a
#                    warnings/<task> file here. Absent today's producers, the
#                    report simply never sees one and every green task is PASSED.
#
# Everything else in a row is derived, not stored: the log path is
# <run>/logs/<task>.log, the branch is <BRANCH_PREFIX><task>, and the worktree
# is <worktree-parent>/yt-<task> (yolotown cuts worktrees at ../yt-<name>).
# Passing these in keeps the renderer testable without a git repo or config.
#
# Verdict -> what a row carries (nothing is probed on the filesystem; the row
# is a pure function of the status word and the config):
#
#   PASSED / PASSED-WITH-WARNING   log, worktree; a merge command; cleanup
#   FAILED                         log, worktree; cleanup (autopsy left intact)
#   RUNNING                        log, worktree (in flight: no merge, no clean)
#   SKIPPED / PENDING              name only (never got a worktree)
#
# Remote push-delete lines are deliberately not emitted here: whether a branch
# reached origin is not recorded in the run dir, and this report never guesses.
# The seed's own per-task report still emits the push-delete where it knows a
# push happened.

# Error prefix; a CLI entrypoint can set YT_PROG to its own name.
: "${YT_PROG:=yolotown}"

_yt_report_die() { printf '%s: report: %s\n' "$YT_PROG" "$*" >&2; return 1; }

# yt_verdict <run-dir> <task> — print <task>'s report verdict (one of PASSED,
#   PASSED-WITH-WARNING, FAILED, SKIPPED, RUNNING, PENDING). Fails loudly if the
#   task is not registered in the run. An unrecognised status word is echoed
#   upper-cased rather than hidden — the report stays honest about bad state.
yt_verdict() {
  local run="$1" task="$2" f="$1/status/$2" s
  if [ ! -f "$f" ]; then
    _yt_report_die "task \"$task\" not registered in $run (no status/$task)"
    return 1
  fi
  s="$(cat "$f")"
  case "$s" in
    passed)
      if [ -f "$run/warnings/$task" ]; then
        printf 'PASSED-WITH-WARNING\n'
      else
        printf 'PASSED\n'
      fi
      ;;
    failed)  printf 'FAILED\n' ;;
    skipped) printf 'SKIPPED\n' ;;
    running) printf 'RUNNING\n' ;;
    pending) printf 'PENDING\n' ;;
    *)       printf '%s\n' "$(printf '%s' "$s" | tr '[:lower:]' '[:upper:]')" ;;
  esac
}

# yt_report <run-dir> <base-branch> <branch-prefix> <worktree-parent>
#   Render the fan-in report for <run-dir> to stdout: a per-task table, the
#   green branches' merge commands, the leftover worktrees' cleanup commands,
#   and a one-line summary. Returns nonzero (message on stderr) if <run-dir>
#   has no status/ directory.
yt_report() {
  local run="$1" base="$2" prefix="$3" wtparent="$4"

  if [ -z "$run" ] || [ ! -d "$run/status" ]; then
    _yt_report_die "no run dir with a status/ directory at ${run:-<unset>}/status"
    return 1
  fi

  # Task list, sorted for a stable table; the glob-empty case yields none.
  local -a tasks=()
  local name
  while IFS= read -r name; do
    [ -n "$name" ] && tasks+=("$name")
  done < <(ls -1 "$run/status" 2>/dev/null | LC_ALL=C sort)

  printf 'run: %s\n\n' "$run"

  if [ "${#tasks[@]}" -eq 0 ]; then
    printf '(no tasks registered in this run)\n'
    return 0
  fi

  # Column widths: VERDICT holds the widest word ("PASSED-WITH-WARNING", 19);
  # TASK grows to the longest name. +2 for a two-space gutter after each.
  local vwidth=19 twidth=4 t
  for t in "${tasks[@]}"; do
    [ "${#t}" -gt "$twidth" ] && twidth="${#t}"
  done

  printf '%-*s  %-*s  %s\n' "$vwidth" "STATUS" "$twidth" "TASK" "POINTERS"

  # Rows, plus accumulate the merge / cleanup sections and the tallies.
  local passed=0 warned=0 failed=0 skipped=0 running=0 pending=0 other=0
  local merges="" cleanups="" verdict log wt ptr warn
  for t in "${tasks[@]}"; do
    verdict="$(yt_verdict "$run" "$t")"
    log="$run/logs/$t.log"
    wt="$wtparent/yt-$t"
    ptr=""
    case "$verdict" in
      PASSED|PASSED-WITH-WARNING|FAILED|RUNNING)
        ptr="log=$log  worktree=$wt" ;;
    esac
    if [ "$verdict" = "PASSED-WITH-WARNING" ] && [ -f "$run/warnings/$t" ]; then
      IFS= read -r warn < "$run/warnings/$t" || true
      ptr="$ptr  warning: $warn"
    fi
    printf '%-*s  %-*s  %s\n' "$vwidth" "$verdict" "$twidth" "$t" "$ptr"

    case "$verdict" in
      PASSED|PASSED-WITH-WARNING)
        merges="$merges  git checkout $base && git merge --no-ff $prefix$t"$'\n'
        cleanups="$cleanups  git worktree remove --force $wt"$'\n'"  git branch -D $prefix$t"$'\n'
        ;;
      FAILED)
        cleanups="$cleanups  git worktree remove --force $wt"$'\n'"  git branch -D $prefix$t"$'\n'
        ;;
    esac
    case "$verdict" in
      PASSED)              passed=$((passed + 1)) ;;
      PASSED-WITH-WARNING) warned=$((warned + 1)) ;;
      FAILED)              failed=$((failed + 1)) ;;
      SKIPPED)             skipped=$((skipped + 1)) ;;
      RUNNING)             running=$((running + 1)) ;;
      PENDING)             pending=$((pending + 1)) ;;
      *)                   other=$((other + 1)) ;;
    esac
  done

  printf '\n'
  printf 'green branches — review, then merge (yolotown never auto-merges):\n'
  if [ -n "$merges" ]; then
    printf '%s' "$merges"
  else
    printf '  (none)\n'
  fi

  printf '\n'
  printf 'leftover worktrees — remove when done:\n'
  if [ -n "$cleanups" ]; then
    printf '%s' "$cleanups"
  else
    printf '  (none)\n'
  fi

  # Summary: only mention the buckets that actually occurred, always in order.
  local parts=""
  [ "$passed"  -gt 0 ] && parts="$parts, $passed passed"
  [ "$warned"  -gt 0 ] && parts="$parts, $warned passed-with-warning"
  [ "$failed"  -gt 0 ] && parts="$parts, $failed failed"
  [ "$skipped" -gt 0 ] && parts="$parts, $skipped skipped"
  [ "$running" -gt 0 ] && parts="$parts, $running running"
  [ "$pending" -gt 0 ] && parts="$parts, $pending pending"
  [ "$other"   -gt 0 ] && parts="$parts, $other unknown"
  parts="${parts#, }"
  printf '\nsummary: %d task%s — %s\n' "${#tasks[@]}" "$([ "${#tasks[@]}" -eq 1 ] && printf '' || printf 's')" "$parts"
}
