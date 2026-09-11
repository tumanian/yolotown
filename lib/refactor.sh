#!/usr/bin/env bash
# yolotown gated refactor stage (SPEC.md section 3.2) — the ONE human checkpoint
# in the whole pipeline, and the ONE place the tool ever writes to BASE_BRANCH.
#
# Sourcing this file only defines functions; call yt_refactor_gate to run it.
#
#   yt_refactor_gate <run-dir> [<tasks-tsv>]
#     <run-dir> must already hold plan.json (lib/plan.sh wrote it).
#     <tasks-tsv> is yt_parse_tasks output ("<name><TAB><description>" per
#     line), used only to show the planner what the colliding tasks actually
#     are; omitting it costs the descriptions, nothing else.
#     reads (from config): BASE_BRANCH TEST_CMD CLAUDE_BIN PLANNER_MODEL
#                          ENV_FILES INVARIANTS_CONTENT WORKTREE_PARENT
#     must be called from inside the target repo, checked out on BASE_BRANCH
#     with a clean tree (`run`'s own preconditions).
#     reads the human's answer from ITS OWN STDIN — this is the one function
#     here that is deliberately interactive, so it must NOT be called inside a
#     command substitution or with stdin redirected from anything but a human.
#     publishes, for the caller's report:
#       YT_REFACTOR_GROUPS    how many COLLIDING-SPLITTABLE groups were found
#       YT_REFACTOR_DECISION  none | approved | rejected | failed
#       YT_REFACTOR_REASON    why it stopped (empty when it did not)
#       YT_REFACTOR_COMMIT    on approval+green, the commit BASE_BRANCH now has
#     returns:
#       0  nothing to gate, or every group approved, green, and merged
#       1  hard failure — plan generation, the refactor agent, or the suite
#       2  a human rejected a refactor (the expected "no", not an error)
#
#   yt_refactor_groups <plan.json>
#     "<tasks><TAB><files><TAB><reason>" per COLLIDING-SPLITTABLE group.
#
# WHY THIS ONE THING IS GATED (SPEC.md section 1). A leaf task that fails dies
# alone at its gate, costing one log — so it is automated. A refactor mutates
# the baseline every other task is cut from, so ITS failure is contagious — so
# it gets exactly one human approval. Everything here follows from that:
#
# - PLAN FIRST, EXECUTE NEVER WITHOUT A YES. One headless call on
#   PLANNER_MODEL produces a PLAN ONLY: which files split, into what, what
#   moves where, and why that makes the colliding tasks disjoint. Nothing is
#   created, nothing is edited, no worktree exists yet. The plan is printed and
#   the gate STOPS on stdin.
# - REJECT IS THE DEFAULT. Empty input, EOF, or anything that is not an
#   explicit yes is a rejection — exactly as seed.sh's base-branch
#   confirmation reads its [y/N]. A non-interactive caller (cron, a pipe, a
#   test) therefore gets "no", which is the only safe way to be wrong here.
#   `edit` is deferred (SPEC.md section 9): it is read as a rejection that says
#   so, since rejecting and amending the backlog covers the same need.
# - EXECUTION IS STILL SANDBOXED. The approved refactor runs in its own
#   worktree cut from BASE_BRANCH, behavior-preserving only, and the FULL suite
#   runs there. The base branch is untouched for the whole of it.
# - THE BASE ADVANCES BY FAST-FORWARD, BY EXACTLY ONE COMMIT, ONLY ON GREEN.
#   The run holds the base (it refused to start off it, or dirty), so the base
#   cannot have moved under us — which is checked anyway, and a base that moved
#   is a refusal, not a merge. The advance is `git merge --ff-only`, so
#   BASE_BRANCH ends up byte-identical to the tree the suite just passed on.
#   It is never pushed: remote base branches stay the human's (SPEC.md
#   section 4).
# - RED DISCARDS EVERYTHING. A red suite (or a crashed agent, or an agent that
#   changed nothing) removes the refactor worktree and leaves BASE_BRANCH
#   exactly where it was, to the byte. The full output stays in the run dir, so
#   the failure is diagnosable without the worktree.
#
# WHAT IT WRITES. Per group, under <run-dir>/refactor/<n>/ (flat files, all
# cat-able — SPEC.md section 2 does not list them, see section 9):
#   plan.txt   the refactor plan the human was shown, verbatim
#   decision   one word: approved | rejected | failed
#   reason     why, when it was not approved-and-green
#   log        the refactor agent's and the suite's full output
#   commit     on green, the commit BASE_BRANCH was fast-forwarded to
#
# MANY GROUPS. Each group is planned, approved and executed on its own, in
# order, each cut from the base the previous one may have advanced. The first
# rejection or failure stops the gate then and there: the caller must not fan
# out, and asking for approvals it can no longer use would be theater.

: "${YT_PROG:=yolotown}"

# The collision report this gate reads is lib/plan.sh's, so the gate declares
# the dependency itself rather than leaving every caller to remember it.
# Sourcing only defines functions, so an entrypoint that also sources it pays
# nothing.
# shellcheck source=lib/plan.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plan.sh" \
  || { printf '%s: error: cannot source lib/plan.sh (broken install)\n' "$YT_PROG" >&2; return 1; }

# Both invocations carry a stable marker in their prompt, exactly as the
# reachability probe (lib/task.sh) and the conflict detector (lib/plan.sh) do,
# so a test shim can tell all four apart: at Stage 3 one `run` makes a probe
# call, a planner call, a refactor-plan call, a refactor-execute call and N task
# calls through the same CLAUDE_BIN. tests/fake-claude answers these two from
# FAKE_CLAUDE_REFACTOR_PLAN_MODE and FAKE_CLAUDE_REFACTOR_MODE. Change a marker
# here and you must change it there.
YT_REFACTOR_PLAN_MARKER="yolotown-refactor-plan"
YT_REFACTOR_EXEC_MARKER="yolotown-refactor-execute"

_yt_refactor_die() { printf '%s: refactor: %s\n' "$YT_PROG" "$*" >&2; return 1; }
# Progress goes to stdout, not stderr: a human is standing at this gate waiting
# to answer it, and the prompt, the plan and the running commentary are one
# conversation.
_yt_refactor_say() { printf '%s: refactor: %s\n' "$YT_PROG" "$*"; }

# _yt_refactor_join <sep> <word>... — join the words with <sep>.
_yt_refactor_join() {
  local sep="$1"; shift
  local out="" w
  for w in "$@"; do
    if [ -z "$out" ]; then out="$w"; else out="$out$sep$w"; fi
  done
  printf '%s' "$out"
}

# yt_refactor_groups <plan.json> — print the COLLIDING-SPLITTABLE collisions,
# one per line, as "<tasks><TAB><files><TAB><reason>" (tasks and files
# space-separated, exactly as yt_plan_collisions gives them). No output means
# there is nothing to gate. INHERENTLY-COUPLED collisions are deliberately not
# here: those are not splittable, so no refactor is proposed for them; the
# coupled scheduler (lib/fanout.sh) runs them in order instead.
yt_refactor_groups() {
  local plan="${1:-}" collisions bucket tasks files reason
  collisions="$(yt_plan_collisions "$plan")" || return 1
  [ -n "$collisions" ] || return 0
  while IFS=$'\t' read -r bucket tasks files reason; do
    [ "$bucket" = "COLLIDING-SPLITTABLE" ] || continue
    printf '%s\t%s\t%s\n' "$tasks" "$files" "$reason"
  done <<< "$collisions"
}

# _yt_refactor_desc <tasks-tsv> <name> — the task's description from the parsed
# backlog, or a placeholder when the caller gave none.
_yt_refactor_desc() {
  local tsv="${1:-}" want="$2" name desc
  if [ -n "$tsv" ]; then
    while IFS=$'\t' read -r name desc; do
      if [ "$name" = "$want" ]; then printf '%s' "$desc"; return 0; fi
    done <<< "$tsv"
  fi
  printf '(description not available to the gate)'
}

# _yt_refactor_show <file> — echo a captured response to stderr, indented and
# bounded, so a refusal is diagnosable without rerunning the agent.
_yt_refactor_show() { _yt_plan_show "$@"; }

# _yt_refactor_plan_prompt <tasks> <files> <reason> <tasks-tsv> — the
# PLAN-ONLY prompt. It says "change nothing" three ways on purpose: this call
# runs before any approval, so an agent that started editing would be editing
# the repo the human is still deciding about.
_yt_refactor_plan_prompt() {
  local tasks="$1" files="$2" reason="$3" tsv="$4" n f

  cat <<EOF
${YT_REFACTOR_PLAN_MARKER}

You are planning a refactor for a parallel task runner. The tasks below are
about to be executed at the same time, each by its own agent in its own git
worktree. Conflict detection found that they COLLIDE: they all have to touch
the same file(s), so running them in parallel would have them overwrite each
other. A shared module could be split so they no longer overlap.

Plan that split. PLAN ONLY — change nothing, create nothing, edit nothing.
Your answer is printed to a human who approves or rejects it before any of it
is executed. If it is approved, a different agent executes it.

COLLIDING TASKS (one per line, "TASK <name> | <description>"):
EOF

  for n in $tasks; do
    printf 'TASK %s | %s\n' "$n" "$(_yt_refactor_desc "$tsv" "$n")"
  done

  printf '\nSHARED FILES (the collision, one per line, "FILE <path>"):\n'
  for f in $files; do
    printf 'FILE %s\n' "$f"
  done

  cat <<EOF

CONFLICT DETECTOR'S REASON: ${reason:-(none given)}

ACCEPTANCE GATE (the refactor must leave this green): ${TEST_CMD}

ANSWER FORMAT — plain text for a human to read in a terminal. No JSON, no
code fences, no preamble, under 40 lines, these four headings:
  SPLIT   which existing files are split, and into which new files
  MOVES   what moves where: which functions/exports, from which path to which
  UPDATES which callers and imports have to be updated to follow the moves
  WHY     one line per colliding task: the files it touches AFTER the refactor,
          and why that no longer overlaps the other tasks

RULES — the refactor you plan must obey these, so plan nothing that breaks one:
- BEHAVIOR-PRESERVING ONLY. Moving and re-exporting code, splitting files,
  updating imports. No new features, no bug fixes, no API changes, none of the
  colliding tasks' actual work.
- Never weaken, delete, or edit an existing test to make it pass.
- The acceptance gate above must be green afterwards, unchanged.
- If the collision cannot be split apart behavior-preservingly, say exactly
  that under SPLIT and explain why. A human reads this; an honest "this is not
  splittable" is a useful answer and will be rejected on purpose.
EOF
}

# _yt_refactor_exec_prompt <plan-text> <tasks> <files> — the EXECUTE prompt,
# built only after a human said yes. The approved plan is quoted into it
# verbatim: the agent follows the plan that was approved, it does not get to
# redesign one.
_yt_refactor_exec_prompt() {
  local plan="$1" tasks="$2" files="$3"

  cat <<EOF
${YT_REFACTOR_EXEC_MARKER}

You are executing an already-approved refactor inside an isolated git
worktree. The current directory is the worktree; it is yours alone.

A human read the plan below at the yolotown refactor gate and approved it.
Follow it. Do not redesign it, do not extend it, do not do the work of the
tasks it is making room for.

REFACTOR PLAN (approved):
${plan}

WHY: the tasks ${tasks} all have to touch ${files}, so they cannot run in
parallel until that shared code is split apart. This refactor is the split,
and nothing else.

ACCEPTANCE GATE: the command \`${TEST_CMD}\` must exit 0. Run it yourself
before finishing. You are done only when it passes.

RULES:
- BEHAVIOR-PRESERVING ONLY. Move code, split files, update imports and
  callers. No new features, no bug fixes, no API changes, no cleanup that
  is not required by the plan.
- Never weaken, delete, or edit an existing test to make it pass. A red gate
  means the refactor is wrong, not the test.
- Do not run any git commands that commit, push, branch, or merge; the
  orchestrator owns git. Read-only git (status, diff, log) is fine.
- Work only inside the current directory.

REPOSITORY INVARIANTS (obey these):
${INVARIANTS_CONTENT:-None provided.}
EOF
}

# _yt_refactor_generate <out> <tasks> <files> <reason> <tasks-tsv> — one
# headless PLANNER_MODEL call that writes the refactor plan to <out>. Read-only
# tools: this call plans, it never edits. stdin from /dev/null like every other
# headless call here — the human's stdin belongs to the approval prompt, and an
# agent must never inherit, or stall on, it. Returns 1 (having said why) on a
# nonzero exit or an empty answer; there is no lenient path, because an empty
# "plan" would be a human approving nothing.
_yt_refactor_generate() {
  local out="$1" tasks="$2" files="$3" reason="$4" tsv="$5"
  local tmp errf prompt rc

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/yt-refactor.XXXXXX")" || {
    _yt_refactor_die "cannot create a temp dir for the refactor planner call"
    return 1
  }
  errf="$tmp/stderr"

  _yt_refactor_say "asking $CLAUDE_BIN (model: ${PLANNER_MODEL:-cli default}) for a refactor plan..."
  prompt="$(_yt_refactor_plan_prompt "$tasks" "$files" "$reason" "$tsv")"
  "$CLAUDE_BIN" -p "$prompt" \
    ${PLANNER_MODEL:+--model "$PLANNER_MODEL"} \
    --allowedTools "Read" "Glob" "Grep" </dev/null >"$out" 2>"$errf"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    _yt_refactor_die "the refactor planner exited nonzero ($rc): $CLAUDE_BIN"
    printf 'refactor planner stderr:\n' >&2
    _yt_refactor_show "$errf"
    printf 'refactor planner stdout:\n' >&2
    _yt_refactor_show "$out"
    printf 'nothing was changed: no worktree was created and %s is untouched.\n' "$BASE_BRANCH" >&2
    rm -rf "$tmp"
    return 1
  fi
  if [ ! -s "$out" ]; then
    _yt_refactor_die "the refactor planner returned no plan at all (exit 0, empty output)"
    printf 'refactor planner stderr:\n' >&2
    _yt_refactor_show "$errf"
    printf 'refusing to ask for approval of an empty plan; %s is untouched.\n' "$BASE_BRANCH" >&2
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$tmp"
  return 0
}

# _yt_refactor_ask <n> <total> — print the checkpoint and READ THE HUMAN'S
# ANSWER FROM STDIN. Anything that is not an explicit yes is a no, and so is
# EOF: `reply` is emptied first and the read's return is deliberately ignored,
# which is exactly how seed.sh reads its [y/N] base-branch confirmation, so a
# piped or closed stdin lands on the safe side by construction.
# Sets YT_REFACTOR_REASON on a rejection. Returns 0 to approve, 1 to reject.
_yt_refactor_ask() {
  local n="$1" total="$2" reply=""

  cat <<EOF

This is the one human checkpoint in the pipeline. Nothing has been changed yet.
  approve  the refactor above runs in its own worktree cut from ${BASE_BRANCH},
           the full suite runs there, and ${BASE_BRANCH} fast-forwards to it by
           exactly one commit ONLY if that suite is green.
  reject   nothing is changed at all and the run stops here.
Empty input or EOF is a reject. "edit" is deferred (SPEC.md section 9): reject,
amend the backlog or re-run to get a new plan.
EOF
  printf '%s: refactor: approve refactor %d/%d? [y/N] ' "$YT_PROG" "$n" "$total"
  read -r reply
  printf '\n'

  case "$reply" in
    y|Y|yes|YES|approve|APPROVE)
      return 0
      ;;
    e|edit|EDIT)
      YT_REFACTOR_REASON="answered \"$reply\", and edit is deferred (SPEC.md section 9); read as a rejection"
      return 1
      ;;
    "")
      YT_REFACTOR_REASON="no answer given (empty input or EOF); the gate defaults to reject"
      return 1
      ;;
    *)
      YT_REFACTOR_REASON="answered \"$reply\", which is not an approval"
      return 1
      ;;
  esac
}

# _yt_refactor_discard <toplevel> <worktree> — remove a refactor worktree whose
# work is not wanted (red suite, crashed agent, no changes). Best effort, and
# loud when it cannot: a leftover worktree is not fatal, but the human has to
# know it is there. The base branch is never involved.
_yt_refactor_discard() {
  local toplevel="$1" wt="$2"
  [ -e "$wt" ] || return 0
  if git -C "$toplevel" worktree remove --force "$wt" >/dev/null 2>&1; then
    _yt_refactor_say "worktree $wt removed (the refactor is discarded)"
    return 0
  fi
  _yt_refactor_say "could not remove the refactor worktree; remove it by hand:"
  _yt_refactor_say "  git worktree remove --force $wt"
  return 1
}

# _yt_refactor_execute <toplevel> <n> <dir> <tasks> <files> <reason> — run one
# APPROVED refactor: worktree from BASE_BRANCH, env files, agent, full suite,
# and on green the one fast-forward of BASE_BRANCH this tool ever does.
# <dir> is the group's run-dir directory, holding plan.txt and taking log and
# commit. Sets YT_REFACTOR_REASON/YT_REFACTOR_COMMIT. Returns 0 on green, 1 on
# anything else, with BASE_BRANCH untouched in every one of those cases.
_yt_refactor_execute() {
  local toplevel="$1" n="$2" dir="$3" tasks="$4" files="$5" reason="$6"
  local log="$dir/log" planfile="$dir/plan.txt"
  local wt="$WORKTREE_PARENT/yt-refactor-$n"
  local base_sha new_sha ahead prompt rc f

  : > "$log"

  if ! base_sha="$(git -C "$toplevel" rev-parse --verify --quiet "$BASE_BRANCH^{commit}")"; then
    YT_REFACTOR_REASON="base branch \"$BASE_BRANCH\" does not resolve to a commit"
    _yt_refactor_die "$YT_REFACTOR_REASON"
    return 1
  fi
  if [ -e "$wt" ]; then
    YT_REFACTOR_REASON="refactor worktree \"$wt\" already exists; cleanup: git worktree remove --force $wt"
    _yt_refactor_die "$YT_REFACTOR_REASON"
    return 1
  fi

  # --detach, not -b: the refactor has no feature branch of its own. Its commit
  # is destined for BASE_BRANCH and nowhere else, so a branch here would only be
  # a name to collide with and to clean up afterwards.
  _yt_refactor_say "worktree $wt, cut from $BASE_BRANCH ($(git -C "$toplevel" rev-parse --short "$base_sha"))"
  if ! git -C "$toplevel" worktree add --detach "$wt" "$base_sha" >>"$log" 2>&1; then
    YT_REFACTOR_REASON="git worktree add failed (see $log)"
    _yt_refactor_die "$YT_REFACTOR_REASON"
    return 1
  fi

  # Env files in, each verified git-ignored here too: the suite about to decide
  # whether BASE_BRANCH moves needs the same environment every task worktree
  # gets, and a refactor commit that carried a secret into the base branch would
  # be the worst possible place to leak one.
  for f in ${ENV_FILES:-}; do
    mkdir -p "$wt/$(dirname "$f")"
    cp "$f" "$wt/$f"
    if ! git -C "$wt" check-ignore -q "$f"; then
      YT_REFACTOR_REASON="ENV_FILES entry \"$f\" is not git-ignored in the refactor worktree; add it to .gitignore"
      _yt_refactor_die "$YT_REFACTOR_REASON"
      _yt_refactor_discard "$toplevel" "$wt"
      return 1
    fi
  done

  prompt="$(_yt_refactor_exec_prompt "$(cat "$planfile")" "$tasks" "$files")"
  _yt_refactor_say "agent: $CLAUDE_BIN (model: ${PLANNER_MODEL:-cli default})"
  (
    cd "$wt" && "$CLAUDE_BIN" -p "$prompt" \
      ${PLANNER_MODEL:+--model "$PLANNER_MODEL"} \
      --allowedTools "Edit" "Write" "Read" "Glob" "Grep" "Bash" </dev/null
  ) 2>&1 | tee -a "$log"
  rc="${PIPESTATUS[0]}"
  if [ "$rc" -ne 0 ]; then
    YT_REFACTOR_REASON="the refactor agent exited nonzero ($rc); see $log"
    _yt_refactor_die "$YT_REFACTOR_REASON"
    _yt_refactor_discard "$toplevel" "$wt"
    return 1
  fi

  # The agent was told not to commit. If it did anyway, the "exactly one
  # commit" contract below is already broken and this is the base branch we are
  # talking about: refuse rather than reason about what it did.
  if [ "$(git -C "$wt" rev-parse HEAD)" != "$base_sha" ]; then
    YT_REFACTOR_REASON="the refactor agent made its own commit(s), which it was told not to do; refusing to advance $BASE_BRANCH"
    _yt_refactor_die "$YT_REFACTOR_REASON"
    _yt_refactor_discard "$toplevel" "$wt"
    return 1
  fi
  if [ -z "$(git -C "$wt" status --porcelain)" ]; then
    YT_REFACTOR_REASON="the refactor agent changed nothing; there is no refactor to gate"
    _yt_refactor_die "$YT_REFACTOR_REASON"
    _yt_refactor_discard "$toplevel" "$wt"
    return 1
  fi

  _yt_refactor_say "gate: $TEST_CMD (in the refactor worktree)"
  ( cd "$wt" && bash -c "$TEST_CMD" ) 2>&1 | tee -a "$log"
  rc="${PIPESTATUS[0]}"
  if [ "$rc" -ne 0 ]; then
    YT_REFACTOR_REASON="the suite is RED in the refactor worktree (exit $rc); the refactor is discarded and $BASE_BRANCH is untouched"
    _yt_refactor_die "$YT_REFACTOR_REASON"
    printf 'full output: %s\n' "$log" >&2
    _yt_refactor_discard "$toplevel" "$wt"
    return 1
  fi

  # Green. Commit inside the worktree; the base branch still has not moved.
  local subject body
  subject="refactor: split $files so $(_yt_refactor_join ', ' $tasks) can run in parallel"
  body="Colliding tasks: $(_yt_refactor_join ', ' $tasks)
Shared files: $files
Conflict detector's reason: ${reason:-(none given)}

Approved by a human at the yolotown refactor gate (SPEC.md section 3.2), and
the full suite was green in the refactor worktree before $BASE_BRANCH was
fast-forwarded to this commit. Behavior-preserving by contract.

Approved refactor plan:
$(cat "$planfile")"
  git -C "$wt" add -A
  if ! git -C "$wt" commit -m "$subject" -m "$body" >>"$log" 2>&1; then
    YT_REFACTOR_REASON="git commit failed in the refactor worktree (see $log)"
    _yt_refactor_die "$YT_REFACTOR_REASON"
    _yt_refactor_discard "$toplevel" "$wt"
    return 1
  fi
  new_sha="$(git -C "$wt" rev-parse HEAD)"
  ahead="$(git -C "$toplevel" rev-list --count "$base_sha..$new_sha" 2>/dev/null)"
  if [ "$ahead" != "1" ]; then
    YT_REFACTOR_REASON="the refactor worktree is $ahead commits ahead of $BASE_BRANCH; the base advances by exactly one commit or not at all"
    _yt_refactor_die "$YT_REFACTOR_REASON"
    _yt_refactor_discard "$toplevel" "$wt"
    return 1
  fi

  # The one write to BASE_BRANCH. The run holds the base — it refused to start
  # off it, or dirty — so it cannot have moved; verified anyway, because this is
  # the single place a wrong assumption here would land on the branch everything
  # else is cut from. A base that DID move keeps its worktree: the work is
  # green and the human is handed the one command that lands it.
  local now_branch now_sha
  now_branch="$(git -C "$toplevel" rev-parse --abbrev-ref HEAD)"
  now_sha="$(git -C "$toplevel" rev-parse HEAD)"
  if [ "$now_branch" != "$BASE_BRANCH" ] || [ "$now_sha" != "$base_sha" ] \
     || [ -n "$(git -C "$toplevel" status --porcelain --untracked-files=no)" ]; then
    YT_REFACTOR_REASON="$BASE_BRANCH moved or the tree went dirty while the refactor ran (on \"$now_branch\" at $(git -C "$toplevel" rev-parse --short "$now_sha")); refusing to advance it
the refactor is green and kept at $wt; land it yourself with:
  git -C $toplevel merge --ff-only $new_sha"
    _yt_refactor_die "$YT_REFACTOR_REASON"
    return 1
  fi

  _yt_refactor_say "gate green; advancing $BASE_BRANCH by exactly this one commit (fast-forward)"
  if ! git -C "$toplevel" merge --ff-only "$new_sha" >>"$log" 2>&1; then
    YT_REFACTOR_REASON="git merge --ff-only $new_sha failed (see $log); $BASE_BRANCH is untouched
the refactor is green and kept at $wt; land it yourself with:
  git -C $toplevel merge --ff-only $new_sha"
    _yt_refactor_die "$YT_REFACTOR_REASON"
    return 1
  fi

  # Never pushed: the tool writes only to worktrees, .yolotown/ and remote
  # FEATURE branches (SPEC.md section 4). The refactor commit on the local base
  # is the human's to push, exactly like a merge they made themselves.
  printf '%s\n' "$new_sha" > "$dir/commit"
  YT_REFACTOR_COMMIT="$new_sha"
  _yt_refactor_say "$BASE_BRANCH advanced $(git -C "$toplevel" rev-parse --short "$base_sha") -> $(git -C "$toplevel" rev-parse --short "$new_sha") (not pushed; it is yours to push)"
  _yt_refactor_discard "$toplevel" "$wt"
  return 0
}

yt_refactor_gate() {
  local run="${1:-}" tsv="${2:-}"

  YT_REFACTOR_GROUPS=0
  YT_REFACTOR_DECISION="none"
  YT_REFACTOR_REASON=""
  YT_REFACTOR_COMMIT=""

  if [ -z "$run" ] || [ ! -d "$run" ]; then
    _yt_refactor_die "no run dir at ${run:-<unset>} (create it with yt_run_create first)"
    return 1
  fi
  local plan="$run/plan.json"
  if [ ! -f "$plan" ]; then
    _yt_refactor_die "no plan.json in $run; run conflict detection first (lib/plan.sh)"
    return 1
  fi
  local k
  for k in CLAUDE_BIN BASE_BRANCH TEST_CMD; do
    if [ -z "${!k:-}" ]; then
      _yt_refactor_die "$k is empty (load the config first)"
      return 1
    fi
  done

  local toplevel
  if ! toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    _yt_refactor_die "not inside a git repository"
    return 1
  fi
  : "${WORKTREE_PARENT:=$(dirname "$toplevel")}"

  local groups
  groups="$(yt_refactor_groups "$plan")" || {
    _yt_refactor_die "cannot read the collision report in $plan"
    return 1
  }

  # Read the groups into an array BEFORE the loop that asks for approvals: a
  # `while read <<< "$groups"` loop owns stdin, and stdin here is the human.
  local -a G=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && G+=("$line")
  done <<< "$groups"
  YT_REFACTOR_GROUPS="${#G[@]}"

  if [ "${#G[@]}" -eq 0 ]; then
    _yt_refactor_say "no COLLIDING-SPLITTABLE group in $plan; nothing to approve"
    return 0
  fi

  _yt_refactor_say "${#G[@]} COLLIDING-SPLITTABLE group(s) in $plan"
  _yt_refactor_say "each one is planned, printed, and stopped on for your approval (SPEC.md section 3.2)"

  local i n total="${#G[@]}" dir gtasks gfiles greason
  for i in "${!G[@]}"; do
    n=$((i + 1))
    IFS=$'\t' read -r gtasks gfiles greason <<< "${G[$i]}"

    dir="$run/refactor/$n"
    if ! mkdir -p "$dir"; then
      YT_REFACTOR_DECISION="failed"
      YT_REFACTOR_REASON="cannot create $dir"
      _yt_refactor_die "$YT_REFACTOR_REASON"
      return 1
    fi

    printf '\n'
    _yt_refactor_say "group $n/$total: $(_yt_refactor_join ' + ' $gtasks)"
    _yt_refactor_say "  shared files: $gfiles"
    _yt_refactor_say "  reason:       ${greason:-(the planner gave none)}"

    if ! _yt_refactor_generate "$dir/plan.txt" "$gtasks" "$gfiles" "$greason" "$tsv"; then
      YT_REFACTOR_DECISION="failed"
      YT_REFACTOR_REASON="no refactor plan could be generated for group $n/$total"
      printf 'failed\n' > "$dir/decision"
      printf '%s\n' "$YT_REFACTOR_REASON" > "$dir/reason"
      return 1
    fi

    printf '\n--- refactor plan %d/%d: %s ---\n' "$n" "$total" "$(_yt_refactor_join ' + ' $gtasks)"
    cat "$dir/plan.txt"
    printf -- '--- end of plan (%s) ---\n' "$dir/plan.txt"

    if ! _yt_refactor_ask "$n" "$total"; then
      YT_REFACTOR_DECISION="rejected"
      printf 'rejected\n' > "$dir/decision"
      printf '%s\n' "$YT_REFACTOR_REASON" > "$dir/reason"
      _yt_refactor_say "REJECTED: $YT_REFACTOR_REASON"
      _yt_refactor_say "nothing was changed: no worktree was created and $BASE_BRANCH is untouched"
      return 2
    fi

    _yt_refactor_say "APPROVED (group $n/$total) — executing it now"
    if ! _yt_refactor_execute "$toplevel" "$n" "$dir" "$gtasks" "$gfiles" "$greason"; then
      YT_REFACTOR_DECISION="failed"
      printf 'failed\n' > "$dir/decision"
      printf '%s\n' "$YT_REFACTOR_REASON" > "$dir/reason"
      _yt_refactor_say "group $n/$total FAILED: $YT_REFACTOR_REASON"
      _yt_refactor_say "$BASE_BRANCH is exactly where it was; do not fan out on it until this is resolved"
      return 1
    fi

    printf 'approved\n' > "$dir/decision"
    YT_REFACTOR_DECISION="approved"
    _yt_refactor_say "group $n/$total done: $BASE_BRANCH carries the refactor and the suite is green on it"
  done

  printf '\n'
  _yt_refactor_say "all $total group(s) refactored; $BASE_BRANCH is green and the colliding tasks are disjoint"
  return 0
}
