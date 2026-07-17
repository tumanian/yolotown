#!/usr/bin/env bash
# Sourced by every test. Builds fixture target repos and a bare fake origin,
# provides asserts, and cleans up temp dirs on exit (unless KEEP_TMP=1).
set -u

YOLOTOWN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED="$YOLOTOWN_ROOT/seed.sh"
FAKE_CLAUDE="$YOLOTOWN_ROOT/tests/fake-claude"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/yolotown-test.XXXXXX")"
REPO="$TMP_ROOT/repo"
ORIGIN="$TMP_ROOT/origin.git"

_cleanup_tmp() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    echo "KEEP_TMP=1: leaving $TMP_ROOT" >&2
    return
  fi
  rm -rf "$TMP_ROOT"
}
trap _cleanup_tmp EXIT

# make_fixture_repo [extra .yolotown.conf lines...]
# Committed contents: src/app.js (valid), check.sh gate (node --check + run),
# CLAUDE.md invariants, .gitignore for .env and .yolotown/, .yolotown.conf.
# Git-ignored, uncommitted: .env with known content.
# Overrides for fail-fast cases: FIXTURE_CONF (verbatim conf content),
# FIXTURE_GITIGNORE (verbatim .gitignore content).
make_fixture_repo() {
  mkdir -p "$REPO/src"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email "test@yolotown.local"
  git -C "$REPO" config user.name "yolotown test"

  cat > "$REPO/src/app.js" <<'EOF'
console.log("app ok");
EOF

  cat > "$REPO/check.sh" <<'EOF'
#!/usr/bin/env bash
node --check src/app.js && node src/app.js
EOF
  chmod +x "$REPO/check.sh"

  cat > "$REPO/CLAUDE.md" <<'EOF'
FIXTURE-INVARIANT: src/app.js must keep printing "app ok".
EOF

  if [ -n "${FIXTURE_GITIGNORE:-}" ]; then
    printf '%s\n' "$FIXTURE_GITIGNORE" > "$REPO/.gitignore"
  else
    printf '.env\n.yolotown/\n' > "$REPO/.gitignore"
  fi

  if [ -n "${FIXTURE_CONF:-}" ]; then
    printf '%s\n' "$FIXTURE_CONF" > "$REPO/.yolotown.conf"
  else
    {
      echo "TEST_CMD=\"./check.sh\""
      echo "CLAUDE_BIN=\"$FAKE_CLAUDE\""
      echo "ENV_FILES=\".env\""
      echo "BASE_BRANCH=\"main\""
      local line
      for line in "$@"; do echo "$line"; done
    } > "$REPO/.yolotown.conf"
  fi

  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "fixture baseline"

  printf 'SECRET=fixture-secret\n' > "$REPO/.env"
}

make_bare_origin() {
  git init -q --bare "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" push -qu origin main
}

reset_fixture() {
  rm -rf "$REPO" "$ORIGIN" "$TMP_ROOT"/yt-*
}

# run_seed <task-name> <description> — sets SEED_RC and SEED_OUT.
# stdin is explicitly /dev/null so interactive prompts (e.g. the missing
# base-branch confirmation) deterministically take their non-interactive path.
run_seed() {
  SEED_OUT="$(cd "$REPO" && "$SEED" "$@" </dev/null 2>&1)"
  SEED_RC=$?
}

# run_seed_with_input <stdin-line> <task-name> <description> — like run_seed,
# but feeds a line of input to stdin, simulating an interactive y/N reply.
run_seed_with_input() {
  local input="$1"; shift
  SEED_OUT="$(cd "$REPO" && printf '%s\n' "$input" | "$SEED" "$@" 2>&1)"
  SEED_RC=$?
}

# ---- asserts ----------------------------------------------------------------
_fail() {
  echo "ASSERT FAIL: $*" >&2
  echo "--- seed output ---" >&2
  echo "${SEED_OUT:-<no seed output captured>}" >&2
  exit 1
}
assert_eq()           { [ "$1" = "$2" ]        || _fail "$3: expected \"$2\", got \"$1\""; }
assert_file_exists()  { [ -e "$1" ]            || _fail "$2: file \"$1\" missing"; }
assert_file_missing() { [ ! -e "$1" ]          || _fail "$2: file \"$1\" unexpectedly exists"; }
assert_contains() {
  case "$1" in *"$2"*) ;; *) _fail "$3: output does not contain \"$2\"" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) _fail "$3: output unexpectedly contains \"$2\"" ;; esac
}
ok() { echo "ok: $*"; }
