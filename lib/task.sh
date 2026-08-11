#!/usr/bin/env bash
# yolotown per-task execution core — the ONE implementation of the pipeline that
# turns a single (name, description) into a gated feature branch inside its own
# worktree: cut a worktree off BASE_BRANCH, seed and verify ENV_FILES, build the
# worker prompt, run the headless agent, gate on TEST_CMD, and on green commit
# (+ push if PUSH_ON_GREEN). seed.sh (one task) and `yolotown run` (a batch) are
# both thin wrappers over this; the pipeline used to be copied into each of them
# and had already diverged. It lives here exactly once now.
#
# Sourcing this file only defines functions; call yt_run_task to run a task.
#
# The CALLER owns the run dir and all whole-repo preflight (base branch exists,
# checked out on it, clean tree, green base gate). yt_run_task takes a run dir
# that already exists with <name> registered (born pending) — it never creates
# a run dir, because a batch shares one across many tasks. It RETURNS 0/1/2
# instead of exiting, so a batch continues past a failure and each caller
# renders its own report from the task-scoped globals below.
#
#   yt_run_task <run-dir> <name> <desc>
#     reads (the caller sets these from config before calling):
#       BASE_BRANCH BRANCH_PREFIX ENV_FILES TEST_CMD CLAUDE_BIN WORKER_MODEL
#       PUSH_ON_GREEN INVARIANTS_CONTENT WORKTREE_PARENT
#     writes (for the caller's report):
#       YT_TASK_BRANCH  the feature branch name
#       YT_TASK_WT      the worktree path
#       YT_TASK_LOG     the per-task log path under the run dir
#       YT_TASK_PUSHED  yes|no — whether the commit reached origin
#       YT_TASK_REASON  the failure reason (empty on success)
#     drives status pending -> running -> {passed|failed} and returns:
#       0  passed  (committed; pushed iff PUSH_ON_GREEN)
#       1  failed  before or at commit — worktree left intact for autopsy
#       2  committed locally but the push failed (commit stands on the branch)
#     Status writes are silenced: a stray status error must never mask the real
#     outcome, and every failure here is the legal running -> failed edge.

: "${YT_PROG:=yolotown}"

# _yt_task_fail <run-dir> <name> <reason> — record a per-task failure: mark
# running -> failed (silenced) and stash the reason for the caller's report.
# It does not print or touch the worktree; the caller owns the human-facing
# report and the worktree is left intact for autopsy.
_yt_task_fail() {
  local run="$1" name="$2" reason="$3"
  yt_status_set "$run" "$name" failed >/dev/null 2>&1 || true
  YT_TASK_REASON="$reason"
}

yt_run_task() {
  local run="$1" name="$2" desc="$3"
  local branch="${BRANCH_PREFIX}${name}"
  local wt="$WORKTREE_PARENT/yt-${name}"
  local log="$run/logs/${name}.log"
  : > "$log"

  # Publish the pointers up front so the caller can report them even on an
  # early failure. PUSHED/REASON are reset each call so a reused shell is clean.
  YT_TASK_BRANCH="$branch"
  YT_TASK_WT="$wt"
  YT_TASK_LOG="$log"
  YT_TASK_PUSHED="no"
  YT_TASK_REASON=""

  # pending -> running. Every downstream failure is the legal running -> failed.
  yt_status_set "$run" "$name" running >/dev/null 2>&1 || true
  {
    echo "run: task=$name branch=$branch"
    echo "run: worktree=$wt"
    echo "run: log=$log"
  } | tee -a "$log"

  # Preflight collisions: a leftover branch or worktree from a prior run. Fail
  # this task loudly (naming the cleanup); the caller decides what to do next.
  if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    _yt_task_fail "$run" "$name" "branch \"$branch\" already exists; cleanup: git branch -D $branch"
    return 1
  fi
  if [ -e "$wt" ]; then
    _yt_task_fail "$run" "$name" "worktree \"$wt\" already exists; cleanup: git worktree remove --force $wt"
    return 1
  fi

  git worktree add "$wt" -b "$branch" "$BASE_BRANCH" >>"$log" 2>&1 || {
    _yt_task_fail "$run" "$name" "git worktree add failed (see log)"
    return 1
  }

  # Env files in, each verified git-ignored in the worktree. A failure here is
  # still pre-agent, so undoing the seconds-old, workless worktree is safe.
  local f
  for f in $ENV_FILES; do
    mkdir -p "$wt/$(dirname "$f")"
    cp "$f" "$wt/$f"
    if ! git -C "$wt" check-ignore -q "$f"; then
      git worktree remove --force "$wt" >/dev/null 2>&1 || true
      git branch -D "$branch" >/dev/null 2>&1 || true
      _yt_task_fail "$run" "$name" "ENV_FILES entry \"$f\" is not git-ignored in the worktree; add it to .gitignore (fresh worktree removed)"
      return 1
    fi
  done

  local prompt
  prompt="You are completing one software task inside an isolated git worktree.
The current directory is the worktree; it is yours alone.

TASK: ${name}
DESCRIPTION: ${desc}

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

  # stdin from /dev/null: the agent is headless and must never inherit (and
  # stall on) the caller's stdin. This is the one place stdin is wired, so the
  # two former copies — one of which omitted it and stalled ~3s per dispatch —
  # can no longer diverge.
  local rc
  echo "run: agent: $CLAUDE_BIN (model: ${WORKER_MODEL:-cli default})" | tee -a "$log"
  (
    cd "$wt" && "$CLAUDE_BIN" -p "$prompt" \
      ${WORKER_MODEL:+--model "$WORKER_MODEL"} \
      --allowedTools "Edit" "Write" "Read" "Glob" "Grep" "Bash" </dev/null
  ) 2>&1 | tee -a "$log"
  rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || { _yt_task_fail "$run" "$name" "agent exited nonzero ($rc)"; return 1; }

  [ -n "$(git -C "$wt" status --porcelain)" ] || {
    _yt_task_fail "$run" "$name" "agent made no changes"; return 1;
  }

  echo "run: gate: $TEST_CMD" | tee -a "$log"
  ( cd "$wt" && bash -c "$TEST_CMD" ) 2>&1 | tee -a "$log"
  rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || { _yt_task_fail "$run" "$name" "gate red, exit $rc"; return 1; }

  local subject body
  subject="feat(${name}): $(printf '%s' "$desc" | cut -c1-60)"
  body="Task: ${desc}

Authored by yolotown via headless claude agent."
  git -C "$wt" add -A
  git -C "$wt" commit -m "$subject" -m "$body" >>"$log" 2>&1 || {
    _yt_task_fail "$run" "$name" "git commit failed"; return 1;
  }

  if [ "$PUSH_ON_GREEN" = "true" ]; then
    if git -C "$wt" push -u origin "$branch" >>"$log" 2>&1; then
      YT_TASK_PUSHED="yes"
    else
      # Commit stands on the branch; the push is the only thing that failed.
      # A distinct return (2) lets a caller report PASSED-LOCALLY instead of a
      # flat failure. Status is failed either way — nothing reached origin.
      _yt_task_fail "$run" "$name" "push failed; commit stands on $branch, retry: git -C $wt push -u origin $branch"
      return 2
    fi
  fi

  yt_status_set "$run" "$name" passed >/dev/null 2>&1 || true
  return 0
}
