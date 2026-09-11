#!/usr/bin/env bash
# lib/plan.sh: conflict detection (SPEC.md 3.1). One headless planner call per
# invocation turns the backlog plus the SOURCE_GLOBS inventory into plan.json:
# every task in exactly one of three buckets, plus the collision report.
#
# The three cases that matter most are a clean disjoint plan, a detected
# collision, and a malformed response. The malformed section is the long one on
# purpose: a planner answer that cannot be trusted must be a loud refusal with
# NO plan.json, never a guess and never a silent "everything is disjoint" —
# that fallback would green-light a fan-out of tasks that overwrite each other.
#
# The planner is answered through its own shim seam (FAKE_CLAUDE_PLAN_MODE), so
# FAKE_CLAUDE_MODE keeps meaning "how the TASK agent behaves"; the last section
# pins both directions of that independence down.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

PLAN_ARGV="$TMP_ROOT/planner-argv"
export FAKE_CLAUDE_PLAN_ARGV_FILE="$PLAN_ARGV"

# write_backlog <file> <line>... — a tasks file in the documented format.
write_backlog() {
  local f="$1"; shift
  : > "$f"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$f"; done
}

# run_plan <tasks-file> — parse the backlog, make a run dir, and run conflict
# detection in $REPO. Sets PLAN_RC, PLAN_OUT (stdout+stderr) and PLAN_JSON (the
# path plan.json would have, whether or not it was written).
run_plan() {
  rm -f "$PLAN_ARGV"
  PLAN_OUT="$(cd "$REPO" && bash -c '
    set -uo pipefail
    . "$1/lib/config.sh"
    . "$1/lib/rundir.sh"
    . "$1/lib/tasks.sh"
    . "$1/lib/plan.sh"
    yt_load_config || exit 9
    parsed="$(yt_parse_tasks "$2")" || exit 9
    run="$(yt_run_create "$PWD/.yolotown")" || exit 9
    yt_plan "$run" "$parsed"
  ' _ "$YOLOTOWN_ROOT" "$1" 2>&1)"
  PLAN_RC=$?
  SEED_OUT="$PLAN_OUT"   # so helpers.sh _fail prints it
  PLAN_JSON="$REPO/.yolotown/latest/plan.json"
}

# plan_tasks / plan_collisions — the library's own readers, tabs flattened to
# spaces so assertions read naturally.
plan_tasks() {
  bash -c '. "$1/lib/plan.sh"; yt_plan_tasks "$2"' _ "$YOLOTOWN_ROOT" "$PLAN_JSON" | tr '\t' ' '
}
plan_collisions() {
  bash -c '. "$1/lib/plan.sh"; yt_plan_collisions "$2"' _ "$YOLOTOWN_ROOT" "$PLAN_JSON" | tr '\t' ' '
}

# assert_no_plan <label> — the refusal contract: nothing written, and the
# refusal says so in the words a human will grep for.
assert_no_plan() {
  local label="$1"
  [ "$PLAN_RC" -ne 0 ] || _fail "$label: a malformed plan must exit nonzero"
  assert_file_missing "$PLAN_JSON" "$label: no plan.json is written"
  assert_contains "$PLAN_OUT" "refusing to write plan.json" "$label: the refusal is explicit"
}

# =============================================================================
# config: SOURCE_GLOBS and PLANNER_MODEL
# =============================================================================
CONF_DIR="$TMP_ROOT/confdir"
dump_config() {
  SEED_OUT="$(cd "$CONF_DIR" && bash -c '
    set -uo pipefail
    . "$1/lib/config.sh"
    yt_load_config
    for k in SOURCE_GLOBS PLANNER_MODEL; do printf "%s=[%s]\n" "$k" "${!k}"; done
  ' _ "$YOLOTOWN_ROOT" 2>&1)"
  SEED_RC=$?
}

rm -rf "$CONF_DIR"; mkdir -p "$CONF_DIR"
printf 'TEST_CMD="./check.sh"\n' > "$CONF_DIR/.yolotown.conf"
dump_config
assert_eq "$SEED_RC" 0 "a conf without SOURCE_GLOBS loads"
assert_contains "$SEED_OUT" "*.js"  "SOURCE_GLOBS defaults to the source-ish extension list"
assert_contains "$SEED_OUT" "*.md"  "the default list covers docs the planner needs to read"
assert_contains "$SEED_OUT" "*.sh"  "the default list covers shell sources"
assert_contains "$SEED_OUT" 'PLANNER_MODEL=[]' "PLANNER_MODEL defaults empty (CLI default)"
ok "SOURCE_GLOBS and PLANNER_MODEL defaults"

printf 'TEST_CMD="./check.sh"\nSOURCE_GLOBS="src/*.ts"\nPLANNER_MODEL="claude-opus-4-8"\n' > "$CONF_DIR/.yolotown.conf"
dump_config
assert_eq "$SEED_RC" 0 "an overriding conf loads"
assert_contains "$SEED_OUT" 'SOURCE_GLOBS=[src/*.ts]'        "SOURCE_GLOBS override wins"
assert_contains "$SEED_OUT" 'PLANNER_MODEL=[claude-opus-4-8]' "PLANNER_MODEL override wins"
ok "SOURCE_GLOBS and PLANNER_MODEL overrides"

printf 'TEST_CMD="./check.sh"\nSOURCE_GLOBS=""\n' > "$CONF_DIR/.yolotown.conf"
dump_config
assert_eq "$SEED_RC" 2 "an empty SOURCE_GLOBS is refused, not read as \"every file\""
assert_contains "$SEED_OUT" "SOURCE_GLOBS" "the refusal names the offending key"
assert_contains "$SEED_OUT" 'SOURCE_GLOBS="*.js *.ts *.md"' "the refusal shows a valid example"
ok "empty SOURCE_GLOBS refused"

# =============================================================================
# a clean disjoint plan
# =============================================================================
reset_fixture
make_fixture_repo
write_backlog "$REPO/backlog.txt" \
  "# three tasks that touch nothing in common" \
  "alpha | add the alpha module" \
  "beta  | add the beta module" \
  "gamma | add the gamma module"

export FAKE_CLAUDE_PLAN_MODE=disjoint
run_plan "$REPO/backlog.txt"
assert_eq "$PLAN_RC" 0 "a well-formed disjoint plan succeeds"
assert_file_exists "$PLAN_JSON" "plan.json lands in the run dir"
assert_contains "$PLAN_OUT" "/plan.json" "yt_plan prints the plan path it wrote"

TASKS_OUT="$(plan_tasks)"
assert_contains "$TASKS_OUT" "alpha DISJOINT src/alpha.js" "alpha is bucketed DISJOINT with its files"
assert_contains "$TASKS_OUT" "beta DISJOINT src/beta.js"   "beta is bucketed DISJOINT with its files"
assert_contains "$TASKS_OUT" "gamma DISJOINT src/gamma.js" "gamma is bucketed DISJOINT with its files"
assert_eq "$(printf '%s\n' "$TASKS_OUT" | wc -l | tr -d ' ')" "3" "every task appears exactly once"
assert_eq "$(plan_collisions)" "" "a disjoint plan reports no collisions"

# The planner call itself: one marked, read-only, model-defaulted invocation.
assert_file_exists "$PLAN_ARGV" "the planner invocation was recorded separately from the task agent's"
ARGV="$(cat "$PLAN_ARGV")"
assert_contains "$ARGV" "yolotown-conflict-detection-plan" "the planner prompt carries its marker"
assert_contains "$ARGV" "TASK alpha | add the alpha module" "the prompt carries the parsed task list"
assert_contains "$ARGV" "FILE src/app.js"  "the prompt carries the SOURCE_GLOBS inventory"
assert_contains "$ARGV" "FILE CLAUDE.md"   "the inventory includes the docs the default globs match"
assert_contains "$ARGV" "DISJOINT"         "the prompt names the buckets it demands"
assert_contains "$ARGV" "INHERENTLY-COUPLED" "the prompt names all three buckets"
assert_contains "$ARGV" "--allowedTools"   "the planner is invoked with scoped tools"
assert_not_contains "$ARGV" "Write"        "the planner gets no write tools: it predicts, it never edits"
assert_not_contains "$ARGV" "--model"      "no PLANNER_MODEL means the CLI default, not a guessed flag"
ok "clean disjoint plan"

# plan.json is flat-file state: readable with cat, and valid JSON on disk.
assert_contains "$(cat "$PLAN_JSON")" '"bucket": "DISJOINT"' "plan.json is cat-able, canonical JSON"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$PLAN_JSON" \
  || _fail "plan.json is not parseable JSON"
ok "plan.json is inspectable flat-file state"

# PLANNER_MODEL reaches the CLI when the conf sets one.
reset_fixture
make_fixture_repo 'PLANNER_MODEL="claude-opus-4-8"'
write_backlog "$REPO/backlog.txt" "alpha | add the alpha module" "beta | add the beta module"
run_plan "$REPO/backlog.txt"
assert_eq "$PLAN_RC" 0 "a plan with PLANNER_MODEL set succeeds"
assert_contains "$(cat "$PLAN_ARGV")" "--model" "PLANNER_MODEL is passed to the planner call"
assert_contains "$(cat "$PLAN_ARGV")" "claude-opus-4-8" "the configured planner model is the one passed"
ok "PLANNER_MODEL reaches the planner invocation"

# =============================================================================
# a detected collision
# =============================================================================
reset_fixture
make_fixture_repo
write_backlog "$REPO/backlog.txt" \
  "alpha | rewrite the shared router" \
  "beta  | also rewrite the shared router" \
  "gamma | add an unrelated module"

export FAKE_CLAUDE_PLAN_MODE=collide
run_plan "$REPO/backlog.txt"
assert_eq "$PLAN_RC" 0 "a plan that reports a collision still succeeds"
assert_file_exists "$PLAN_JSON" "a colliding plan is written too: the collision IS the answer"

TASKS_OUT="$(plan_tasks)"
assert_contains "$TASKS_OUT" "alpha COLLIDING-SPLITTABLE" "the first colliding task is bucketed"
assert_contains "$TASKS_OUT" "beta COLLIDING-SPLITTABLE"  "the second colliding task is bucketed"
assert_contains "$TASKS_OUT" "gamma DISJOINT"             "the uninvolved task stays DISJOINT"
assert_contains "$TASKS_OUT" "src/shared.js"              "the shared file is recorded on the tasks"

COLL_OUT="$(plan_collisions)"
assert_eq "$(printf '%s\n' "$COLL_OUT" | wc -l | tr -d ' ')" "1" "exactly one collision is reported"
assert_contains "$COLL_OUT" "COLLIDING-SPLITTABLE alpha beta src/shared.js" \
  "the collision names its bucket, its pair, and the overlapping file"
assert_contains "$COLL_OUT" "both tasks rewrite" "the collision carries the planner's reason"
ok "detected collision: COLLIDING-SPLITTABLE"

export FAKE_CLAUDE_PLAN_MODE=coupled
run_plan "$REPO/backlog.txt"
assert_eq "$PLAN_RC" 0 "an inherently-coupled plan succeeds"
assert_contains "$(plan_tasks)" "alpha INHERENTLY-COUPLED" "the coupled bucket is carried through"
assert_contains "$(plan_collisions)" "INHERENTLY-COUPLED alpha beta" "the collision is bucketed coupled"
assert_contains "$(plan_tasks)" "gamma DISJOINT" "the third task is untouched by the coupling"
ok "detected collision: INHERENTLY-COUPLED"

# =============================================================================
# malformed responses: hard failure, naming what was wrong, writing nothing
# =============================================================================
reset_fixture
make_fixture_repo
write_backlog "$REPO/backlog.txt" \
  "alpha | add the alpha module" \
  "beta  | add the beta module"

export FAKE_CLAUDE_PLAN_MODE=prose
run_plan "$REPO/backlog.txt"
assert_no_plan "prose"
assert_contains "$PLAN_OUT" "no JSON object" "the refusal says the response had no JSON"
assert_contains "$PLAN_OUT" "seem fine to me" "the refusal shows the response it rejected"
ok "malformed: a prose answer is rejected"

export FAKE_CLAUDE_PLAN_MODE=truncated
run_plan "$REPO/backlog.txt"
assert_no_plan "truncated"
assert_contains "$PLAN_OUT" "not parseable JSON" "the refusal says the JSON did not parse"
ok "malformed: unparseable JSON is rejected"

export FAKE_CLAUDE_PLAN_MODE=silent
run_plan "$REPO/backlog.txt"
assert_no_plan "silent"
assert_contains "$PLAN_OUT" "no output at all" "a silent exit-0 planner is a failure, not an empty plan"
ok "malformed: a silent planner is rejected"

export FAKE_CLAUDE_PLAN_MODE=crash
run_plan "$REPO/backlog.txt"
assert_no_plan "crash"
assert_contains "$PLAN_OUT" "exited nonzero" "the refusal names the planner's exit"
assert_contains "$PLAN_OUT" "simulated planner crash" "the refusal shows the planner's stderr"
ok "malformed: a crashing planner is rejected"

export FAKE_CLAUDE_PLAN_MODE=missing-task
run_plan "$REPO/backlog.txt"
assert_no_plan "missing-task"
assert_contains "$PLAN_OUT" 'task "beta" is missing' "the refusal names the task left out of the plan"
ok "malformed: a task missing from the plan is rejected"

export FAKE_CLAUDE_PLAN_MODE=unknown-task
run_plan "$REPO/backlog.txt"
assert_no_plan "unknown-task"
assert_contains "$PLAN_OUT" "ghost-task" "the refusal names the invented task"
assert_contains "$PLAN_OUT" "not a task in this backlog" "the refusal says why it was rejected"
ok "malformed: an invented task is rejected"

export FAKE_CLAUDE_PLAN_MODE=duplicate-task
run_plan "$REPO/backlog.txt"
assert_no_plan "duplicate-task"
assert_contains "$PLAN_OUT" "appears more than once" "the refusal names the duplicated task"
ok "malformed: a duplicated task is rejected"

export FAKE_CLAUDE_PLAN_MODE=bad-bucket
run_plan "$REPO/backlog.txt"
assert_no_plan "bad-bucket"
assert_contains "$PLAN_OUT" "PROBABLY-FINE" "the refusal shows the invented bucket"
assert_contains "$PLAN_OUT" "DISJOINT, COLLIDING-SPLITTABLE, INHERENTLY-COUPLED" \
  "the refusal lists the only three buckets there are"
ok "malformed: a fourth bucket is rejected"

export FAKE_CLAUDE_PLAN_MODE=no-files
run_plan "$REPO/backlog.txt"
assert_no_plan "no-files"
assert_contains "$PLAN_OUT" "predicts no files" "the refusal names the task with no prediction"
ok "malformed: a task predicting no files is rejected"

export FAKE_CLAUDE_PLAN_MODE=uncollided
run_plan "$REPO/backlog.txt"
assert_no_plan "uncollided"
assert_contains "$PLAN_OUT" "appears in no collision" \
  "a task bucketed as colliding must be in the collision report"
ok "malformed: a colliding bucket with no collision is rejected"

export FAKE_CLAUDE_PLAN_MODE=half-collision
run_plan "$REPO/backlog.txt"
assert_no_plan "half-collision"
assert_contains "$PLAN_OUT" "predicted by at least two" \
  "a shared file only one task predicts is not a collision"
ok "malformed: a half-reported collision is rejected"

# The dangerous one: the planner's own file lists overlap while it claims
# everything is disjoint. Trusting this would fan out tasks that overwrite each
# other, so the plan is cross-examined against itself and refused.
export FAKE_CLAUDE_PLAN_MODE=hidden-collision
run_plan "$REPO/backlog.txt"
assert_no_plan "hidden-collision"
assert_contains "$PLAN_OUT" "src/shared.js" "the refusal names the file both tasks predict"
assert_contains "$PLAN_OUT" "no collision reports them together" "the refusal says the overlap went unreported"
assert_contains "$PLAN_OUT" "colliding parallel run" "the refusal says what the guess would have caused"
ok "malformed: an unreported overlap cannot pass as DISJOINT"

# =============================================================================
# the inventory the planner is given is SOURCE_GLOBS, and nothing else
# =============================================================================
reset_fixture
make_fixture_repo 'SOURCE_GLOBS="*.js"'
write_backlog "$REPO/backlog.txt" "alpha | add the alpha module" "beta | add the beta module"
export FAKE_CLAUDE_PLAN_MODE=disjoint
run_plan "$REPO/backlog.txt"
assert_eq "$PLAN_RC" 0 "a narrowed SOURCE_GLOBS still plans"
ARGV="$(cat "$PLAN_ARGV")"
assert_contains     "$ARGV" "FILE src/app.js" "the narrowed inventory keeps what the glob matches"
assert_not_contains "$ARGV" "FILE check.sh"   "the narrowed inventory drops what it does not"
assert_not_contains "$ARGV" "FILE CLAUDE.md"  "SOURCE_GLOBS, not convention, decides the inventory"
ok "SOURCE_GLOBS decides the inventory"

reset_fixture
make_fixture_repo 'SOURCE_GLOBS="*.nothing-matches-this"'
write_backlog "$REPO/backlog.txt" "alpha | add the alpha module"
run_plan "$REPO/backlog.txt"
[ "$PLAN_RC" -ne 0 ] || _fail "an inventory of nothing must not be planned against"
assert_file_missing "$PLAN_JSON" "no plan.json from an empty inventory"
assert_contains "$PLAN_OUT" "matched no tracked files" "the refusal says the globs matched nothing"
assert_contains "$PLAN_OUT" "*.nothing-matches-this" "the refusal shows the offending globs"
ok "an empty inventory is refused"

# =============================================================================
# the planner seam and the task-agent seam are independent
# =============================================================================
# Direction 1: how the TASK agent behaves cannot change the planner's answer.
reset_fixture
make_fixture_repo
write_backlog "$REPO/backlog.txt" "alpha | add the alpha module" "beta | add the beta module"
export FAKE_CLAUDE_MODE=crash
export FAKE_CLAUDE_PLAN_MODE=disjoint
run_plan "$REPO/backlog.txt"
assert_eq "$PLAN_RC" 0 "a crashing TASK agent does not crash the planner"
assert_contains "$(plan_tasks)" "alpha DISJOINT" "the planner answered from its own seam"
ok "FAKE_CLAUDE_MODE does not reach the planner"

# Direction 2: the planner seam cannot change how the task agent behaves — the
# guarantee that lets Stage 3 run both through one CLAUDE_BIN with no existing
# test touched.
reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=good
export FAKE_CLAUDE_PLAN_MODE=crash
run_seed seam-task "Add the feature module"
assert_eq "$SEED_RC" 0 "a crashing planner seam leaves the task agent alone"
assert_contains "$SEED_OUT" "RESULT: PASSED" "the task ran to green through the same shim"
ok "FAKE_CLAUDE_PLAN_MODE does not reach the task agent"

unset FAKE_CLAUDE_MODE FAKE_CLAUDE_PLAN_MODE FAKE_CLAUDE_PLAN_ARGV_FILE

echo "plan: all cases passed"
