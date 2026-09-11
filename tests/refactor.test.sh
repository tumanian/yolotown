#!/usr/bin/env bash
# lib/refactor.sh: the gated refactor stage (SPEC.md section 3.2).
#
# This is the one human checkpoint in the pipeline and the one place the tool
# ever writes to BASE_BRANCH, so the assertions here are about what the base
# branch looks like AFTERWARDS, proven with real git, not about what the gate
# printed:
#
#   reject / EOF / anything-but-yes  -> nothing happens at all. No refactor
#                                       agent is invoked, no worktree is cut,
#                                       BASE_BRANCH is byte-identical.
#   approve + red suite              -> BASE_BRANCH is STILL byte-identical
#                                       (same sha, same tree, clean), and the
#                                       refactor worktree is gone.
#   approve + green suite            -> BASE_BRANCH advanced by EXACTLY ONE
#                                       commit, that commit's parent is the old
#                                       tip (a real fast-forward), and the suite
#                                       is green on it.
#
# The gate's two agent calls go through their own shim seams, so a test can
# approve a plan and then make the execution go red; the last section pins that
# independence — and the independence from the task agent's own mode — down.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Four seams, recorded separately. The two refactor ones are what this file is
# about; PLAN_ARGV proves the conflict detector is still its own call, and
# TASK_ARGV proves the gate never runs a TASK agent.
PLAN_ARGV="$TMP_ROOT/planner-argv"
RPLAN_ARGV="$TMP_ROOT/refactor-planner-argv"
REXEC_ARGV="$TMP_ROOT/refactor-exec-argv"
TASK_ARGV="$TMP_ROOT/task-argv"
export FAKE_CLAUDE_PLAN_ARGV_FILE="$PLAN_ARGV"
export FAKE_CLAUDE_REFACTOR_PLAN_ARGV_FILE="$RPLAN_ARGV"
export FAKE_CLAUDE_REFACTOR_ARGV_FILE="$REXEC_ARGV"
export FAKE_CLAUDE_ARGV_FILE="$TASK_ARGV"

# The gate as `run` will call it: config, parsed backlog, a run dir, conflict
# detection into plan.json, then the gate itself — stdin left alone, because
# stdin IS the feature.
GATE_SCRIPT='
set -uo pipefail
. "$1/lib/config.sh"
. "$1/lib/rundir.sh"
. "$1/lib/tasks.sh"
. "$1/lib/plan.sh"
. "$1/lib/refactor.sh"
yt_load_config || exit 9
parsed="$(yt_parse_tasks "$2")" || exit 9
run="$(yt_run_create "$PWD/.yolotown")" || exit 9
if [ -n "$INVARIANTS_FILE" ]; then INVARIANTS_CONTENT="$(cat "$INVARIANTS_FILE")"; else INVARIANTS_CONTENT="None provided."; fi
WORKTREE_PARENT="$(dirname "$PWD")"
yt_plan "$run" "$parsed" >/dev/null || exit 9
yt_refactor_gate "$run" "$parsed"
'

write_backlog() {
  local f="$1"; shift
  : > "$f"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$f"; done
}

# run_gate <stdin> [tasks-file] — run the gate in $REPO with <stdin> fed to it
# verbatim; the literal string --eof means stdin is closed (no input at all).
# Sets GATE_RC, GATE_OUT and RUN (the run dir it used).
run_gate() {
  local input="$1" tasks="${2:-backlog.txt}"
  rm -f "$PLAN_ARGV" "$RPLAN_ARGV" "$REXEC_ARGV" "$TASK_ARGV"
  if [ "$input" = "--eof" ]; then
    GATE_OUT="$(cd "$REPO" && bash -c "$GATE_SCRIPT" _ "$YOLOTOWN_ROOT" "$tasks" </dev/null 2>&1)"
  else
    GATE_OUT="$(cd "$REPO" && printf '%s' "$input" | bash -c "$GATE_SCRIPT" _ "$YOLOTOWN_ROOT" "$tasks" 2>&1)"
  fi
  GATE_RC=$?
  SEED_OUT="$GATE_OUT"   # so helpers.sh _fail prints it
  RUN="$REPO/.yolotown/$(readlink "$REPO/.yolotown/latest" 2>/dev/null)"
}

# snapshot_base — remember everything about BASE_BRANCH that must not change.
snapshot_base() {
  BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
  BASE_TREE="$(git -C "$REPO" rev-parse 'HEAD^{tree}')"
}

# assert_base_untouched <label> — the load-bearing assertion of the whole file:
# BASE_BRANCH is byte-identical to what snapshot_base recorded.
assert_base_untouched() {
  local label="$1"
  assert_eq "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" "main" \
    "$label: still checked out on the base branch"
  assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$BASE_SHA" \
    "$label: the base branch tip did not move"
  assert_eq "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" "$BASE_TREE" \
    "$label: the base branch tree is byte-identical"
  assert_eq "$(git -C "$REPO" status --porcelain --untracked-files=no)" "" \
    "$label: the base working tree is clean"
}

# assert_no_worktrees <label> — no refactor worktree was left behind anywhere.
assert_no_worktrees() {
  local label="$1"
  assert_eq "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')" "1" \
    "$label: only the repo itself is a worktree"
  [ -z "$(ls -d "$TMP_ROOT"/yt-* 2>/dev/null)" ] \
    || _fail "$label: a yt-* worktree directory was left behind"
}

# fresh_fixture — a repo with a colliding backlog, ready for one gate run.
# PLANNER_MODEL is set because SPEC.md 3.2 says BOTH refactor calls run on it.
fresh_fixture() {
  reset_fixture
  make_fixture_repo 'PLANNER_MODEL="planner-model-x"'
  write_backlog "$REPO/backlog.txt" \
    "alpha | rewrite the shared router" \
    "beta  | also rewrite the shared router" \
    "gamma | add an unrelated module"
  snapshot_base
  export FAKE_CLAUDE_PLAN_MODE=collide
  export FAKE_CLAUDE_REFACTOR_PLAN_MODE=plan
  export FAKE_CLAUDE_REFACTOR_MODE=good
}

# =============================================================================
# reject: the gate stops and nothing at all happened
# =============================================================================
fresh_fixture
run_gate 'n
'
assert_eq "$GATE_RC" 2 "a rejected refactor returns 2 (the expected no, not an error)"
assert_contains "$GATE_OUT" "COLLIDING-SPLITTABLE group" "the gate says what it found"
assert_contains "$GATE_OUT" "group 1/1: alpha + beta" "the group names its colliding tasks"
assert_contains "$GATE_OUT" "src/shared.js" "the group names the shared file"
assert_contains "$GATE_OUT" "approve refactor 1/1? [y/N]" "the gate stops for approval"
assert_contains "$GATE_OUT" "REJECTED" "the rejection is stated"
assert_contains "$GATE_OUT" "nothing was changed" "the rejection says nothing was changed"

assert_file_exists "$RPLAN_ARGV" "a plan was generated to show the human"
assert_file_missing "$REXEC_ARGV" "reject: the refactor agent is never invoked"
assert_file_missing "$TASK_ARGV" "reject: no task agent is invoked either"
assert_base_untouched "reject"
assert_no_worktrees "reject"
assert_eq "$(cat "$RUN/refactor/1/decision")" "rejected" "the decision is recorded in the run dir"
assert_contains "$(cat "$RUN/refactor/1/reason")" "not an approval" "the reason is recorded beside it"
assert_file_exists "$RUN/refactor/1/plan.txt" "the plan the human saw is kept, verbatim"
ok "refactor: a rejection changes nothing and records why"

# =============================================================================
# the plan itself: printed before the question, generated read-only, PLANNER_MODEL
# =============================================================================
assert_contains "$GATE_OUT" "--- refactor plan 1/1: alpha + beta ---" "the plan is printed under its own banner"
assert_contains "$GATE_OUT" "SPLIT" "the plan's SPLIT section reaches the human"
assert_contains "$GATE_OUT" "MOVES" "...and MOVES"
assert_contains "$GATE_OUT" "UPDATES" "...and UPDATES"
assert_contains "$GATE_OUT" "WHY" "...and WHY: which files each task touches afterwards"
assert_contains "$GATE_OUT" "src/shared-alpha.js" "the plan names what the shared file splits into"
assert_contains "$(cat "$RUN/refactor/1/plan.txt")" "SPLIT" "the same plan is on disk"

RPLAN="$(cat "$RPLAN_ARGV")"
assert_contains "$RPLAN" "yolotown-refactor-plan" "the plan call carries its own marker"
assert_not_contains "$RPLAN" "yolotown-refactor-execute" "it is not the execution call"
assert_not_contains "$RPLAN" "yolotown-conflict-detection-plan" "nor the conflict detector's"
assert_contains "$RPLAN" "TASK alpha | rewrite the shared router" "the colliding tasks' descriptions reach the planner"
assert_contains "$RPLAN" "TASK beta" "both colliding tasks are sent"
assert_not_contains "$RPLAN" "TASK gamma" "the uninvolved DISJOINT task is not"
assert_contains "$RPLAN" "FILE src/shared.js" "the shared file is sent"
assert_contains "$RPLAN" "PLAN ONLY" "the planner is told to change nothing"
assert_contains "$RPLAN" "planner-model-x" "the plan runs on PLANNER_MODEL (SPEC.md 3.2)"
assert_contains "$RPLAN" "Read" "the plan call gets read-only tools"
assert_not_contains "$RPLAN" "Write" "a planning call can never edit anything"
ok "refactor: the plan is generated read-only on PLANNER_MODEL and printed before the question"

# =============================================================================
# EOF defaults to reject — exactly as seed.sh's [y/N] does
# =============================================================================
fresh_fixture
run_gate --eof
assert_eq "$GATE_RC" 2 "EOF on stdin is a rejection"
assert_contains "$GATE_OUT" "empty input or EOF" "the gate says it defaulted to reject"
assert_file_missing "$REXEC_ARGV" "EOF: the refactor agent is never invoked"
assert_base_untouched "eof"
assert_no_worktrees "eof"
assert_eq "$(cat "$RUN/refactor/1/decision")" "rejected" "EOF is recorded as a rejection"
ok "refactor: EOF defaults to reject, changing nothing"

fresh_fixture
run_gate '
'
assert_eq "$GATE_RC" 2 "a bare newline is a rejection"
assert_contains "$GATE_OUT" "empty input or EOF" "empty input takes the same default"
assert_base_untouched "empty input"
assert_no_worktrees "empty input"
ok "refactor: empty input defaults to reject too"

# Anything that is not an explicit yes is a no — including a typo'd yes.
fresh_fixture
run_gate 'yeah, go ahead
'
assert_eq "$GATE_RC" 2 "an answer that is not an approval is a rejection"
assert_contains "$GATE_OUT" "which is not an approval" "the rejection quotes what was answered"
assert_file_missing "$REXEC_ARGV" "no refactor agent runs on a non-answer"
assert_base_untouched "non-answer"
ok "refactor: only an explicit yes approves"

# `edit` is deferred (SPEC.md section 9): read as a rejection that says so.
fresh_fixture
run_gate 'edit
'
assert_eq "$GATE_RC" 2 "edit is a rejection"
assert_contains "$GATE_OUT" "edit is deferred" "the gate says edit is deferred"
assert_contains "$GATE_OUT" "SPEC.md section 9" "...and where that is written down"
assert_file_missing "$REXEC_ARGV" "edit executes nothing"
assert_base_untouched "edit"
ok "refactor: edit is deferred and reads as a rejection"

# =============================================================================
# approve + GREEN: the base advances by exactly one commit, and only here
# =============================================================================
fresh_fixture
# The TASK agent's mode is crash for this whole run: the refactor calls have
# their own seams, so a task agent that would explode must not matter here.
export FAKE_CLAUDE_MODE=crash
run_gate 'y
'
assert_eq "$GATE_RC" 0 "an approved, green refactor returns 0"
assert_contains "$GATE_OUT" "APPROVED" "the approval is stated"
assert_contains "$GATE_OUT" "gate green" "the suite ran in the refactor worktree"
assert_contains "$GATE_OUT" "advanced" "the gate reports the base moving"
assert_contains "$GATE_OUT" "fast-forward" "...by fast-forward"

NEW_SHA="$(git -C "$REPO" rev-parse HEAD)"
[ "$NEW_SHA" != "$BASE_SHA" ] || _fail "green: the base branch should have advanced"
assert_eq "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" "main" "green: still on the base branch"
assert_eq "$(git -C "$REPO" rev-list --count "$BASE_SHA..$NEW_SHA")" "1" \
  "green: the base advanced by EXACTLY one commit"
assert_eq "$(git -C "$REPO" rev-parse 'HEAD^')" "$BASE_SHA" \
  "green: that commit's parent is the old tip — a real fast-forward, no merge commit"
assert_eq "$(git -C "$REPO" status --porcelain --untracked-files=no)" "" \
  "green: the base working tree is clean afterwards"
assert_contains "$(git -C "$REPO" log -1 --pretty=%s)" "refactor:" "the commit says it is a refactor"
assert_contains "$(git -C "$REPO" log -1 --pretty=%B)" "Approved by a human" \
  "the commit records the human approval that permitted it"
assert_contains "$(git -C "$REPO" log -1 --pretty=%B)" "SPLIT" \
  "the approved plan travels in the commit body"

# The base is green: that is the whole point of gating on the suite first.
( cd "$REPO" && ./check.sh >/dev/null 2>&1 ) || _fail "green: the base suite must be green after the refactor"
assert_file_exists "$REPO/src/greet.js" "green: the refactor's files are on the base branch"
assert_eq "$(git -C "$REPO" ls-files .env)" "" "green: the env file was never committed"

assert_no_worktrees "green"
assert_eq "$(cat "$RUN/refactor/1/decision")" "approved" "the approval is recorded"
assert_eq "$(cat "$RUN/refactor/1/commit")" "$NEW_SHA" "the run dir records the commit the base now carries"
assert_file_exists "$RUN/refactor/1/log" "the refactor agent's and the suite's output is kept"
assert_contains "$(cat "$RUN/refactor/1/log")" "app ok" "the log carries the suite's own output"
unset FAKE_CLAUDE_MODE
ok "refactor: an approved green refactor advances the base by exactly one commit"

# The execution call: its own marker, its own tools, the approved plan quoted in.
REXEC="$(cat "$REXEC_ARGV")"
assert_contains "$REXEC" "yolotown-refactor-execute" "the execution call carries its own marker"
assert_contains "$REXEC" "SPLIT" "the approved plan is quoted into the execution prompt"
assert_contains "$REXEC" "Follow it. Do not redesign it" "the executor follows the approved plan"
assert_contains "$REXEC" "BEHAVIOR-PRESERVING ONLY" "behavior preservation is in the prompt (SPEC.md 3.2)"
assert_contains "$REXEC" "Never weaken, delete, or edit an existing test" "so is the never-weaken-a-test rule"
assert_contains "$REXEC" "FIXTURE-INVARIANT" "the repo invariants are injected, as for any agent"
assert_contains "$REXEC" "planner-model-x" "the execution runs on PLANNER_MODEL too"
assert_contains "$REXEC" "Write" "the executor gets editing tools"
assert_file_missing "$TASK_ARGV" "the gate never invokes a TASK agent"
ok "refactor: the execution call is distinguishable and carries the approved plan"

# =============================================================================
# approve + RED: discard the worktree, leave the base byte-identical
# =============================================================================
fresh_fixture
export FAKE_CLAUDE_REFACTOR_MODE=bad
run_gate 'y
'
[ "$GATE_RC" -ne 0 ] || _fail "red: an approved refactor whose suite is red must fail the gate"
assert_eq "$GATE_RC" 1 "red: a failed refactor returns 1"
assert_contains "$GATE_OUT" "RED" "the red suite is named as such"
assert_contains "$GATE_OUT" "untouched" "the gate says the base branch is untouched"
assert_contains "$GATE_OUT" "do not fan out" "...and that fanning out on it is not allowed"
assert_file_exists "$REXEC_ARGV" "red: the refactor agent did run (it is its work that failed)"
assert_base_untouched "red"
assert_no_worktrees "red: the refactor worktree is discarded"
assert_eq "$(cat "$RUN/refactor/1/decision")" "failed" "the failure is recorded"
assert_contains "$(cat "$RUN/refactor/1/log")" "not valid javascript" \
  "red: the full output survives the discarded worktree"
ok "refactor: a red suite discards the refactor and leaves the base byte-identical"

# An agent that crashes, and one that changes nothing, are the same story.
fresh_fixture
export FAKE_CLAUDE_REFACTOR_MODE=crash
run_gate 'y
'
assert_eq "$GATE_RC" 1 "a crashed refactor agent fails the gate"
assert_contains "$GATE_OUT" "exited nonzero" "the failure names the crash"
assert_base_untouched "crashed agent"
assert_no_worktrees "crashed agent"

fresh_fixture
export FAKE_CLAUDE_REFACTOR_MODE=noop
run_gate 'y
'
assert_eq "$GATE_RC" 1 "a refactor agent that changes nothing fails the gate"
assert_contains "$GATE_OUT" "changed nothing" "the failure says what happened"
assert_base_untouched "noop agent"
assert_no_worktrees "noop agent"
ok "refactor: a crashed or empty-handed refactor agent leaves the base untouched"

# =============================================================================
# env files: seeded into the refactor worktree, and never committable
# =============================================================================
# The suite that decides whether BASE_BRANCH moves needs the same environment
# every task worktree gets — and a refactor commit is the worst possible place
# to leak a secret, since it lands on the base branch. A .env that is not
# git-ignored is refused before the agent is ever invoked.
FIXTURE_GITIGNORE='.yolotown/'
fresh_fixture
FIXTURE_GITIGNORE=''
run_gate 'y
'
assert_eq "$GATE_RC" 1 "an un-ignored ENV_FILES entry fails the gate"
assert_contains "$GATE_OUT" "not git-ignored in the refactor worktree" "the refusal names the problem"
assert_contains "$GATE_OUT" ".gitignore" "...and the fix"
assert_file_missing "$REXEC_ARGV" "the refactor agent never runs on an unsafe worktree"
assert_base_untouched "un-ignored env file"
assert_no_worktrees "un-ignored env file"
ok "refactor: env files are seeded into the refactor worktree and verified git-ignored there"

# =============================================================================
# a plan that cannot be generated: refuse BEFORE asking a human anything
# =============================================================================
fresh_fixture
export FAKE_CLAUDE_REFACTOR_PLAN_MODE=crash
run_gate 'y
'
assert_eq "$GATE_RC" 1 "a crashed refactor planner fails the gate"
assert_contains "$GATE_OUT" "exited nonzero" "the refusal names the planner's exit"
assert_not_contains "$GATE_OUT" "[y/N]" "no approval is asked for a plan that does not exist"
assert_file_missing "$REXEC_ARGV" "nothing is executed"
assert_base_untouched "planner crash"
assert_no_worktrees "planner crash"

fresh_fixture
export FAKE_CLAUDE_REFACTOR_PLAN_MODE=silent
run_gate 'y
'
assert_eq "$GATE_RC" 1 "an empty plan fails the gate"
assert_contains "$GATE_OUT" "no plan at all" "the refusal says the plan was empty"
assert_not_contains "$GATE_OUT" "[y/N]" "a human is never asked to approve an empty plan"
assert_base_untouched "empty plan"
assert_no_worktrees "empty plan"
ok "refactor: a plan that cannot be generated refuses before any approval is asked"

# A plan may legitimately say "this cannot be split" — that is an answer for the
# human to reject, not an error, so it is printed and stopped on like any other.
fresh_fixture
export FAKE_CLAUDE_REFACTOR_PLAN_MODE=splitless
run_gate 'n
'
assert_eq "$GATE_RC" 2 "a splitless plan is still put to the human"
assert_contains "$GATE_OUT" "None possible" "the honest answer is printed verbatim"
assert_contains "$GATE_OUT" "[y/N]" "...and still stopped on"
assert_base_untouched "splitless"
ok "refactor: a plan saying the collision is not splittable is still the human's call"

# =============================================================================
# nothing to gate: no prompt, no call, no fuss
# =============================================================================
fresh_fixture
export FAKE_CLAUDE_PLAN_MODE=disjoint
run_gate 'y
'
assert_eq "$GATE_RC" 0 "a disjoint plan passes the gate untouched"
assert_contains "$GATE_OUT" "nothing to approve" "the gate says there was nothing to gate"
assert_not_contains "$GATE_OUT" "[y/N]" "a human is never stopped for a backlog with no collisions"
assert_file_missing "$RPLAN_ARGV" "no refactor plan is paid for"
assert_file_missing "$REXEC_ARGV" "no refactor is executed"
assert_base_untouched "disjoint"
assert_no_worktrees "disjoint"
ok "refactor: a disjoint plan is not a checkpoint"

# INHERENTLY-COUPLED is a collision, but not a splittable one: the coupled
# scheduler runs those in order (SPEC.md 3.1), the refactor gate ignores them.
fresh_fixture
export FAKE_CLAUDE_PLAN_MODE=coupled
run_gate 'y
'
assert_eq "$GATE_RC" 0 "an INHERENTLY-COUPLED collision is not gated"
assert_contains "$GATE_OUT" "nothing to approve" "the gate leaves coupled groups alone"
assert_file_missing "$RPLAN_ARGV" "no refactor is planned for a coupled group"
assert_base_untouched "coupled"
assert_no_worktrees "coupled"
ok "refactor: only COLLIDING-SPLITTABLE groups are gated"

# =============================================================================
# the library's own reader, and its refusals
# =============================================================================
fresh_fixture
run_gate --eof   # a rejected run, purely to get a real plan.json on disk
# Not named GROUPS: that is a bash special variable (the caller's group ids),
# and assigning to it is silently ignored.
COLL_GROUPS="$(bash -c '. "$1/lib/refactor.sh"; yt_refactor_groups "$2"' _ "$YOLOTOWN_ROOT" "$RUN/plan.json" | tr '\t' ' ')"
assert_contains "$COLL_GROUPS" "alpha beta" "yt_refactor_groups lists the colliding tasks"
assert_contains "$COLL_GROUPS" "src/shared.js" "...with the shared files"
assert_eq "$(printf '%s\n' "$COLL_GROUPS" | wc -l | tr -d ' ')" "1" "one group, once"

GATE_OUT="$(cd "$REPO" && bash -c '
  . "$1/lib/config.sh"; . "$1/lib/refactor.sh"
  yt_load_config
  yt_refactor_gate "$2"
' _ "$YOLOTOWN_ROOT" "$REPO/.yolotown" 2>&1)"
GATE_RC=$?
SEED_OUT="$GATE_OUT"
[ "$GATE_RC" -ne 0 ] || _fail "the gate must refuse a run dir with no plan.json"
assert_contains "$GATE_OUT" "no plan.json" "the refusal names what is missing"
assert_contains "$GATE_OUT" "conflict detection" "...and what to run first"
ok "refactor: the reader and the gate's own preconditions fail loudly"

unset FAKE_CLAUDE_PLAN_MODE FAKE_CLAUDE_REFACTOR_PLAN_MODE FAKE_CLAUDE_REFACTOR_MODE
unset FAKE_CLAUDE_PLAN_ARGV_FILE FAKE_CLAUDE_REFACTOR_PLAN_ARGV_FILE
unset FAKE_CLAUDE_REFACTOR_ARGV_FILE FAKE_CLAUDE_ARGV_FILE

echo "refactor: all cases passed"
