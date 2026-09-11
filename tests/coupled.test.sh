#!/usr/bin/env bash
# Coupled-serial scheduling (SPEC.md section 3.1): the INHERENTLY-COUPLED bucket
# is the one place tasks must NOT be parallel. A coupled group is dispatched as
# a CHAIN — its tasks in order, one at a time, each cut from the previous task's
# branch rather than from BASE_BRANCH — and the first failure abandons the rest
# of the chain as SKIPPED.
#
# Three properties are proved here, each the hard way:
#
#   ORDERING   the agent shim writes "start <task>" and "end <task>" into a
#              shared file, so the transcript itself shows the order AND the
#              non-overlap: within a chain, every task's "end" precedes the next
#              task's "start". Nothing about that can be satisfied by a
#              scheduler that ran the group in parallel and got lucky.
#   REBASING   asserted on real git history. Task 2's branch must contain task
#              1's commit as an ancestor, task 3's must contain both, and task
#              3's branch must carry exactly three commits over the base. A
#              scheduler that cut every worktree from BASE_BRANCH produces one
#              commit per branch and no ancestry at all.
#   SKIPPING   a mid-chain crash must leave the remainder at "skipped" with NO
#              worktree, NO branch, and — the part that matters — no agent
#              invocation: the shim's own transcript is the witness that the
#              tasks after the failure were never run rather than run and
#              discarded.
#
# Everything else is real: real worktrees, real commits, real pushes to a real
# bare origin, a real gate per task.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

. "$YOLOTOWN_ROOT/lib/config.sh"
. "$YOLOTOWN_ROOT/lib/rundir.sh"
. "$YOLOTOWN_ROOT/lib/task.sh"
. "$YOLOTOWN_ROOT/lib/fanout.sh"
. "$YOLOTOWN_ROOT/lib/report.sh"

# ---- the transcript agent shim ----------------------------------------------
# Answers the reachability probe like tests/fake-claude does, then: read its own
# task name out of the prompt, register in CHAIN_DIR/inflight, bracket its work
# with "start"/"end" lines in CHAIN_DIR/order, sample the in-flight count, and
# make an edit named after the task (so two tasks in a chain make DIFFERENT
# edits — an identical one would leave the second with nothing to commit).
SHIM="$TMP_ROOT/chain-claude"
cat > "$SHIM" <<'SHIM_EOF'
#!/usr/bin/env bash
set -u
for _a in "$@"; do
  case "$_a" in *yolotown-agent-reachability-probe*) echo "ok"; exit 0 ;; esac
done

PROMPT=""
for _a in "$@"; do
  case "$_a" in *"TASK: "*) PROMPT="$_a" ;; esac
done
NAME=""
while IFS= read -r _line; do
  case "$_line" in "TASK: "*) NAME="${_line#TASK: }"; break ;; esac
done <<< "$PROMPT"
[ -n "$NAME" ] || { echo "chain shim: no TASK line in the prompt" >&2; exit 98; }

DIR="${CHAIN_DIR:?chain shim needs CHAIN_DIR}"
mkdir -p "$DIR/inflight"
ME="$DIR/inflight/$$"
: > "$ME"
printf 'start %s\n' "$NAME" >> "$DIR/order"

# Hold, sampling every tick, exactly as tests/fan-out.test.sh's probe does:
# release once CHAIN_EXPECT agents are in flight, but never before
# CHAIN_MIN_TICKS samples, so an over-bound burst cannot slip past unobserved.
expect="${CHAIN_EXPECT:-1}"
min_ticks="${CHAIN_MIN_TICKS:-3}"
max_ticks="${CHAIN_MAX_TICKS:-40}"
tick=0
while [ "$tick" -lt "$max_ticks" ]; do
  n="$(ls "$DIR/inflight" | wc -l | tr -d ' ')"
  printf '%s\n' "$n" >> "$DIR/samples"
  tick=$((tick + 1))
  [ "$tick" -ge "$min_ticks" ] && [ "$n" -ge "$expect" ] && break
  sleep 0.05
done
rm -f "$ME"
printf 'end %s\n' "$NAME" >> "$DIR/order"

case "$PROMPT" in
  *crash-me*) echo "fatal: chain shim crash requested by $NAME" >&2; exit 1 ;;
esac

mkdir -p src
printf '// added by the chain shim for %s\n' "$NAME" > "src/$NAME.js"
echo "chain shim: $NAME edited"
exit 0
SHIM_EOF
chmod +x "$SHIM"

# chain_reset <label> — a fresh, empty transcript dir for one dispatch.
chain_reset() {
  export CHAIN_DIR="$TMP_ROOT/chain-$1"
  rm -rf "$CHAIN_DIR"
  mkdir -p "$CHAIN_DIR/inflight"
  : > "$CHAIN_DIR/order"
  : > "$CHAIN_DIR/samples"
}

chain_peak() {
  local peak
  peak="$(LC_ALL=C sort -n "$CHAIN_DIR/samples" 2>/dev/null | tail -1)"
  printf '%s\n' "${peak:-0}"
}

# chain_order [name...] — the transcript, filtered to the named tasks (all of
# it when none are named), as one space-separated line for easy comparison.
chain_order() {
  local want=" $* " line out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ $# -gt 0 ]; then
      case "$want" in *" ${line#* } "*) ;; *) continue ;; esac
    fi
    if [ -z "$out" ]; then out="$line"; else out="$out | $line"; fi
  done < "$CHAIN_DIR/order"
  printf '%s\n' "$out"
}

# prepare_core — cd into the fixture, load its config into the globals the core
# reads, point worktrees at the temp root, and hand back a fresh run dir in RUN.
# Mirrors what cmd_run does before dispatching.
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

register() {
  local t
  for t in "$@"; do
    yt_status_init "$RUN" "$t" || _fail "could not register $t"
  done
}

# =============================================================================
# a three-task coupled group: in order, one at a time, each rebased on the last
# =============================================================================
chain_reset trio
export CHAIN_EXPECT=1
make_fixture_repo "CLAUDE_BIN=\"$SHIM\""
make_bare_origin
prepare_core
register alpha beta gamma

CHAIN=$'alpha\tFirst link of the coupled group\nbeta\tSecond link, builds on the first\ngamma\tThird link, builds on the second'

# max 3, on purpose: the bound would ALLOW all three at once. The chain is what
# holds them to one at a time, not a lack of slots.
OUT="$(yt_fanout_chains "$RUN" 3 "$CHAIN" 2>&1)"; RC=$?
assert_eq "$RC" 0 "an all-green coupled group returns 0"

assert_eq "$(chain_order)" \
  "start alpha | end alpha | start beta | end beta | start gamma | end gamma" \
  "the coupled group ran strictly in order, one agent at a time"
assert_eq "$(chain_peak)" 1 "a coupled group never had two agents in flight, even with max 3"

assert_eq "$(cat "$RUN/status/alpha")" "passed" "alpha passed"
assert_eq "$(cat "$RUN/status/beta")"  "passed" "beta passed"
assert_eq "$(cat "$RUN/status/gamma")" "passed" "gamma passed"

# The rebasing, in real git history: each branch is cut from the previous one.
git -C "$REPO" merge-base --is-ancestor feature/alpha feature/beta \
  || _fail "beta must be cut from alpha's branch, not from main"
git -C "$REPO" merge-base --is-ancestor feature/beta feature/gamma \
  || _fail "gamma must be cut from beta's branch, not from main"
assert_eq "$(git -C "$REPO" rev-list --count main..feature/alpha)" 1 "alpha's branch carries its own commit"
assert_eq "$(git -C "$REPO" rev-list --count main..feature/beta)"  2 "beta's branch carries alpha's commit and its own"
assert_eq "$(git -C "$REPO" rev-list --count main..feature/gamma)" 3 "gamma's branch carries the whole group"

# ...and in the working trees: the later task SAW the earlier task's work.
assert_file_exists "$TMP_ROOT/yt-gamma/src/alpha.js" "gamma's worktree carries alpha's edit"
assert_file_exists "$TMP_ROOT/yt-gamma/src/beta.js"  "gamma's worktree carries beta's edit"
assert_file_missing "$TMP_ROOT/yt-alpha/src/beta.js" "alpha, cut first, cannot carry beta's edit"

# Each task's log names the ref its worktree was cut from.
assert_contains "$(cat "$RUN/logs/alpha.log")" "run: base=main" "the first link is cut from BASE_BRANCH"
assert_contains "$(cat "$RUN/logs/beta.log")"  "run: base=feature/alpha" "the second link is cut from the first's branch"
assert_contains "$(cat "$RUN/logs/gamma.log")" "run: base=feature/beta" "the third link is cut from the second's branch"

assert_contains "$OUT" "run: dispatch alpha -> beta -> gamma (coupled group 1/1" "the group is dispatched as one unit, in order"
assert_contains "$OUT" "task gamma: PASSED" "every link is reported by name"

i=0
for t in alpha beta gamma; do
  git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/feature/$t" >/dev/null \
    || _fail "$t should have been pushed to origin"
done
assert_eq "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" "main" "the base branch is untouched by a coupled group"
[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] || _fail "a coupled group left the base tree dirty"
ok "coupled group: in order, one at a time, each branch cut from the previous"

# =============================================================================
# a mid-group failure abandons the rest of the group: SKIPPED, not run
# =============================================================================
reset_fixture
chain_reset broken
export CHAIN_EXPECT=1
make_fixture_repo "CLAUDE_BIN=\"$SHIM\""
make_bare_origin
prepare_core
register one two three four

CHAIN=$'one\tThe link that lands\ntwo\tThe link that will crash-me\nthree\tNever dispatched\nfour\tNever dispatched either'

OUT="$(yt_fanout_chains "$RUN" 4 "$CHAIN" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || _fail "a coupled group with a failed link must return nonzero"

assert_eq "$(cat "$RUN/status/one")"   "passed"  "the link before the failure still passed"
assert_eq "$(cat "$RUN/status/two")"   "failed"  "the crashing link failed"
assert_eq "$(cat "$RUN/status/three")" "skipped" "the link after the failure is SKIPPED"
assert_eq "$(cat "$RUN/status/four")"  "skipped" "every remaining link is SKIPPED, not just the next one"

# The load-bearing assertion: they were never RUN. The shim writes a line the
# moment it starts, so its silence is proof no agent was ever invoked for them.
assert_eq "$(chain_order)" "start one | end one | start two | end two" \
  "the agent was never invoked for the skipped links"

# ...and nothing was created for them either.
assert_file_missing "$TMP_ROOT/yt-three" "a skipped task never got a worktree"
assert_file_missing "$TMP_ROOT/yt-four"  "a skipped task never got a worktree"
if git -C "$REPO" rev-parse --verify --quiet refs/heads/feature/three >/dev/null; then
  _fail "a skipped task must not have a branch"
fi
assert_file_missing "$RUN/results/three" "a skipped task has no result record: nothing ran to report"

# The failed link keeps its worktree for autopsy, exactly as a lone task does.
git -C "$REPO" worktree list | grep -q "yt-two" || _fail "the failed link's worktree should be left intact"
assert_contains "$(cat "$RUN/results/two")" "agent exited nonzero" "the failed link's result records the real reason"
assert_contains "$(cat "$RUN/logs/two.log")" "chain shim crash requested" "the failed link's agent stderr reached its log"

assert_contains "$OUT" "task two: FAILED" "the failing link is reported by name"
assert_contains "$OUT" "task three: SKIPPED" "the abandoned link is reported by name"
assert_contains "$OUT" "a task rebased on a failure is meaningless" "the report says WHY it was skipped"
assert_contains "$(cat "$RUN/logs/three.log")" "run: skipped:" "a skipped task is diagnosable from its own log"
assert_contains "$(cat "$RUN/logs/three.log")" "\"two\"" "the skip record names the task that failed"

# Nothing of the group past the failure reached origin.
git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/one >/dev/null \
  || _fail "the link before the failure should be pushed"
if git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/three >/dev/null; then
  _fail "a skipped task must not reach origin"
fi

# The fan-in report renders the whole group honestly.
REPORT="$(yt_report "$RUN" main feature/ "$(dirname "$REPO")")"
assert_contains "$REPORT" "SKIPPED              three" "the report renders a skipped task as SKIPPED"
assert_contains "$REPORT" "1 passed, 1 failed, 2 skipped" "the report tallies the abandoned tail"
ok "mid-group failure: the remainder is skipped, not run — no agent, no worktree, no branch"

# =============================================================================
# the failure at the HEAD of a group: everything behind it is skipped
# =============================================================================
reset_fixture
chain_reset head
export CHAIN_EXPECT=1
make_fixture_repo "CLAUDE_BIN=\"$SHIM\""
make_bare_origin
prepare_core
register lead follow

CHAIN=$'lead\tThe first link, which will crash-me\nfollow\tThe link that depended on it'

yt_fanout_chains "$RUN" 2 "$CHAIN" >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] || _fail "a group whose first link fails must return nonzero"
assert_eq "$(cat "$RUN/status/lead")"   "failed"  "the first link failed"
assert_eq "$(cat "$RUN/status/follow")" "skipped" "the whole tail of the group is skipped"
assert_eq "$(chain_order)" "start lead | end lead" "no agent ran after the first link failed"
ok "head-of-group failure: the entire remainder is skipped"

# =============================================================================
# groups fan out against EACH OTHER while staying serial inside: two coupled
# groups, two workers, two agents in flight — but never two from one group.
# =============================================================================
reset_fixture
chain_reset pair
export CHAIN_EXPECT=2
make_fixture_repo "CLAUDE_BIN=\"$SHIM\""
make_bare_origin
prepare_core
register a1 a2 b1 b2

CHAIN_A=$'a1\tGroup A, first\na2\tGroup A, second'
CHAIN_B=$'b1\tGroup B, first\nb2\tGroup B, second'

OUT="$(yt_fanout_chains "$RUN" 2 "$CHAIN_A" "$CHAIN_B" 2>&1)"; RC=$?
assert_eq "$RC" 0 "two all-green coupled groups return 0"
assert_eq "$(chain_peak)" 2 "two groups really did run at the same time"
assert_eq "$(chain_order a1 a2)" "start a1 | end a1 | start a2 | end a2" "group A stayed serial inside itself"
assert_eq "$(chain_order b1 b2)" "start b1 | end b1 | start b2 | end b2" "group B stayed serial inside itself"
git -C "$REPO" merge-base --is-ancestor feature/a1 feature/a2 || _fail "a2 must be cut from a1"
git -C "$REPO" merge-base --is-ancestor feature/b1 feature/b2 || _fail "b2 must be cut from b1"
if git -C "$REPO" merge-base --is-ancestor feature/a1 feature/b2 2>/dev/null; then
  _fail "group B must not be built on group A: separate groups are independent"
fi
ok "two coupled groups: parallel with each other, serial within themselves"

# =============================================================================
# mixed dispatch: a lone task is the degenerate one-task chain, and yt_fanout's
# <name> <desc> pairs still mean exactly what they meant
# =============================================================================
reset_fixture
chain_reset mixed
export CHAIN_EXPECT=2
make_fixture_repo "CLAUDE_BIN=\"$SHIM\""
make_bare_origin
prepare_core
register solo c1 c2

OUT="$(yt_fanout_chains "$RUN" 2 "$(printf 'solo\tAn independent task')" "$(printf 'c1\tCoupled first\nc2\tCoupled second')" 2>&1)"
RC=$?
assert_eq "$RC" 0 "a mixed batch of lone tasks and coupled groups returns 0"
assert_contains "$OUT" "run: dispatch solo (task 1/2" "a one-task chain is dispatched as a plain task"
assert_contains "$OUT" "run: dispatch c1 -> c2 (coupled group 2/2" "a multi-task chain is dispatched as a coupled group"
assert_eq "$(cat "$RUN/status/solo")" "passed" "the lone task passed"
assert_contains "$(cat "$RUN/logs/solo.log")" "run: base=main" "a lone task is still cut from BASE_BRANCH"
assert_contains "$(cat "$RUN/logs/c2.log")" "run: base=feature/c1" "the coupled task beside it is still rebased"
ok "mixed dispatch: lone tasks and coupled groups share one bounded scheduler"

# =============================================================================
# the base-ref override in the core itself (lib/task.sh), which is what the
# chain is built out of: cutting from an arbitrary ref, and refusing a bad one
# =============================================================================
reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=good
prepare_core
register first second nobase

yt_run_task "$RUN" first "A first feature"; RC=$?
assert_eq "$RC" 0 "the default base still works with no fourth argument"
assert_eq "$YT_TASK_BASE" "main" "YT_TASK_BASE defaults to BASE_BRANCH"

# The fake agent writes the SAME file every time, so a second task cut from the
# first's branch has nothing to change — which is itself proof the worktree was
# cut from feature/first and not from main.
yt_run_task "$RUN" second "A second feature" feature/first; RC=$?
assert_eq "$RC" 1 "a task cut from a branch that already has the agent's edit has nothing to commit"
assert_eq "$YT_TASK_BASE" "feature/first" "YT_TASK_BASE publishes the ref actually used"
assert_contains "$YT_TASK_REASON" "no changes" "the reason is the real one, not a base-ref error"
assert_file_exists "$TMP_ROOT/yt-second/src/feature.js" "the worktree was cut from feature/first, carrying its commit"
assert_eq "$(git -C "$REPO" rev-list --count main..feature/second)" 1 "feature/second starts at feature/first's commit"

yt_run_task "$RUN" nobase "A task with nowhere to start" feature/ghost; RC=$?
assert_eq "$RC" 1 "an unresolvable base ref fails the task"
assert_contains "$YT_TASK_REASON" "feature/ghost" "the refusal names the offending ref"
assert_contains "$YT_TASK_REASON" "does not resolve to a commit" "the refusal says what was wrong"
assert_file_missing "$TMP_ROOT/yt-nobase" "a refused base ref creates no worktree"
if git -C "$REPO" rev-parse --verify --quiet refs/heads/feature/nobase >/dev/null; then
  _fail "a refused base ref must not leave a branch behind"
fi
ok "base-ref override: cuts from any ref, refuses one that does not resolve"

# =============================================================================
# a chain worker that DIES mid-group. Its running task is convicted (the
# existing reaper rule); its unstarted tasks are stranded at "pending" and must
# be reported SKIPPED, not failed — they never ran. Driven straight against
# lib/fanout.sh, because a killed worker cannot be arranged through the agent.
# =============================================================================
BRANCH_PREFIX="feature/"
WORKTREE_PARENT="$TMP_ROOT/wt"
KILLDIR="$TMP_ROOT/.yolotown-chain-kill"
rm -rf "$KILLDIR"; mkdir -p "$KILLDIR"
KRUN="$(yt_run_create "$KILLDIR" chainkill)"
yt_status_init "$KRUN" inflight || _fail "could not register the in-flight task"
yt_status_set  "$KRUN" inflight running || _fail "could not start the in-flight task"
yt_status_init "$KRUN" unstarted || _fail "could not register the unstarted task"

RECON="$(yt_fanout_reconcile "$KRUN" inflight 137 2>&1)"; RRC=$?
assert_eq "$RRC" 1 "the task that was running when the chain worker died is a failure"
assert_eq "$(yt_status_get "$KRUN" inflight)" "failed" "the running task is convicted"

RECON="$(yt_fanout_reconcile "$KRUN" unstarted 137 2>&1)"; RRC=$?
assert_eq "$RRC" 0 "a task that never started is not counted as a failure"
assert_eq "$(yt_status_get "$KRUN" unstarted)" "skipped" "a pending task behind a dead chain worker is SKIPPED"
assert_contains "$RECON" "task unstarted: SKIPPED" "the unstarted task is reported by name"
assert_contains "$RECON" "137" "the report names the dead worker's exit code"
assert_file_missing "$KRUN/results/unstarted" "an unstarted task gets no result record"
assert_contains "$(cat "$KRUN/logs/unstarted.log")" "run: skipped:" "the skip is written into the task's own log"

# A skipped task is terminal: reconciling it again must not resurrect it.
yt_fanout_reconcile "$KRUN" unstarted 0 >/dev/null 2>&1 || _fail "re-reconciling a skipped task is not a failure"
assert_eq "$(yt_status_get "$KRUN" unstarted)" "skipped" "a skipped task stays skipped"
ok "dead chain worker: the running task is convicted, the unstarted ones are skipped"

# ---- yt_fanout_chains' own argument validation ------------------------------
if yt_fanout_chains "$KRUN" 0 "$(printf 'x\ta task')" 2>/dev/null; then _fail "max 0 must be refused"; fi
if yt_fanout_chains "$KRUN" many "$(printf 'x\ta task')" 2>/dev/null; then _fail "a non-numeric max must be refused"; fi
if yt_fanout_chains "$KRUN" 2 2>/dev/null; then _fail "no chains at all must be refused"; fi
if yt_fanout_chains "$KRUN" 2 "" 2>/dev/null; then _fail "an empty chain must be refused"; fi
if yt_fanout_chains "$TMP_ROOT/nope" 2 "$(printf 'x\ta task')" 2>/dev/null; then _fail "a bogus run dir must be refused"; fi
CHAIN_ERR="$(yt_fanout_chains "$KRUN" 2 "$(printf 'x\ta task')" "" 2>&1)"
assert_contains "$CHAIN_ERR" "chain 2/2 holds no tasks" "the refusal names which chain was empty"
assert_contains "$CHAIN_ERR" "<name><TAB><desc>" "the refusal shows the chain format"
CHAIN_ERR="$(yt_fanout "$KRUN" 2 "x" "$(printf 'a\tdesc')" 2>&1)"
assert_contains "$CHAIN_ERR" "tab or newline" "a description that would forge a chain boundary is refused"
ok "yt_fanout_chains: bad bounds, empty chains and bogus run dirs are refused"

echo "coupled: all cases passed"
