#!/usr/bin/env bash
# `yolotown run` as the whole of SPEC.md section 3, wired end to end: conflict
# detection, the gated refactor, the fan-out (with coupled groups run in order),
# the per-task gates with their lane checks, and the fan-in report.
#
# The assertions here are about ORDER and about what EXISTS when the pipeline
# stops, because that is the only thing that makes the refactor gate worth
# gating. A fan-out cannot be un-cut: once a worktree exists on a baseline a
# human had not approved, no later verdict takes it back. So:
#
#   ORDERING      the agent shim writes the KIND of every call it receives into
#                 a shared transcript, so the run's own sequence is the witness:
#                 one plan call, then the refactor plan, then the refactor
#                 execution, and only then the first task agent. Nothing about
#                 that can be satisfied by a run that planned after dispatching.
#   ABORT-BEFORE  a rejected refactor, a red one, and a planner that could not
#                 answer all stop the run with NO task worktree, NO task branch
#                 and NO task agent invocation — proven by the transcript's
#                 silence and by real git, not by what the run printed.
#   --no-plan     the planner is never invoked at all: no "plan" line in the
#                 transcript, no argv recorded at the planner seam, no plan.json
#                 in the run dir — and the run still ships the backlog.
#
# Everything else is real: real worktrees, real commits, real pushes to a real
# bare origin, a real gate per task, a real fast-forward of the base branch.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

YOLOTOWN="$YOLOTOWN_ROOT/yolotown"

# The planner seam's own argv file: a second, independent witness that the
# conflict-detection call happened (or, under --no-plan, that it did not).
PLAN_ARGV="$TMP_ROOT/planner-argv"
export FAKE_CLAUDE_PLAN_ARGV_FILE="$PLAN_ARGV"

# ---- the transcript agent shim ----------------------------------------------
# Records the KIND of every call yolotown makes through CLAUDE_BIN, in order.
# Every NON-task call is handed to the central shim (tests/fake-claude), which
# already knows how to answer it and whose FAKE_CLAUDE_*_MODE variables steer
# it; only the task agent is played here, and it makes a DIFFERENT edit per task
# so that a coupled chain's second task has something of its own to commit.
SHIM="$TMP_ROOT/wiring-claude"
cat > "$SHIM" <<'SHIM_EOF'
#!/usr/bin/env bash
set -u
kind=""
for _a in "$@"; do
  case "$_a" in
    *yolotown-agent-reachability-probe*) kind="probe"; break ;;
    *yolotown-conflict-detection-plan*)  kind="plan"; break ;;
    *yolotown-refactor-execute*)         kind="refactor-exec"; break ;;
    *yolotown-refactor-plan*)            kind="refactor-plan"; break ;;
  esac
done

PROMPT=""
NAME=""
if [ -z "$kind" ]; then
  for _a in "$@"; do
    case "$_a" in *"TASK: "*) PROMPT="$_a" ;; esac
  done
  while IFS= read -r _line; do
    case "$_line" in "TASK: "*) NAME="${_line#TASK: }"; break ;; esac
  done <<< "$PROMPT"
  [ -n "$NAME" ] || { echo "wiring shim: no TASK line in the prompt" >&2; exit 98; }
  kind="task:$NAME"
fi

printf '%s\n' "$kind" >> "${WIRING_ORDER:?wiring shim needs WIRING_ORDER}"

case "$kind" in
  task:*)
    mkdir -p src
    printf '// added by the wiring shim for %s\n' "$NAME" > "src/$NAME.js"
    # A task told to stray touches a file the plan did not predict for it,
    # which is what the gate-time lane check is supposed to notice.
    case "$PROMPT" in
      *stray-me*) printf '// outside the predicted lane\n' > "src/wandered-$NAME.js" ;;
    esac
    echo "wiring shim: $NAME edited"
    exit 0
    ;;
  *)
    exec "${FAKE_CLAUDE:?wiring shim needs FAKE_CLAUDE}" "$@"
    ;;
esac
SHIM_EOF
chmod +x "$SHIM"

# wiring_reset <label> — a fresh, empty call transcript for one run.
wiring_reset() {
  export WIRING_ORDER="$TMP_ROOT/order-$1"
  : > "$WIRING_ORDER"
  rm -f "$PLAN_ARGV"
}

# ord_index <extended-regex> — the 1-based position of the first call of that
# kind in the transcript, or 0 if it never happened.
ord_index() {
  local n
  n="$(grep -n -m1 -E "$1" "$WIRING_ORDER" 2>/dev/null | cut -d: -f1)"
  printf '%s\n' "${n:-0}"
}
ord_count() {
  local n
  n="$(grep -c -E "$1" "$WIRING_ORDER" 2>/dev/null | tr -d ' ')"
  printf '%s\n' "${n:-0}"
}
ord_all() { tr '\n' ' ' < "$WIRING_ORDER"; }

# run_yt <args...> — the entrypoint from the fixture root, stdin closed.
run_yt() {
  YT_OUT="$(cd "$REPO" && "$YOLOTOWN" "$@" </dev/null 2>&1)"
  YT_RC=$?
  SEED_OUT="$YT_OUT"   # so helpers.sh _fail prints it
}

# run_yt_input <stdin> <args...> — same, with <stdin> fed verbatim: the refactor
# gate's approval question is read from there.
run_yt_input() {
  local input="$1"; shift
  YT_OUT="$(cd "$REPO" && printf '%s' "$input" | "$YOLOTOWN" "$@" 2>&1)"
  YT_RC=$?
  SEED_OUT="$YT_OUT"
}

latest_run() { printf '%s\n' "$REPO/.yolotown/$(readlink "$REPO/.yolotown/latest")"; }

write_backlog() {
  local f="$1"; shift
  : > "$f"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$f"; done
}

# colliding_fixture <label> — a repo whose backlog collides, wired to the shim.
# alpha and beta both "rewrite the shared router" (FAKE_CLAUDE_PLAN_MODE=collide
# has them share src/shared.js); gamma is unrelated.
colliding_fixture() {
  reset_fixture
  wiring_reset "$1"
  make_fixture_repo "CLAUDE_BIN=\"$SHIM\""
  make_bare_origin
  write_backlog "$REPO/backlog.txt" \
    "alpha | rewrite the shared router" \
    "beta  | also rewrite the shared router" \
    "gamma | add an unrelated module"
  BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
  BASE_TREE="$(git -C "$REPO" rev-parse 'HEAD^{tree}')"
  export FAKE_CLAUDE_PLAN_MODE=collide
  export FAKE_CLAUDE_REFACTOR_PLAN_MODE=plan
  export FAKE_CLAUDE_REFACTOR_MODE=good
}

assert_base_untouched() {
  local label="$1"
  assert_eq "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" "main" "$label: still on the base branch"
  assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$BASE_SHA" "$label: the base tip did not move"
  assert_eq "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" "$BASE_TREE" "$label: the base tree is byte-identical"
  assert_eq "$(git -C "$REPO" status --porcelain --untracked-files=no)" "" "$label: the base tree is clean"
}

# assert_nothing_dispatched <label> <task>... — the load-bearing check of the
# abort cases: no task agent ran, and no task worktree or branch exists.
assert_nothing_dispatched() {
  local label="$1"; shift
  assert_eq "$(ord_count '^task:')" "0" "$label: no task agent was ever invoked"
  local t
  for t in "$@"; do
    assert_file_missing "$TMP_ROOT/yt-$t" "$label: $t got no worktree"
    if git -C "$REPO" rev-parse --verify --quiet "refs/heads/feature/$t" >/dev/null; then
      _fail "$label: $t must not have a branch"
    fi
  done
  assert_eq "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')" "1" \
    "$label: only the repo itself is a worktree"
}

# =============================================================================
# the whole pipeline, green: plan -> gate -> approved refactor -> fan-out
# =============================================================================
colliding_fixture full

run_yt_input 'y
' run backlog.txt
assert_eq "$YT_RC" 0 "an approved refactor followed by three green tasks exits 0"

RUN="$(latest_run)"

# 1. Conflict detection ran once, for the whole backlog, into THIS run dir.
assert_file_exists "$RUN/plan.json" "conflict detection wrote plan.json into the run dir"
assert_file_exists "$PLAN_ARGV" "the planner seam recorded the call"
assert_eq "$(ord_count '^plan$')" "1" "the planner is called exactly once for the whole backlog"
assert_contains "$YT_OUT" "COLLIDING-SPLITTABLE (2)" "the run prints the buckets it got back"
assert_contains "$YT_OUT" "src/shared.js" "...and the overlap behind them"

# 2. THE ORDER. Plan, then the human checkpoint, then the first task agent.
PLAN_AT="$(ord_index '^plan$')"
RPLAN_AT="$(ord_index '^refactor-plan$')"
REXEC_AT="$(ord_index '^refactor-exec$')"
TASK_AT="$(ord_index '^task:')"
[ "$PLAN_AT" -gt 0 ]        || _fail "the planner was never called (transcript: $(ord_all))"
[ "$PLAN_AT" -lt "$RPLAN_AT" ] || _fail "conflict detection must precede the refactor plan (transcript: $(ord_all))"
[ "$RPLAN_AT" -lt "$REXEC_AT" ] || _fail "the refactor is planned before it is executed (transcript: $(ord_all))"
[ "$REXEC_AT" -lt "$TASK_AT" ]  || _fail "no task agent may run before the refactor gate is done (transcript: $(ord_all))"
assert_contains "$YT_OUT" "approve refactor 1/1? [y/N]" "the run stopped at the one human checkpoint"

# 3. The approved refactor landed on the base branch, by exactly one commit.
NEW_SHA="$(git -C "$REPO" rev-parse HEAD)"
assert_eq "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" "main" "the run ends on the base branch"
assert_eq "$(git -C "$REPO" rev-list --count "$BASE_SHA..$NEW_SHA")" "1" \
  "the base advanced by exactly the refactor's one commit"
assert_contains "$(git -C "$REPO" log -1 --pretty=%s)" "refactor:" "that commit is the refactor"
assert_eq "$(cat "$RUN/refactor/1/decision")" "approved" "the decision is recorded in the run dir"

# 4. Every task fanned out FROM THE REFACTORED BASE, and shipped.
assert_contains "$YT_OUT" "parallel: up to 3 workers" "the disjoint tasks fan out in parallel"
for t in alpha beta gamma; do
  assert_eq "$(cat "$RUN/status/$t")" "passed" "$t passed"
  assert_contains "$(cat "$RUN/logs/$t.log")" "run: base=main" "$t was cut from the base branch"
  git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/feature/$t" >/dev/null \
    || _fail "$t should have been pushed to origin"
  git -C "$REPO" merge-base --is-ancestor "$NEW_SHA" "feature/$t" \
    || _fail "$t's branch must carry the approved refactor it was cut from"
  assert_file_exists "$TMP_ROOT/yt-$t/src/greet.js" "$t's worktree carries the refactor's files"
done

# 5. The gates ran the lane check, and the fan-in report closed the run.
assert_contains "$(cat "$RUN/logs/alpha.log")" "run: lane: inside the lane plan.json predicted" \
  "the gate checked the task against the plan's prediction"
assert_contains "$YT_OUT" "summary: 3 tasks" "the fan-in report covers the backlog"
assert_contains "$YT_OUT" "3 passed" "...and tallies the three passes"
assert_contains "$YT_OUT" "git merge --no-ff feature/gamma" "...and emits the merge commands"
ok "run: plan -> approved refactor -> fan-out -> report, in that order, all green"

# =============================================================================
# a REJECTED refactor aborts the run before any task worktree exists
# =============================================================================
colliding_fixture reject

run_yt_input 'n
' run backlog.txt
[ "$YT_RC" -ne 0 ] || _fail "a run whose refactor was rejected must exit nonzero"

RUN="$(latest_run)"
assert_file_exists "$RUN/plan.json" "conflict detection still ran (it is what found the collision)"
assert_eq "$(cat "$RUN/refactor/1/decision")" "rejected" "the rejection is recorded in the run dir"
assert_contains "$YT_OUT" "REJECTED" "the rejection is stated"
assert_contains "$YT_OUT" "ABORTED" "the run says it stopped"
assert_contains "$YT_OUT" "no task worktree was cut" "...and that nothing was dispatched"

assert_nothing_dispatched "reject" alpha beta gamma
assert_base_untouched "reject"
assert_eq "$(ord_count '^refactor-exec$')" "0" "reject: the refactor agent never ran either"

# The backlog is accounted for: every task is SKIPPED, not left pending.
for t in alpha beta gamma; do
  assert_eq "$(cat "$RUN/status/$t")" "skipped" "$t is SKIPPED, not left pending"
  assert_contains "$(cat "$RUN/logs/$t.log")" "run: skipped:" "$t's own log says why it never ran"
done
assert_contains "$YT_OUT" "3 skipped" "the report tallies the whole backlog as skipped"
assert_contains "$YT_OUT" "SKIPPED              alpha" "the report renders the skipped tasks"
ok "run: a rejected refactor stops the run with nothing cut, and says so per task"

# =============================================================================
# an APPROVED refactor whose suite goes RED: never fan out on a red baseline
# =============================================================================
colliding_fixture red
export FAKE_CLAUDE_REFACTOR_MODE=bad

run_yt_input 'y
' run backlog.txt
[ "$YT_RC" -ne 0 ] || _fail "a run whose refactor went red must exit nonzero"

RUN="$(latest_run)"
assert_eq "$(ord_count '^refactor-exec$')" "1" "the refactor agent did run — it is its work that failed"
assert_contains "$YT_OUT" "RED" "the red suite is named"
assert_contains "$YT_OUT" "ABORTED" "the run stops there"
assert_eq "$(cat "$RUN/refactor/1/decision")" "failed" "the failure is recorded in the run dir"
assert_nothing_dispatched "red refactor" alpha beta gamma
assert_base_untouched "red refactor"
ok "run: a red refactor aborts the run — the fan-out never starts on it"

# =============================================================================
# a planner that cannot answer: no plan, no gate, no dispatch
# =============================================================================
colliding_fixture planless
export FAKE_CLAUDE_PLAN_MODE=crash

run_yt run backlog.txt
[ "$YT_RC" -ne 0 ] || _fail "a run whose conflict detection failed must exit nonzero"

RUN="$(latest_run)"
assert_file_missing "$RUN/plan.json" "a failed conflict detection writes no plan.json"
assert_contains "$YT_OUT" "ABORTED" "the run stops"
assert_contains "$YT_OUT" "--no-plan" "the refusal names the flag that dispatches anyway"
assert_eq "$(ord_count '^refactor-plan$')" "0" "no refactor is planned without a plan to read"
assert_nothing_dispatched "planner crash" alpha beta gamma
assert_base_untouched "planner crash"
ok "run: a planner that cannot answer stops the run before the gate and before dispatch"

# =============================================================================
# --no-plan: the planner is NEVER invoked, and the backlog still ships
# =============================================================================
colliding_fixture noplan
# collide mode on purpose: if the planner were called at all, this backlog would
# stop at the refactor gate instead of shipping. It ships, so it was not called.
export FAKE_CLAUDE_PLAN_MODE=collide

run_yt run --no-plan backlog.txt
assert_eq "$YT_RC" 0 "--no-plan dispatches the backlog and exits 0"

RUN="$(latest_run)"
assert_eq "$(ord_count '^plan$')" "0" "--no-plan: the planner was never invoked"
assert_file_missing "$PLAN_ARGV" "--no-plan: nothing was recorded at the planner seam"
assert_file_missing "$RUN/plan.json" "--no-plan: no plan.json is written"
assert_eq "$(ord_count '^refactor-plan$')" "0" "--no-plan: the refactor gate is skipped too"
assert_not_contains "$YT_OUT" "[y/N]" "--no-plan: no human is stopped for approval"

assert_contains "$YT_OUT" "--no-plan: NO conflict detection and NO refactor gate" \
  "the run header says loudly that the pipeline was skipped"
assert_contains "$YT_OUT" "treated as DISJOINT" "...and what it did instead"

for t in alpha beta gamma; do
  assert_eq "$(cat "$RUN/status/$t")" "passed" "$t still shipped under --no-plan"
done
assert_contains "$(cat "$RUN/logs/alpha.log")" "run: lane: not checked" \
  "with no plan there is no lane to check, and the log says so"
assert_base_untouched "--no-plan"
ok "run --no-plan: no planner call, no gate, no plan.json — and the backlog ships"

# =============================================================================
# INHERENTLY-COUPLED groups run through the coupled-serial scheduler
# =============================================================================
colliding_fixture coupled
export FAKE_CLAUDE_PLAN_MODE=coupled

run_yt run backlog.txt
assert_eq "$YT_RC" 0 "a backlog with a coupled group exits 0 when every task passes"

RUN="$(latest_run)"
assert_contains "$YT_OUT" "INHERENTLY-COUPLED (2)" "the plan reports the coupled pair"
assert_contains "$YT_OUT" "run: dispatch alpha -> beta (coupled group" \
  "the coupled pair is dispatched as ONE unit, in order"
assert_contains "$YT_OUT" "run: dispatch gamma (task" "the disjoint task is dispatched on its own"
assert_eq "$(ord_count '^refactor-plan$')" "0" "a coupled collision is not a refactor checkpoint"
assert_not_contains "$YT_OUT" "[y/N]" "...so no human is stopped for it"

# The rebasing, in real git history: beta is cut from alpha, gamma from the base.
assert_contains "$(cat "$RUN/logs/alpha.log")" "run: base=main" "the first link is cut from the base branch"
assert_contains "$(cat "$RUN/logs/beta.log")" "run: base=feature/alpha" "the second link is cut from the first"
assert_contains "$(cat "$RUN/logs/gamma.log")" "run: base=main" "the independent task is cut from the base branch"
git -C "$REPO" merge-base --is-ancestor feature/alpha feature/beta \
  || _fail "beta must be built on alpha, not raced against it"
assert_eq "$(git -C "$REPO" rev-list --count main..feature/beta)" "2" "beta's branch carries alpha's commit and its own"
assert_eq "$(git -C "$REPO" rev-list --count main..feature/gamma)" "1" "gamma is independent of the coupled group"
assert_file_exists "$TMP_ROOT/yt-beta/src/alpha.js" "beta's worktree carries alpha's work"
assert_base_untouched "coupled"
ok "run: an INHERENTLY-COUPLED group runs in order through the coupled scheduler"

# --serial does not un-chain a coupled group: one agent at a time either way,
# but the group still goes through the chain scheduler, because the rebasing is
# the group's property and not the bound's.
colliding_fixture coupled-serial
export FAKE_CLAUDE_PLAN_MODE=coupled

run_yt run --serial backlog.txt
assert_eq "$YT_RC" 0 "--serial with a coupled group exits 0"
assert_contains "$YT_OUT" "serial: one at a time" "--serial still announces the serial bound"
assert_contains "$YT_OUT" "run: dispatch alpha -> beta (coupled group" "...and the group is still one dispatch unit"
assert_contains "$(cat "$(latest_run)/logs/beta.log")" "run: base=feature/alpha" \
  "...still rebased on its predecessor"
assert_base_untouched "coupled --serial"
ok "run --serial: a coupled group stays a chain, one agent at a time"

# =============================================================================
# lane checks at the gates: straying is a warning, never a failure
# =============================================================================
reset_fixture
wiring_reset lane
make_fixture_repo "CLAUDE_BIN=\"$SHIM\""
make_bare_origin
write_backlog "$REPO/backlog.txt" \
  "wanderer | please stray-me outside the predicted files" \
  "homebody | keep to the module the plan predicts"
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
BASE_TREE="$(git -C "$REPO" rev-parse 'HEAD^{tree}')"
export FAKE_CLAUDE_PLAN_MODE=disjoint

run_yt run backlog.txt
assert_eq "$YT_RC" 0 "a lane violation never fails the run"

RUN="$(latest_run)"
assert_eq "$(cat "$RUN/status/wanderer")" "passed" "the straying task still PASSED"
assert_file_exists "$RUN/warnings/wanderer" "the lane check recorded the stray"
assert_contains "$(cat "$RUN/warnings/wanderer")" "src/wandered-wanderer.js" "...naming the file it touched"
assert_file_missing "$RUN/warnings/homebody" "the task that stayed in its lane is not warned about"
assert_contains "$YT_OUT" "PASSED-WITH-WARNING  wanderer" "the report renders it as PASSED-WITH-WARNING"
assert_contains "$YT_OUT" "1 passed, 1 passed-with-warning" "the report tallies both honestly"
assert_base_untouched "lane"
ok "run: the gate's lane check warns on a stray and never fails it"

# =============================================================================
# run-one is unchanged: one task has nothing to collide with, so no planner
# =============================================================================
reset_fixture
wiring_reset runone
make_fixture_repo "CLAUDE_BIN=\"$SHIM\""
make_bare_origin
export FAKE_CLAUDE_PLAN_MODE=crash   # if run-one planned at all, this would kill it

run_yt run-one solo "Do a single small thing"
assert_eq "$YT_RC" 0 "run-one still exits 0"
assert_contains "$YT_OUT" "RESULT: PASSED" "run-one keeps seed.sh's single-task report"
assert_eq "$(ord_count '^plan$')" "0" "run-one never invokes the planner"
assert_file_missing "$PLAN_ARGV" "...and nothing reaches the planner seam"
git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/solo >/dev/null \
  || _fail "run-one should still push feature/solo"
ok "run-one: unchanged, and never pays for a planner call"

# =============================================================================
# the dispatch grouping itself (lib/plan.sh), where a run cannot reach it
# =============================================================================
. "$YOLOTOWN_ROOT/lib/plan.sh"
GROUPDIR="$TMP_ROOT/groups"
mkdir -p "$GROUPDIR"

# Two coupled collisions sharing a task are ONE chain: a task can only be cut
# from one predecessor, so dispatching it in two chains would run it twice.
cat > "$GROUPDIR/plan.json" <<'EOF'
{
  "tasks": [
    { "name": "a", "bucket": "INHERENTLY-COUPLED", "files": ["src/x.js"] },
    { "name": "b", "bucket": "INHERENTLY-COUPLED", "files": ["src/x.js"] },
    { "name": "c", "bucket": "INHERENTLY-COUPLED", "files": ["src/x.js"] },
    { "name": "d", "bucket": "DISJOINT", "files": ["src/d.js"] }
  ],
  "collisions": [
    { "tasks": ["a", "b"], "files": ["src/x.js"], "bucket": "INHERENTLY-COUPLED", "reason": "same state machine" },
    { "tasks": ["b", "c"], "files": ["src/x.js"], "bucket": "INHERENTLY-COUPLED", "reason": "and c too" }
  ]
}
EOF
PLAN_GROUPS="$(yt_plan_groups "$GROUPDIR/plan.json" | tr '\t' ' ' | tr '\n' '|')"
assert_eq "$PLAN_GROUPS" "1 a|1 b|1 c|0 d|" "overlapping coupled collisions merge into one chain; disjoint stays alone"

# A COLLIDING-SPLITTABLE group is NOT a chain: by dispatch time the refactor
# gate has made those tasks disjoint, or the run never got here.
cat > "$GROUPDIR/plan.json" <<'EOF'
{
  "tasks": [
    { "name": "p", "bucket": "COLLIDING-SPLITTABLE", "files": ["src/s.js"] },
    { "name": "q", "bucket": "COLLIDING-SPLITTABLE", "files": ["src/s.js"] }
  ],
  "collisions": [
    { "tasks": ["p", "q"], "files": ["src/s.js"], "bucket": "COLLIDING-SPLITTABLE", "reason": "splittable" }
  ]
}
EOF
PLAN_GROUPS="$(yt_plan_groups "$GROUPDIR/plan.json" | tr '\t' ' ' | tr '\n' '|')"
assert_eq "$PLAN_GROUPS" "0 p|0 q|" "a refactored-apart pair fans out as two independent tasks"

if yt_plan_groups "$TMP_ROOT/nope.json" 2>/dev/null; then
  _fail "yt_plan_groups must refuse a plan file that does not exist"
fi
ok "yt_plan_groups: coupled chains merge, splittable pairs fan out, bad input refused"

unset FAKE_CLAUDE_PLAN_MODE FAKE_CLAUDE_REFACTOR_PLAN_MODE FAKE_CLAUDE_REFACTOR_MODE
unset FAKE_CLAUDE_PLAN_ARGV_FILE WIRING_ORDER

echo "run-wiring: all cases passed"
