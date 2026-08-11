#!/usr/bin/env bash
# yolotown run directories: each run gets a flat-file home under .yolotown/,
# named by the UTC time it was created, holding a status file and the run's
# log. A `latest` symlink always points at the newest run.
#
# Sourcing this file only defines functions; call yt_run_create to make a run
# and yt_status_get / yt_status_set to drive its state machine.
#
# Status state machine — a run is born "pending" and moves through exactly the
# edges below; every other transition (including a no-op same-state set) is
# rejected loudly:
#
#     pending ──▶ running ──▶ passed
#        │           └──────▶ failed
#        └──────────────────▶ skipped
#
#   pending  created, not yet started
#   running  the agent / gate is in flight
#   passed   terminal: the run succeeded
#   failed   terminal: the run broke
#   skipped  terminal: the run was deliberately not started
#
# Terminal states have no outgoing edges. A run reaches "passed" only by way
# of "running" — you cannot pass something that never ran.

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

# yt_run_create <yolotown-dir> [timestamp]
#   Make <yolotown-dir>/run-<ts>/, seed its status file to "pending", repoint
#   <yolotown-dir>/latest at it, and print the run dir path. <ts> defaults to
#   the current UTC time (YYYYMMDDTHHMMSSZ). A same-<ts> collision gets a
#   -2, -3, ... suffix, so a run dir is never reused.
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
  printf 'pending\n' > "$dir/status"

  # Relative symlink so .yolotown/ stays relocatable; -n so an existing
  # latest -> dir symlink is replaced, not descended into; -f to overwrite.
  ln -sfn "$base" "$ytdir/latest" \
    || { _yt_run_die "cannot update latest symlink in $ytdir"; return 1; }

  printf '%s\n' "$dir"
}

# yt_status_get <run-dir> — print the run's current status.
yt_status_get() {
  local dir="$1"
  if [ -z "$dir" ] || [ ! -f "$dir/status" ]; then
    _yt_run_die "yt_status_get: no status file at ${dir:-<unset>}/status"
    return 1
  fi
  cat "$dir/status"
}

# yt_status_set <run-dir> <new-status> — enforce the transition, then write it.
#   Rejects (nonzero, status left untouched) an unknown target status or an
#   illegal edge, naming what was refused and the legal next states.
yt_status_set() {
  local dir="$1" to="$2"
  if [ -z "$dir" ] || [ ! -f "$dir/status" ]; then
    _yt_run_die "yt_status_set: no status file at ${dir:-<unset>}/status"
    return 1
  fi
  if ! _yt_status_known "$to"; then
    _yt_run_die "unknown status \"$to\" (valid: pending running passed failed skipped)"
    return 1
  fi
  local from
  from="$(cat "$dir/status")"
  if ! _yt_status_legal "$from" "$to"; then
    _yt_run_die "illegal transition \"$from\" -> \"$to\" for $dir (legal next from \"$from\": $(_yt_status_next "$from"))"
    return 1
  fi
  printf '%s\n' "$to" > "$dir/status"
}
