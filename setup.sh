#!/usr/bin/env bash
# yolotown setup: one-time per-target-repo bootstrap. Currently: ensures a
# git "origin" remote exists, since PUSH_ON_GREEN needs one to push to.
# Run from the target repo root:
#   /path/to/setup.sh
set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: setup.sh

Run from the target repo root. Checks for a git "origin" remote; if one is
missing, asks whether you already have one to add, and otherwise offers to
create one via the gh CLI.
USAGE
  exit 2
}

die() { printf 'setup: error: %s\n' "$*" >&2; exit 1; }

[ $# -eq 0 ] || usage

GH_BIN="${GH_BIN:-gh}"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
TOPLEVEL="$(git rev-parse --show-toplevel)"
[ "$(pwd -P)" = "$TOPLEVEL" ] || die "run from the repo root: $TOPLEVEL"

if git remote get-url origin >/dev/null 2>&1; then
  echo "setup: origin remote already configured: $(git remote get-url origin)"
  exit 0
fi

printf 'setup: no "origin" remote is configured for this repo. Do you already have one you'"'"'d like to use? [y/N] '
REPLY=""
read -r REPLY
case "$REPLY" in
  y|Y|yes|YES)
    printf 'setup: remote URL: '
    URL=""
    read -r URL
    [ -n "$URL" ] || die "no URL given; nothing added"
    git remote add origin "$URL" || die "git remote add origin \"$URL\" failed"
    echo "setup: added origin -> $URL"
    exit 0
    ;;
esac

no_remote_die() {
  die "no remote configured.
if you intend to stay local, set PUSH_ON_GREEN=\"false\" in .yolotown.conf and skip this script.
otherwise add one yourself: git remote add origin <url>"
}

command -v "$GH_BIN" >/dev/null 2>&1 || no_remote_die

printf 'setup: create a new GitHub repo for this project now via gh? [y/N] '
REPLY=""
read -r REPLY
case "$REPLY" in
  y|Y|yes|YES) ;;
  *) no_remote_die ;;
esac

printf 'setup: visibility - public or private? [private] '
VIS=""
read -r VIS
[ -z "$VIS" ] && VIS="private"
case "$VIS" in
  public|private) ;;
  *) die "visibility must be \"public\" or \"private\" (got \"$VIS\")" ;;
esac

"$GH_BIN" repo create --source=. --remote=origin --"$VIS" || die "gh repo create failed"
echo "setup: created GitHub repo and added it as origin -> $(git remote get-url origin)"
