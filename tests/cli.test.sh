#!/usr/bin/env bash
# The `yolotown` entrypoint's subcommand dispatch: plan (parse+list dry run),
# run (serial batch into one shared run dir, continuing past failures, then the
# fan-in report), run-one (delegates to seed.sh), and clean (--force gated
# worktree/branch removal). All drive real git + worktrees; only the agent is
# mocked, per the repo's testing rules.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

YOLOTOWN="$YOLOTOWN_ROOT/yolotown"

# run_yt <args...> — invoke the entrypoint from the fixture repo root with stdin
# from /dev/null; sets YT_OUT and YT_RC.
run_yt() {
  YT_OUT="$(cd "$REPO" && "$YOLOTOWN" "$@" </dev/null 2>&1)"
  YT_RC=$?
}

latest_run() { printf '%s\n' "$REPO/.yolotown/$(readlink "$REPO/.yolotown/latest")"; }

# =============================================================================
# run — all tasks green: one shared run dir, both PASSED, both pushed
# =============================================================================
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=good

cat > "$REPO/backlog.txt" <<'EOF'
# a two-line backlog
alpha | first small feature
beta  | second small feature
EOF

run_yt run backlog.txt
assert_eq "$YT_RC" 0 "run over an all-green backlog exits 0"

# Exactly one run dir holds the whole batch (registered up front).
nruns="$(ls -1d "$REPO"/.yolotown/run-* | wc -l | tr -d ' ')"
assert_eq "$nruns" 1 "the batch lands in exactly one run dir"

RUN="$(latest_run)"
assert_eq "$(cat "$RUN/status/alpha")" "passed" "alpha registered and passed in the run dir"
assert_eq "$(cat "$RUN/status/beta")"  "passed" "beta registered and passed in the run dir"
assert_file_exists "$RUN/logs/alpha.log" "alpha got its own log in the run dir"
assert_file_exists "$RUN/logs/beta.log"  "beta got its own log in the run dir"

# Both branches exist locally and reached the bare origin.
git -C "$REPO" rev-parse --verify --quiet refs/heads/feature/alpha >/dev/null || _fail "feature/alpha branch missing"
git -C "$REPO" rev-parse --verify --quiet refs/heads/feature/beta  >/dev/null || _fail "feature/beta branch missing"
git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/alpha >/dev/null || _fail "feature/alpha not pushed"
git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/beta  >/dev/null || _fail "feature/beta not pushed"

# The fan-in report is printed at the end.
assert_contains "$YT_OUT" "summary: 2 tasks" "run prints the fan-in report summary"
assert_contains "$YT_OUT" "2 passed" "report tallies both passes"
assert_contains "$YT_OUT" "git merge --no-ff feature/alpha" "report emits alpha's merge command"
assert_contains "$YT_OUT" "git merge --no-ff feature/beta"  "report emits beta's merge command"

# Base branch untouched: still main, still clean.
assert_eq "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" "main" "base branch unchanged"
[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] || _fail "base working tree left dirty"
ok "run: all-green batch — one run dir, both passed and pushed, report printed"

# =============================================================================
# run — continues past failures: every task attempted even when all crash
# =============================================================================
reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=crash

cat > "$REPO/backlog.txt" <<'EOF'
one | crash the first
two | crash the second
EOF

run_yt run backlog.txt
[ "$YT_RC" -ne 0 ] || _fail "a batch with failures should exit nonzero"

RUN="$(latest_run)"
# Both were attempted (not aborted after the first): both have failed status
# and a non-empty log.
assert_eq "$(cat "$RUN/status/one")" "failed" "first task recorded failed"
assert_eq "$(cat "$RUN/status/two")" "failed" "second task recorded failed — the run did not stop at the first"
assert_file_exists "$RUN/logs/one.log" "first task's log exists"
assert_file_exists "$RUN/logs/two.log" "second task's log exists (proves it ran)"
assert_contains "$(cat "$RUN/logs/two.log")" "simulated agent crash" "second agent actually ran"
assert_contains "$YT_OUT" "FAILED" "report marks the crashed tasks FAILED"
assert_contains "$YT_OUT" "summary: 2 tasks" "report still summarizes the whole batch"
ok "run: continues past failures — both tasks attempted, both FAILED"

# =============================================================================
# run — mixed batch via a per-task shim: winner passes, loser crashes
# =============================================================================
reset_fixture

# A shim that decides per task from the prompt: any arg carrying "crash-me"
# exits nonzero (a crashed agent); otherwise it makes a harmless edit so the
# gate stays green. Overrides CLAUDE_BIN in the fixture conf (last assignment
# wins when the conf is sourced).
SHIM="$TMP_ROOT/pertask-claude"
cat > "$SHIM" <<'EOF'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  case "$a" in
    *crash-me*) echo "fatal: per-task crash requested" >&2; exit 1 ;;
  esac
done
mkdir -p src
printf '// added by the per-task shim\n' > "src/added-$$.js"
echo "per-task shim: made an edit, gate stays green"
exit 0
EOF
chmod +x "$SHIM"

make_fixture_repo "CLAUDE_BIN=\"$SHIM\""
make_bare_origin
unset FAKE_CLAUDE_MODE

cat > "$REPO/backlog.txt" <<'EOF'
winner | ship a small thing
loser  | please crash-me right away
EOF

run_yt run backlog.txt
[ "$YT_RC" -ne 0 ] || _fail "a mixed batch with one failure should exit nonzero"

RUN="$(latest_run)"
assert_eq "$(cat "$RUN/status/winner")" "passed" "winner passed"
assert_eq "$(cat "$RUN/status/loser")"  "failed" "loser failed"
git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/winner >/dev/null || _fail "winner should be pushed"
if git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/loser >/dev/null; then
  _fail "loser must not reach origin (its agent crashed before commit)"
fi
# The loser's worktree is left intact for autopsy (the run created it before
# the agent ran); the winner's is left too (run never auto-removes).
git -C "$REPO" worktree list | grep -q "yt-loser"  || _fail "loser worktree should be left intact for autopsy"
git -C "$REPO" worktree list | grep -q "yt-winner" || _fail "winner worktree should be left intact"
assert_contains "$YT_OUT" "1 passed" "report tallies the pass"
assert_contains "$YT_OUT" "1 failed" "report tallies the failure"
ok "run: mixed batch — winner shipped, loser failed, both accounted for"

# =============================================================================
# clean — reuses the mixed run's leftover worktrees: dry run then --force
# =============================================================================
run_yt clean
assert_eq "$YT_RC" 0 "clean (dry run) exits 0"
assert_contains "$YT_OUT" "git worktree remove --force" "clean prints worktree removal commands"
assert_contains "$YT_OUT" "yt-winner" "clean names the winner worktree"
assert_contains "$YT_OUT" "yt-loser"  "clean names the loser worktree"
assert_contains "$YT_OUT" "git branch -D feature/winner" "clean prints the branch removal"
assert_contains "$YT_OUT" "re-run with --force" "dry run points at --force"
# Dry run executed nothing: both worktrees still present.
git -C "$REPO" worktree list | grep -q "yt-winner" || _fail "clean dry run must not remove worktrees"
git -C "$REPO" worktree list | grep -q "yt-loser"  || _fail "clean dry run must not remove worktrees"
ok "clean: dry run prints the commands and touches nothing"

run_yt clean --force
assert_eq "$YT_RC" 0 "clean --force exits 0"
# Now the worktrees and local branches are gone.
if git -C "$REPO" worktree list | grep -q "yt-winner"; then _fail "clean --force should remove the winner worktree"; fi
if git -C "$REPO" worktree list | grep -q "yt-loser";  then _fail "clean --force should remove the loser worktree"; fi
if git -C "$REPO" rev-parse --verify --quiet refs/heads/feature/winner >/dev/null; then _fail "clean --force should delete feature/winner"; fi
if git -C "$REPO" rev-parse --verify --quiet refs/heads/feature/loser  >/dev/null; then _fail "clean --force should delete feature/loser"; fi
ok "clean --force: removes the leftover worktrees and local branches"

# clean with no runs fails loudly.
reset_fixture
make_fixture_repo
run_yt clean
[ "$YT_RC" -ne 0 ] || _fail "clean with no runs should fail"
assert_contains "$YT_OUT" "no runs yet" "clean with no runs explains there is nothing to clean"
# unknown option rejected.
run_yt clean --bogus
[ "$YT_RC" -ne 0 ] || _fail "clean should reject an unknown option"
assert_contains "$YT_OUT" "unknown option" "clean names the bad option"
ok "clean: no-runs and bad-option cases fail loudly"

# =============================================================================
# run-one — delegates to seed.sh verbatim (single-task path)
# =============================================================================
reset_fixture
make_fixture_repo
make_bare_origin
export FAKE_CLAUDE_MODE=good

run_yt run-one solo "Do a single small thing"
assert_eq "$YT_RC" 0 "run-one green path exits 0"
assert_contains "$YT_OUT" "RESULT: PASSED" "run-one preserves seed.sh's single-task report"
git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/feature/solo >/dev/null || _fail "run-one should push feature/solo"

run_yt run-one solo
[ "$YT_RC" -ne 0 ] || _fail "run-one with a missing description should fail"
ok "run-one: delegates to seed.sh, single-task PASSED, arity checked"

# =============================================================================
# plan — parse + list dry run, touches nothing; malformed input fails fast
# =============================================================================
reset_fixture
make_fixture_repo   # no origin, no agent: plan never dispatches

cat > "$REPO/backlog.txt" <<'EOF'
# planning only
red  | first candidate
blue | second candidate
EOF

run_yt plan backlog.txt
assert_eq "$YT_RC" 0 "plan exits 0 on a well-formed backlog"
assert_contains "$YT_OUT" "red" "plan lists the first task"
assert_contains "$YT_OUT" "blue" "plan lists the second task"
assert_contains "$YT_OUT" "dry run" "plan announces it is a dry run"
assert_contains "$YT_OUT" "Stage 3" "plan notes conflict detection is deferred to Stage 3"
assert_file_missing "$REPO/.yolotown" "plan touches nothing on disk"

printf 'this line has no separator\n' > "$REPO/bad.txt"
run_yt plan bad.txt
[ "$YT_RC" -ne 0 ] || _fail "plan on a malformed backlog should fail"
assert_contains "$YT_OUT" "missing" "plan surfaces the parser's line-numbered error"
assert_file_missing "$REPO/.yolotown" "a failed plan still touches nothing"
ok "plan: dry-run lists tasks and touches nothing; malformed input fails fast"

# =============================================================================
# run — malformed backlog fails fast, before any run dir is created
# =============================================================================
reset_fixture
make_fixture_repo
make_bare_origin

printf 'not a task line\n' > "$REPO/bad.txt"
run_yt run bad.txt
[ "$YT_RC" -ne 0 ] || _fail "run on a malformed backlog should fail"
assert_file_missing "$REPO/.yolotown/latest" "a malformed backlog creates no run dir"
ok "run: refuses a malformed backlog before touching the tree"

# =============================================================================
# dispatch — usage and unknown command
# =============================================================================
reset_fixture
make_fixture_repo
run_yt
assert_eq "$YT_RC" 2 "no subcommand prints usage and exits 2"
assert_contains "$YT_OUT" "usage: yolotown" "usage lists the surface"
assert_contains "$YT_OUT" "run-one" "usage documents run-one"
run_yt bogus
assert_eq "$YT_RC" 2 "unknown command exits 2"
assert_contains "$YT_OUT" "unknown command" "unknown command is named"
ok "dispatch: usage and unknown command handled"

echo "cli: all cases passed"
