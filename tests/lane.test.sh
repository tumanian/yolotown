#!/usr/bin/env bash
# lib/lane.sh — the gate-time lane check (SPEC.md sections 2 and 3.4).
#
# The three cases the feature is defined by, each driven through the real core
# (lib/task.sh yt_run_task) against a real worktree, real commit and real diff:
#   in lane        plan.json predicted what the agent touched  -> no warning
#   strayed        the agent touched a file outside it         -> warnings/<task>
#   no prediction  no plan.json at all (a run-one)             -> no warning
#
# Plus the property that outranks all three: a lane violation NEVER fails a
# task. The strayed case asserts the same green outcome as the in-lane one —
# return 0, status passed, one commit, pushed — and only then the warning.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

. "$YOLOTOWN_ROOT/lib/config.sh"
. "$YOLOTOWN_ROOT/lib/rundir.sh"
. "$YOLOTOWN_ROOT/lib/report.sh"
. "$YOLOTOWN_ROOT/lib/task.sh"

# prepare_core — same preamble a wrapper (seed.sh / cmd_run) runs before the
# core: cd into the fixture, load its config into the globals yt_run_task
# reads, point worktrees at the temp root, hand back a fresh run dir in RUN.
prepare_core() {
  cd "$REPO" || _fail "cannot cd into fixture $REPO"
  yt_load_config
  WORKTREE_PARENT="$(dirname "$REPO")"
  if [ -n "$INVARIANTS_FILE" ]; then
    INVARIANTS_CONTENT="$(cat "$INVARIANTS_FILE")"
  else
    INVARIANTS_CONTENT="None provided."
  fi
  RUN="$(yt_run_create "$REPO/.yolotown" "$(date -u +%Y%m%dT%H%M%SZ)")" \
    || _fail "could not create run dir under $REPO/.yolotown"
}

# write_plan <run-dir> <task>:<file>[,<file>]... — drop a plan.json into the run
# dir holding exactly the given predictions, in the shape lib/plan.sh writes
# (JSON generated in node, per CLAUDE.md). This is what conflict detection
# leaves behind for the lane check to read.
write_plan() {
  local run="$1"; shift
  YT_LANE_SPEC="$*" node -e 'const spec=process.env.YT_LANE_SPEC.trim().split(/\s+/).filter(Boolean);const tasks=spec.map((s)=>{const i=s.indexOf(":");return{name:s.slice(0,i),bucket:"DISJOINT",files:s.slice(i+1).split(",").filter(Boolean)}});process.stdout.write(JSON.stringify({tasks,collisions:[]},null,2)+"\n")' \
    > "$run/plan.json" || _fail "could not write $run/plan.json"
}

# A shim that touches TWO files: one the plan will predict, one it will not.
# The stock `good` mode writes a single file, which cannot show that the
# warning names only the stray and leaves the in-lane file out of it.
make_two_file_shim() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -u
mkdir -p src docs
printf '// added by agent\nmodule.exports = { feature: true };\n' > src/feature.js
printf 'notes the task never said anything about\n' > docs/notes.md
echo "I created src/feature.js and, while I was there, docs/notes.md."
exit 0
EOF
  chmod +x "$path"
}

# =============================================================================
# unit: yt_lane_predicted answers only when there IS a prediction
# =============================================================================
make_fixture_repo
UNIT="$TMP_ROOT/unit"
mkdir -p "$UNIT"
write_plan "$UNIT" "alpha:src/a.js,lib/a.sh" "beta:src/b.js"

assert_eq "$(yt_lane_predicted "$UNIT/plan.json" alpha)" "src/a.js
lib/a.sh" "predicted files come back one per line, in plan order"
assert_eq "$(yt_lane_predicted "$UNIT/plan.json" beta)" "src/b.js" "a second task reads independently"

if yt_lane_predicted "$UNIT/plan.json" ghost >/dev/null 2>&1; then
  _fail "a task absent from the plan must have no prediction"
fi
if yt_lane_predicted "$UNIT/nope.json" alpha >/dev/null 2>&1; then
  _fail "a missing plan file must have no prediction"
fi
printf 'this is not json at all\n' > "$UNIT/broken.json"
if yt_lane_predicted "$UNIT/broken.json" alpha >/dev/null 2>&1; then
  _fail "an unparseable plan must have no prediction, not a crash"
fi
write_plan "$UNIT" "empty:"
if yt_lane_predicted "$UNIT/plan.json" empty >/dev/null 2>&1; then
  _fail "a task predicting no files must have no prediction"
fi
ok "yt_lane_predicted: reads a lane, and is silently empty when there is none"

# =============================================================================
# case 1 — IN LANE: the agent touched exactly what the plan predicted.
# PASSED, and no warnings/<task> record exists at all.
# =============================================================================
reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=good
prepare_core
yt_status_init "$RUN" inlane || _fail "could not register inlane"
write_plan "$RUN" "inlane:src/feature.js"

yt_run_task "$RUN" inlane "Add the feature module"
rc=$?
assert_eq "$rc" 0 "in-lane task returns 0"
assert_eq "$(cat "$RUN/status/inlane")" "passed" "in-lane task is passed"
assert_file_missing "$RUN/warnings/inlane" "no warning record for a task that stayed in its lane"
assert_eq "$YT_LANE_VERDICT" "in-lane" "verdict published as in-lane"
assert_eq "$(yt_verdict "$RUN" inlane)" "PASSED" "report renders a plain PASSED"
assert_contains "$(cat "$RUN/logs/inlane.log")" "lane: inside the lane plan.json predicted" \
  "log records the in-lane verdict"
ok "in lane: PASSED, no warning record, nothing for the report to surface"

# =============================================================================
# case 2 — STRAYED: the agent touched a predicted file AND one nobody predicted.
# Still PASSED (0, committed, pushed) — warn only — plus warnings/<task>, which
# names the stray and ONLY the stray, and which the report turns into
# PASSED-WITH-WARNING.
# =============================================================================
reset_fixture
SHIM="$TMP_ROOT/two-file-claude"
make_two_file_shim "$SHIM"
make_fixture_repo "CLAUDE_BIN=\"$SHIM\""
make_bare_origin
unset FAKE_CLAUDE_MODE
prepare_core
yt_status_init "$RUN" strayer || _fail "could not register strayer"
write_plan "$RUN" "strayer:src/feature.js"

yt_run_task "$RUN" strayer "Add the feature module"
rc=$?
# The load-bearing assertions: a lane violation changes NOTHING about the
# outcome. Promoting it to a failure is a deferred decision (SPEC.md section 7).
assert_eq "$rc" 0 "a straying task still returns 0 — the lane check is warn only"
assert_eq "$(cat "$RUN/status/strayer")" "passed" "a straying task is still passed"
assert_eq "$YT_TASK_REASON" "" "a lane violation is not a failure reason"
count="$(git -C "$TMP_ROOT/yt-strayer" rev-list --count main..feature/strayer)"
assert_eq "$count" 1 "the commit stands"
git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/strayer >/dev/null \
  || _fail "a straying task is still pushed"

assert_eq "$YT_LANE_VERDICT" "strayed" "verdict published as strayed"
assert_file_exists "$RUN/warnings/strayer" "a stray writes the warnings/<task> record"
WARN="$(cat "$RUN/warnings/strayer")"
assert_contains "$WARN" "docs/notes.md" "the record names the file outside the lane"
IFS= read -r WARN1 < "$RUN/warnings/strayer"
assert_contains "$WARN1" "strayed outside predicted lane" "line 1 stands alone (it is what the table shows)"
assert_not_contains "$WARN1" "src/feature.js" "the predicted file is not reported as a stray"
assert_contains "$WARN" "warn only" "the record says outright that it never fails a task"

assert_eq "$(yt_verdict "$RUN" strayer)" "PASSED-WITH-WARNING" "the record drives the report verdict"
OUT="$(yt_report "$RUN" main feature/ "$TMP_ROOT")"
assert_contains "$OUT" "PASSED-WITH-WARNING" "the table shows PASSED-WITH-WARNING"
assert_contains "$OUT" "warning: strayed outside predicted lane" "the table surfaces the warning line"
assert_contains "$OUT" "git merge --no-ff feature/strayer" "a strayed branch is still offered for merge"
assert_contains "$(cat "$RUN/logs/strayer.log")" "docs/notes.md" "the log names the stray too"
ok "strayed: PASSED-WITH-WARNING, warn only, the commit and push untouched"

# =============================================================================
# case 3 — NO PREDICTION: no plan.json in the run dir, which is every
# `yolotown run-one`. Not a violation: no warning, plain PASSED.
# =============================================================================
reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=good
prepare_core
yt_status_init "$RUN" lonely || _fail "could not register lonely"
assert_file_missing "$RUN/plan.json" "a run-one style run dir has no plan"

yt_run_task "$RUN" lonely "A single task nobody planned"
rc=$?
assert_eq "$rc" 0 "an unplanned task passes"
assert_eq "$(cat "$RUN/status/lonely")" "passed" "an unplanned task is passed"
assert_eq "$YT_LANE_VERDICT" "unchecked" "no prediction means unchecked, not strayed"
assert_file_missing "$RUN/warnings" "no warnings/ directory is created when nothing strayed"
assert_eq "$(yt_verdict "$RUN" lonely)" "PASSED" "report renders a plain PASSED"
assert_contains "$(cat "$RUN/logs/lonely.log")" "lane: not checked" "the log says why it was not checked"
ok "no prediction: unchecked and silent — a run-one never warns"

# =============================================================================
# case 3b — a plan.json that simply does not name this task is the same answer.
# (A backlog the task was not part of; still nothing to compare against.)
# =============================================================================
reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=good
prepare_core
yt_status_init "$RUN" unplanned || _fail "could not register unplanned"
write_plan "$RUN" "somebody-else:src/other.js"

yt_run_task "$RUN" unplanned "A task the plan never mentions"
rc=$?
assert_eq "$rc" 0 "a task missing from the plan passes"
assert_eq "$YT_LANE_VERDICT" "unchecked" "a plan without this task means unchecked"
assert_file_missing "$RUN/warnings/unplanned" "no warning for a task the plan never predicted"
ok "no prediction: a plan that omits the task warns no more than a missing one"

# =============================================================================
# the gate still comes first: a red task never reaches the lane check, so it
# gets no warning record to muddle its FAILED row.
# =============================================================================
reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=bad
prepare_core
yt_status_init "$RUN" redt || _fail "could not register redt"
write_plan "$RUN" "redt:src/nothing-like-this.js"

yt_run_task "$RUN" redt "Break the gate"
rc=$?
assert_eq "$rc" 1 "a red gate still fails"
assert_eq "$(cat "$RUN/status/redt")" "failed" "a red gate is still failed"
assert_file_missing "$RUN/warnings/redt" "a failed task is not lane-checked (the gate decides first)"
assert_eq "$(yt_verdict "$RUN" redt)" "FAILED" "report renders FAILED, not a warning"
ok "red gate: no lane check, no warning record"

echo "lane: all cases passed"
