#!/usr/bin/env bash
# yolotown seed (Stage 0): one task, one agent, one worktree, gate, ship.
# Run from the target repo root (the directory containing .yolotown.conf):
#   /path/to/seed.sh <task-name> "<task description>"
#
# The per-task pipeline itself (worktree, env files, prompt, agent, gate,
# commit, push) lives in lib/task.sh and is shared with `yolotown run`. This
# script is a thin wrapper: whole-repo preflight, one run dir with one task
# registered, a single call into that core, then the single-task report.
set -uo pipefail

# seed.sh runs from the *target* repo root, so locate our own libs by path.
SEED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SEED_DIR/lib/config.sh" \
  || { printf 'seed: error: cannot source %s/lib/config.sh (broken install)\n' "$SEED_DIR" >&2; exit 1; }
# shellcheck source=lib/rundir.sh
. "$SEED_DIR/lib/rundir.sh" \
  || { printf 'seed: error: cannot source %s/lib/rundir.sh (broken install)\n' "$SEED_DIR" >&2; exit 1; }
# shellcheck source=lib/task.sh
. "$SEED_DIR/lib/task.sh" \
  || { printf 'seed: error: cannot source %s/lib/task.sh (broken install)\n' "$SEED_DIR" >&2; exit 1; }

usage() {
  cat >&2 <<'USAGE'
usage: seed.sh <task-name> "<task description>"

  <task-name>          matches [a-z0-9-]+; becomes branch <BRANCH_PREFIX><task-name>
  <task description>   what the agent is told to do

Run from the target repo root (the directory containing .yolotown.conf).
USAGE
  exit 2
}

die() { printf 'seed: error: %s\n' "$*" >&2; exit 1; }

# ---- args ------------------------------------------------------------------
[ $# -eq 2 ] || usage
TASK_NAME="$1"
TASK_DESC="$2"
if ! [[ "$TASK_NAME" =~ ^[a-z0-9-]+$ ]]; then
  printf 'seed: error: task name "%s" is invalid (must match [a-z0-9-]+)\n' "$TASK_NAME" >&2
  exit 2
fi
[ -n "$TASK_DESC" ] || usage

# ---- config ----------------------------------------------------------------
# Defaults, sourcing, and validation all live in lib/config.sh.
yt_load_config

# ---- preflight ---------------------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
TOPLEVEL="$(git rev-parse --show-toplevel)"
[ "$(pwd -P)" = "$TOPLEVEL" ] || die "run from the repo root: $TOPLEVEL"
if ! git rev-parse --verify --quiet "refs/heads/$BASE_BRANCH" >/dev/null; then
  if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    die "base branch \"$BASE_BRANCH\" does not exist, and this repo has no commits yet.
Make an initial commit, then re-run."
  fi
  HEAD_REF="$(git rev-parse --abbrev-ref HEAD)"
  [ "$HEAD_REF" = "HEAD" ] && HEAD_REF="$(git rev-parse --short HEAD)"
  printf 'seed: base branch "%s" does not exist. Create it now pointing at current HEAD (%s)? [y/N] ' "$BASE_BRANCH" "$HEAD_REF"
  REPLY=""
  read -r REPLY
  case "$REPLY" in
    y|Y|yes|YES) git checkout -q -b "$BASE_BRANCH" || die "failed to create base branch \"$BASE_BRANCH\"" ;;
    *) die "aborted: base branch \"$BASE_BRANCH\" was not created.
create it yourself: git branch $BASE_BRANCH $HEAD_REF" ;;
  esac
fi
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT_BRANCH" = "$BASE_BRANCH" ] \
  || die "checked out on \"$CURRENT_BRANCH\", not base branch \"$BASE_BRANCH\"; the base gate must run against the base branch"
[ -z "$(git status --porcelain --untracked-files=no)" ] \
  || die "base working tree is dirty; commit or stash before running"

BRANCH="${BRANCH_PREFIX}${TASK_NAME}"
if git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  die "branch \"$BRANCH\" already exists
cleanup: git branch -D $BRANCH"
fi
WORKTREE="$(dirname "$TOPLEVEL")/yt-${TASK_NAME}"
if [ -e "$WORKTREE" ]; then
  die "worktree path \"$WORKTREE\" already exists
cleanup: git worktree remove --force $WORKTREE"
fi
for f in $ENV_FILES; do
  [ -f "$f" ] || die "ENV_FILES entry \"$f\" not found in repo root"
done

# ---- agent reachability -------------------------------------------------------
# One probe per invocation (lib/task.sh), before the base gate so an unreachable
# agent is not paid for with a full suite run, and before the run dir and the
# worktree exist so a refusal creates nothing. It prints its own refusal.
yt_agent_precheck || exit 1

# ---- base gate ----------------------------------------------------------------
echo "seed: base gate: $TEST_CMD"
bash -c "$TEST_CMD" || die "base suite is red; refusing to start (fix the base branch first)"

# ---- run dir + log ----------------------------------------------------------
# The run dir is this run's flat-file home. State is per task: this task's
# status state machine lives in .yolotown/run-<ts>/status/<name>, and its log's
# bytes live in .yolotown/run-<ts>/logs/<name>.log. .yolotown/logs/<name>-<ts>.log
# is kept as a symlink into the run dir, so the log stays discoverable by name
# while the run dir owns it. yt_run_create also repoints .yolotown/latest at
# this run; yt_status_init registers this task, born pending.
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
YT_DIR="$TOPLEVEL/.yolotown"
RUN_DIR="$(yt_run_create "$YT_DIR" "$RUN_TS")" || die "could not create a run dir under $YT_DIR"
yt_status_init "$RUN_DIR" "$TASK_NAME" || die "could not register task \"$TASK_NAME\" in $RUN_DIR"
LOG_DIR="$YT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${TASK_NAME}-${RUN_TS}.log"
ln -sfn "../$(basename "$RUN_DIR")/logs/${TASK_NAME}.log" "$LOG"

# ---- run the task -----------------------------------------------------------
# yt_run_task (lib/task.sh) owns the whole per-task pipeline. It reads config as
# globals, so hand it the invariants text and the worktree parent, then dispatch
# our single task into the shared run dir. It returns 0/1/2 rather than exiting,
# leaving the outcome in the YT_TASK_* globals for the report below.
if [ -n "$INVARIANTS_FILE" ]; then
  INVARIANTS_CONTENT="$(cat "$INVARIANTS_FILE")"
else
  INVARIANTS_CONTENT="None provided."
fi
WORKTREE_PARENT="$(dirname "$TOPLEVEL")"

yt_run_task "$RUN_DIR" "$TASK_NAME" "$TASK_DESC"
TASK_RC=$?
PUSHED="$YT_TASK_PUSHED"

# ---- report -----------------------------------------------------------------
# yt_run_task already drove the status machine and left the worktree intact on
# any failure; here we only render the single-task report. The branch/worktree
# are the ones seed computed in preflight (identical to what the core used).
print_cleanup() {
  echo "cleanup:"
  echo "  git worktree remove --force $WORKTREE"
  echo "  git branch -D $BRANCH"
  if [ "$PUSHED" = "yes" ]; then
    echo "  git push origin --delete $BRANCH"
  fi
}

case "$TASK_RC" in
  0)
    {
      echo ""
      echo "RESULT: PASSED"
      echo "branch:   $BRANCH (pushed: $PUSHED)"
      echo "run:      $RUN_DIR"
      echo "log:      $LOG"
      echo "worktree: $WORKTREE"
      echo "merge:    git checkout $BASE_BRANCH && git merge --no-ff $BRANCH"
      print_cleanup
    } | tee -a "$LOG"
    exit 0
    ;;
  2)
    # Committed locally, but the push failed: the commit stands on the branch.
    {
      echo ""
      echo "RESULT: PASSED-LOCALLY (push failed; commit stands on $BRANCH)"
      echo "retry:    git -C $WORKTREE push -u origin $BRANCH"
      echo "run:      $RUN_DIR"
      echo "log:      $LOG"
      echo "worktree: $WORKTREE"
      print_cleanup
    } | tee -a "$LOG"
    exit 1
    ;;
  *)
    {
      echo ""
      echo "RESULT: FAILED ($YT_TASK_REASON)"
      echo "run:      $RUN_DIR"
      echo "log:      $LOG"
      echo "worktree: $WORKTREE"
      print_cleanup
    } | tee -a "$LOG"
    exit 1
    ;;
esac
