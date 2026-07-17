#!/usr/bin/env bash
# yolotown seed (Stage 0): one task, one agent, one worktree, gate, ship.
# Run from the target repo root (the directory containing .yolotown.conf):
#   /path/to/seed.sh <task-name> "<task description>"
set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: seed.sh <task-name> "<task description>"

  <task-name>          matches [a-z0-9-]+; becomes branch <BRANCH_PREFIX><task-name>
  <task description>   what the agent is told to do

Run from the target repo root (the directory containing .yolotown.conf).
USAGE
  exit 2
}

conf_die() { printf 'seed: config error: %s\n' "$*" >&2; exit 2; }
die()      { printf 'seed: error: %s\n'        "$*" >&2; exit 1; }

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
[ -f ./.yolotown.conf ] || conf_die "no .yolotown.conf in $PWD
a minimal valid config:
  TEST_CMD=\"npm test\""

TEST_CMD=""
ENV_FILES=""
INVARIANTS_FILE=""
BASE_BRANCH="main"
BRANCH_PREFIX="feature/"
PUSH_ON_GREEN="true"
WORKER_MODEL=""
CLAUDE_BIN="claude"

# shellcheck source=/dev/null
. ./.yolotown.conf || conf_die ".yolotown.conf failed to source (must be plain shell key=value)"

[ -n "$TEST_CMD" ] || conf_die "TEST_CMD is required and missing
a minimal valid config:
  TEST_CMD=\"npm test\""
case "$PUSH_ON_GREEN" in
  true|false) ;;
  *) conf_die "PUSH_ON_GREEN must be \"true\" or \"false\" (got \"$PUSH_ON_GREEN\")" ;;
esac
if [ -z "$INVARIANTS_FILE" ] && [ -f CLAUDE.md ]; then
  INVARIANTS_FILE="CLAUDE.md"
fi
if [ -n "$INVARIANTS_FILE" ] && [ ! -f "$INVARIANTS_FILE" ]; then
  conf_die "INVARIANTS_FILE \"$INVARIANTS_FILE\" does not exist"
fi

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

# ---- base gate ----------------------------------------------------------------
echo "seed: base gate: $TEST_CMD"
bash -c "$TEST_CMD" || die "base suite is red; refusing to start (fix the base branch first)"

# ---- log ------------------------------------------------------------------------
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="$TOPLEVEL/.yolotown/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${TASK_NAME}-${RUN_TS}.log"
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
log "seed: task=$TASK_NAME branch=$BRANCH"
log "seed: log=$LOG"

# ---- worktree -----------------------------------------------------------------
git worktree add "$WORKTREE" -b "$BRANCH" "$BASE_BRANCH" >>"$LOG" 2>&1 \
  || die "git worktree add failed (see $LOG)"

# Allowed ONLY before the agent has run: undo a seconds-old, workless worktree.
remove_fresh_worktree() {
  git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  git branch -D "$BRANCH" >/dev/null 2>&1 || true
}

for f in $ENV_FILES; do
  mkdir -p "$WORKTREE/$(dirname "$f")"
  cp "$f" "$WORKTREE/$f"
  if ! git -C "$WORKTREE" check-ignore -q "$f"; then
    remove_fresh_worktree
    die "ENV_FILES entry \"$f\" is not git-ignored in the worktree; it would be committed. Add it to .gitignore. (fresh worktree and branch removed)"
  fi
done

# ---- worker prompt ----------------------------------------------------------------
if [ -n "$INVARIANTS_FILE" ]; then
  INVARIANTS_CONTENT="$(cat "$INVARIANTS_FILE")"
else
  INVARIANTS_CONTENT="None provided."
fi

PROMPT="You are completing one software task inside an isolated git worktree.
The current directory is the worktree; it is yours alone.

TASK: ${TASK_NAME}
DESCRIPTION: ${TASK_DESC}

ACCEPTANCE GATE: the command \`${TEST_CMD}\` must exit 0. Run it yourself
before finishing. You are done only when it passes.

RULES:
- Never weaken, delete, or edit an existing test to make it pass. A red
  gate means the work is wrong, not the test.
- Do not run any git commands that commit, push, branch, or merge; the
  orchestrator owns git. Read-only git (status, diff, log) is fine.
- Work only inside the current directory.
- If the description references spec files in the repo, read them first.

REPOSITORY INVARIANTS (obey these):
${INVARIANTS_CONTENT}"

# ---- reporting ----------------------------------------------------------------
PUSHED="no"
print_cleanup() {
  echo "cleanup:"
  echo "  git worktree remove --force $WORKTREE"
  echo "  git branch -D $BRANCH"
  if [ "$PUSHED" = "yes" ]; then
    echo "  git push origin --delete $BRANCH"
  fi
}
fail_task() {
  {
    echo ""
    echo "RESULT: FAILED ($1)"
    echo "log:      $LOG"
    echo "worktree: $WORKTREE"
    print_cleanup
  } | tee -a "$LOG"
  exit 1
}

# ---- agent ----------------------------------------------------------------------
log "seed: agent: $CLAUDE_BIN (model: ${WORKER_MODEL:-cli default})"
(
  cd "$WORKTREE" && "$CLAUDE_BIN" -p "$PROMPT" \
    ${WORKER_MODEL:+--model "$WORKER_MODEL"} \
    --allowedTools "Edit" "Write" "Read" "Glob" "Grep" "Bash"
) 2>&1 | tee -a "$LOG"
AGENT_RC="${PIPESTATUS[0]}"
[ "$AGENT_RC" -eq 0 ] || fail_task "agent exited nonzero ($AGENT_RC)"

[ -n "$(git -C "$WORKTREE" status --porcelain)" ] || fail_task "agent made no changes"

# ---- gate -------------------------------------------------------------------------
log "seed: gate: $TEST_CMD"
( cd "$WORKTREE" && bash -c "$TEST_CMD" ) 2>&1 | tee -a "$LOG"
GATE_RC="${PIPESTATUS[0]}"
[ "$GATE_RC" -eq 0 ] || fail_task "gate red, exit $GATE_RC"

# ---- ship ---------------------------------------------------------------------------
SUBJECT="feat(${TASK_NAME}): $(printf '%s' "$TASK_DESC" | cut -c1-60)"
BODY="Task: ${TASK_DESC}

Authored by yolotown seed via headless claude agent."
git -C "$WORKTREE" add -A
git -C "$WORKTREE" commit -m "$SUBJECT" -m "$BODY" >>"$LOG" 2>&1 || fail_task "git commit failed"

if [ "$PUSH_ON_GREEN" = "true" ]; then
  if git -C "$WORKTREE" push -u origin "$BRANCH" 2>&1 | tee -a "$LOG"; then
    PUSHED="yes"
  else
    {
      echo ""
      echo "RESULT: PASSED-LOCALLY (push failed; commit stands on $BRANCH)"
      echo "retry:    git -C $WORKTREE push -u origin $BRANCH"
      echo "log:      $LOG"
      echo "worktree: $WORKTREE"
      print_cleanup
    } | tee -a "$LOG"
    exit 1
  fi
fi

{
  echo ""
  echo "RESULT: PASSED"
  echo "branch:   $BRANCH (pushed: $PUSHED)"
  echo "log:      $LOG"
  echo "worktree: $WORKTREE"
  echo "merge:    git checkout $BASE_BRANCH && git merge --no-ff $BRANCH"
  print_cleanup
} | tee -a "$LOG"
exit 0
