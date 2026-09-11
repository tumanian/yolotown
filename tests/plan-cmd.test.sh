#!/usr/bin/env bash
# The `yolotown plan` subcommand: SPEC.md section 2's dry run, now backed by the
# real conflict detection of lib/plan.sh (SPEC.md 3.1) instead of a parse-and-
# list placeholder.
#
# Two things are being tested here, and the second matters more than the first.
#
#   1. The RENDERING: all three buckets, always, every task under its own with
#      the files predicted for it, and under a colliding bucket the overlap
#      groups — tasks, shared files, the planner's reason — that produced it.
#      lib/plan.sh's own tests already prove the bucketing; these prove a human
#      can read the answer.
#   2. The DRY RUN: plan is the command you run BEFORE committing to a fan-out,
#      so it must dispatch nothing. No worktree, no branch, no task agent, no
#      status transitions, no push — and on a failure, no plan.json either.
#      That promise is asserted from the outside (real git, real filesystem)
#      rather than from plan's own output.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

YOLOTOWN="$YOLOTOWN_ROOT/yolotown"

# The two shim seams, recorded separately: PLAN_ARGV proves the planner WAS
# called, TASK_ARGV proves the task agent was NOT.
PLAN_ARGV="$TMP_ROOT/planner-argv"
TASK_ARGV="$TMP_ROOT/task-argv"
export FAKE_CLAUDE_PLAN_ARGV_FILE="$PLAN_ARGV"
export FAKE_CLAUDE_ARGV_FILE="$TASK_ARGV"

# run_yt <args...> — invoke the entrypoint from the fixture repo root, stdin
# closed; sets YT_OUT and YT_RC. Clears both argv records first so every
# assertion about them describes THIS invocation.
run_yt() {
  rm -f "$PLAN_ARGV" "$TASK_ARGV"
  YT_OUT="$(cd "$REPO" && "$YOLOTOWN" "$@" </dev/null 2>&1)"
  YT_RC=$?
  SEED_OUT="$YT_OUT"   # so helpers.sh _fail prints it
}

write_backlog() {
  local f="$1"; shift
  : > "$f"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$f"; done
}

# assert_dispatched_nothing <label> — the load-bearing assertion of this file.
# Everything `run` would have created, proven absent with real git.
assert_dispatched_nothing() {
  local label="$1"
  assert_eq "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')" "1" \
    "$label: plan creates no worktree (only the repo itself is listed)"
  assert_eq "$(git -C "$REPO" branch --list | wc -l | tr -d ' ')" "1" \
    "$label: plan creates no branch (only the base branch exists)"
  assert_eq "$(git -C "$REPO" branch --list 'feature/*' | wc -l | tr -d ' ')" "0" \
    "$label: no BRANCH_PREFIX branch was cut"
  [ -z "$(ls -d "$TMP_ROOT"/yt-* 2>/dev/null)" ] \
    || _fail "$label: plan left a yt-<name> worktree directory behind"
  assert_file_missing "$TASK_ARGV" "$label: the task agent was never invoked"
  assert_eq "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" "main" \
    "$label: plan does not move off the base branch"
  # HEAD is byte-identical: plan committed nothing to the base branch.
  assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$BASE_SHA" \
    "$label: the base branch is exactly where it was"
}

# base_sha — remember the baseline commit so the assertion above can prove it
# never moved.
snapshot_base() { BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"; }

# =============================================================================
# a fully disjoint backlog: three buckets printed, nothing dispatched
# =============================================================================
make_fixture_repo   # no origin on purpose: plan must never want one
snapshot_base
write_backlog "$REPO/backlog.txt" \
  "# the whole backlog" \
  "alpha | add the alpha module" \
  "beta  | add the beta module" \
  "gamma | add the gamma module"

export FAKE_CLAUDE_PLAN_MODE=disjoint
run_yt plan backlog.txt
assert_eq "$YT_RC" 0 "plan over a disjoint backlog exits 0"

assert_contains "$YT_OUT" "DISJOINT (3)" "the DISJOINT bucket is printed with its count"
assert_contains "$YT_OUT" "alpha" "the first task appears"
assert_contains "$YT_OUT" "src/alpha.js" "a task is shown with the files predicted for it"
assert_contains "$YT_OUT" "src/gamma.js" "every task's prediction is shown, not just the first"
# The empty buckets still print: "nothing collided" is the answer a human came for.
assert_contains "$YT_OUT" "COLLIDING-SPLITTABLE (0)" "an empty colliding bucket still prints"
assert_contains "$YT_OUT" "INHERENTLY-COUPLED (0)"   "an empty coupled bucket still prints"
assert_contains "$YT_OUT" "(none)" "an empty bucket says so explicitly"
assert_contains "$YT_OUT" "summary: 3 tasks" "plan summarizes the whole backlog"
assert_not_contains "$YT_OUT" "Stage 3" "conflict detection is no longer deferred"

# The planner ran exactly once, through its own seam.
assert_file_exists "$PLAN_ARGV" "plan invokes the conflict detector"
assert_contains "$(cat "$PLAN_ARGV")" "yolotown-conflict-detection-plan" \
  "the invocation plan made is the planner one"
assert_contains "$(cat "$PLAN_ARGV")" "TASK alpha | add the alpha module" \
  "the parsed backlog reached the planner"

assert_dispatched_nothing "disjoint"
ok "plan: a disjoint backlog renders all three buckets and dispatches nothing"

# =============================================================================
# the run dir: plan.json, and nothing else
# =============================================================================
RUN="$REPO/.yolotown/$(readlink "$REPO/.yolotown/latest")"
assert_file_exists "$RUN/plan.json" "plan writes plan.json into the run dir"
assert_contains "$YT_OUT" "$(basename "$RUN")/plan.json" "plan prints where it put the plan"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$RUN/plan.json" \
  || _fail "plan.json is not parseable JSON"
# No task is registered: plan ran nothing, so nothing is pending, running or
# skipped. The run dir's shape is standard; its per-task state is empty.
assert_eq "$(ls -1 "$RUN/status" | wc -l | tr -d ' ')"  "0" "no task status is written by a plan"
assert_eq "$(ls -1 "$RUN/logs" | wc -l | tr -d ' ')"    "0" "no task log is written by a plan"
assert_eq "$(ls -1 "$RUN/results" | wc -l | tr -d ' ')" "0" "no task result is written by a plan"
assert_eq "$(ls -1 "$RUN" | LC_ALL=C sort | tr '\n' ' ')" "logs plan.json results status " \
  "the run dir holds plan.json and the empty standard subdirs, nothing more"

# A plan-only run dir is a legal input to the other readers: neither may blow up
# on a run with no tasks in it.
run_yt clean
assert_eq "$YT_RC" 0 "clean over a plan-only run exits 0"
assert_contains "$YT_OUT" "nothing to clean" "clean reports a plan left no worktrees"
run_yt status
assert_eq "$YT_RC" 0 "status over a plan-only run exits 0"
assert_contains "$YT_OUT" "no tasks registered" "status says a plan registered no tasks"
ok "plan: the run dir carries plan.json only, and reads back cleanly"

# =============================================================================
# a detected collision: the overlap that produced the bucket is shown
# =============================================================================
reset_fixture
make_fixture_repo
snapshot_base
write_backlog "$REPO/backlog.txt" \
  "alpha | rewrite the shared router" \
  "beta  | also rewrite the shared router" \
  "gamma | add an unrelated module"

export FAKE_CLAUDE_PLAN_MODE=collide
run_yt plan backlog.txt
assert_eq "$YT_RC" 0 "plan over a colliding backlog still exits 0: the collision IS the answer"
assert_contains "$YT_OUT" "COLLIDING-SPLITTABLE (2)" "the colliding tasks are counted in their bucket"
assert_contains "$YT_OUT" "DISJOINT (1)" "the uninvolved task stays in DISJOINT"
assert_contains "$YT_OUT" "src/shared.js" "the shared file is shown"
assert_contains "$YT_OUT" "overlap: alpha + beta" "the overlap names the tasks that collided"
assert_contains "$YT_OUT" "reason:" "the overlap carries the planner's reason"
assert_contains "$YT_OUT" "both tasks rewrite" "the reason is the planner's own words"
assert_contains "$YT_OUT" "summary: 3 tasks" "the summary covers every task"
assert_dispatched_nothing "collide"
ok "plan: a COLLIDING-SPLITTABLE group prints with the overlap behind it"

export FAKE_CLAUDE_PLAN_MODE=coupled
run_yt plan backlog.txt
assert_eq "$YT_RC" 0 "plan over a coupled backlog exits 0"
assert_contains "$YT_OUT" "INHERENTLY-COUPLED (2)" "the coupled bucket carries its tasks"
assert_contains "$YT_OUT" "COLLIDING-SPLITTABLE (0)" "the splittable bucket is empty here"
assert_contains "$YT_OUT" "overlap: alpha + beta" "the coupled group shows its overlap too"
assert_contains "$YT_OUT" "run sequentially" "the bucket explains what it means for the run"
assert_dispatched_nothing "coupled"
ok "plan: an INHERENTLY-COUPLED group prints with the overlap behind it"

# =============================================================================
# a planner that cannot be trusted: loud refusal, no plan.json, still no fan-out
# =============================================================================
reset_fixture
make_fixture_repo
snapshot_base
write_backlog "$REPO/backlog.txt" "alpha | add the alpha module" "beta | add the beta module"

export FAKE_CLAUDE_PLAN_MODE=hidden-collision
run_yt plan backlog.txt
[ "$YT_RC" -ne 0 ] || _fail "plan must exit nonzero when the plan cannot be trusted"
assert_contains "$YT_OUT" "refusing to write plan.json" "the refusal is explicit"
assert_contains "$YT_OUT" "no collision reports them together" "the refusal says what was wrong"
assert_file_missing "$REPO/.yolotown/latest/plan.json" "a refused plan writes no plan.json"
assert_contains "$YT_OUT" "rm -rf" "the failure hands over the exact cleanup command"
assert_dispatched_nothing "refused"
ok "plan: a malformed planner response refuses loudly and still dispatches nothing"

export FAKE_CLAUDE_PLAN_MODE=crash
run_yt plan backlog.txt
[ "$YT_RC" -ne 0 ] || _fail "a crashing planner must fail the plan"
assert_contains "$YT_OUT" "exited nonzero" "the refusal names the planner's exit"
assert_file_missing "$REPO/.yolotown/latest/plan.json" "a crashed planner writes no plan.json"
assert_dispatched_nothing "crashed planner"
ok "plan: a crashing planner fails the plan without dispatching anything"

# =============================================================================
# bad input fails fast, before the run dir and before the planner is paid for
# =============================================================================
reset_fixture
make_fixture_repo
snapshot_base
export FAKE_CLAUDE_PLAN_MODE=disjoint

printf 'this line has no separator\n' > "$REPO/bad.txt"
run_yt plan bad.txt
[ "$YT_RC" -ne 0 ] || _fail "plan on a malformed backlog should fail"
assert_file_missing "$REPO/.yolotown" "a malformed backlog creates no run dir"
assert_file_missing "$PLAN_ARGV" "a malformed backlog is never sent to the planner"

run_yt plan nope.txt
[ "$YT_RC" -ne 0 ] || _fail "plan on a missing tasks file should fail"
assert_contains "$YT_OUT" "tasks file not found" "the failure names the missing file"
assert_file_missing "$REPO/.yolotown" "a missing tasks file creates no run dir"

write_backlog "$REPO/empty.txt" "# only a comment" ""
run_yt plan empty.txt
[ "$YT_RC" -ne 0 ] || _fail "plan on a backlog with no tasks should fail"
assert_contains "$YT_OUT" "no tasks found" "the failure says the backlog held no tasks"
assert_file_missing "$PLAN_ARGV" "an empty backlog is never sent to the planner"

run_yt plan one.txt two.txt
[ "$YT_RC" -ne 0 ] || _fail "plan should reject two tasks files"
assert_contains "$YT_OUT" "at most one argument" "the arity refusal explains itself"
assert_dispatched_nothing "bad input"
ok "plan: bad input fails fast, before the run dir and before the planner call"

# =============================================================================
# plan defaults to tasks.txt, and answers on a tree `run` would refuse
# =============================================================================
reset_fixture
make_fixture_repo
snapshot_base
write_backlog "$REPO/tasks.txt" "alpha | add the alpha module" "beta | add the beta module"
run_yt plan
assert_eq "$YT_RC" 0 "a bare plan reads tasks.txt"
assert_contains "$YT_OUT" "tasks.txt" "the default tasks file is named in the header"
assert_contains "$YT_OUT" "DISJOINT (2)" "the default backlog is bucketed"
ok "plan: defaults to tasks.txt"

# The moment plan exists for: a human mid-edit, deciding whether to fan out.
# `run` refuses a dirty tree; plan writes nothing to it, so it answers anyway.
reset_fixture
make_fixture_repo
snapshot_base
write_backlog "$REPO/backlog.txt" "alpha | add the alpha module" "beta | add the beta module"
printf 'console.log("mid-edit");\n' >> "$REPO/src/app.js"
[ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] || _fail "fixture should be dirty here"

run_yt plan backlog.txt
assert_eq "$YT_RC" 0 "plan answers on a dirty tree (it writes nothing to it)"
assert_contains "$YT_OUT" "DISJOINT (2)" "the dirty-tree plan is a real plan"
assert_contains "$(git -C "$REPO" status --porcelain --untracked-files=no)" "src/app.js" \
  "plan left the uncommitted edit exactly where it was"
assert_dispatched_nothing "dirty tree"

# ...and on a branch that is not BASE_BRANCH, for the same reason.
git -C "$REPO" checkout -q -b scratch
run_yt plan backlog.txt
assert_eq "$YT_RC" 0 "plan answers off the base branch too"
assert_eq "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" "scratch" "plan does not move the checkout"
git -C "$REPO" checkout -q main
ok "plan: answers on a dirty tree and off the base branch, changing neither"

unset FAKE_CLAUDE_PLAN_MODE FAKE_CLAUDE_PLAN_ARGV_FILE FAKE_CLAUDE_ARGV_FILE

echo "plan-cmd: all cases passed"
