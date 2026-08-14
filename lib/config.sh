#!/usr/bin/env bash
# yolotown config loader: defaults, sourcing, and fail-fast validation of
# .yolotown.conf. Sourcing this file only defines things; call yt_load_config
# to actually read the config.
#
# yt_load_config reads ./.yolotown.conf from the current directory (the target
# repo root) and leaves the config in these globals:
#
#   TEST_CMD         (required)              the acceptance gate
#   ENV_FILES        ""                      space-separated git-ignored files
#   INVARIANTS_FILE  CLAUDE.md if present    injected into agent prompts
#   BASE_BRANCH      main                    branch worktrees are cut from
#   BRANCH_PREFIX    feature/                prefix for task branches
#   PUSH_ON_GREEN    true                    "true"|"false"
#   MAX_PARALLEL     3                       workers `run` fans out at once
#   WORKER_MODEL     ""                      empty = claude CLI default
#   CLAUDE_BIN       claude                  agent binary; also the test seam
#
# The conf is plain shell, so unknown keys (SOURCE_GLOBS, PLANNER_MODEL, ... —
# consumed by later stages) are tolerated and ignored here. Any validation
# failure prints to stderr and exits 2; the caller never gets a half-config.

# Error prefix. A later CLI entrypoint can set YT_PROG to its own name.
: "${YT_PROG:=seed}"

conf_die() { printf '%s: config error: %s\n' "$YT_PROG" "$*" >&2; exit 2; }

YT_CONF_EXAMPLE='a minimal valid config:
  TEST_CMD="npm test"'

yt_load_config() {
  [ -f ./.yolotown.conf ] || conf_die "no .yolotown.conf in $PWD
$YT_CONF_EXAMPLE"

  TEST_CMD=""
  ENV_FILES=""
  INVARIANTS_FILE=""
  BASE_BRANCH="main"
  BRANCH_PREFIX="feature/"
  PUSH_ON_GREEN="true"
  MAX_PARALLEL="3"
  WORKER_MODEL=""
  CLAUDE_BIN="claude"

  # shellcheck source=/dev/null
  . ./.yolotown.conf || conf_die ".yolotown.conf failed to source (must be plain shell key=value)"

  [ -n "$TEST_CMD" ] || conf_die "TEST_CMD is required and missing
$YT_CONF_EXAMPLE"

  case "$PUSH_ON_GREEN" in
    true|false) ;;
    *) conf_die "PUSH_ON_GREEN must be \"true\" or \"false\" (got \"$PUSH_ON_GREEN\")" ;;
  esac

  # Bounded parallelism is a hard requirement (rate limits are real), so an
  # unusable bound is a refusal, not a guess: no rounding, no silent default.
  case "$MAX_PARALLEL" in
    ""|*[!0-9]*)
      conf_die "MAX_PARALLEL must be a positive integer (got \"$MAX_PARALLEL\")
  MAX_PARALLEL=\"3\"" ;;
  esac
  [ "$MAX_PARALLEL" -ge 1 ] || conf_die "MAX_PARALLEL must be at least 1 (got \"$MAX_PARALLEL\")
  MAX_PARALLEL=\"3\"    # or run with --serial for one task at a time"

  if [ -z "$INVARIANTS_FILE" ] && [ -f CLAUDE.md ]; then
    INVARIANTS_FILE="CLAUDE.md"
  fi
  if [ -n "$INVARIANTS_FILE" ] && [ ! -f "$INVARIANTS_FILE" ]; then
    conf_die "INVARIANTS_FILE \"$INVARIANTS_FILE\" does not exist"
  fi
}
