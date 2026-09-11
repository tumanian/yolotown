#!/usr/bin/env bash
# yolotown conflict detection (SPEC.md section 3.1): ONE headless call on
# PLANNER_MODEL, given the parsed task list and the SOURCE_GLOBS file inventory,
# answering with machine-parseable JSON that maps each task to the files it will
# likely touch, sorts it into exactly one of three buckets, and reports every
# overlapping group. The validated answer is written to the run dir as
# plan.json.
#
# Sourcing this file only defines functions; call yt_plan to do work.
#
#   yt_plan <run-dir> <tasks-tsv>
#     <tasks-tsv> is yt_parse_tasks output: "<name><TAB><description>" per line.
#     reads (from config): SOURCE_GLOBS CLAUDE_BIN PLANNER_MODEL
#     must be called from the repo root (the inventory is `git ls-files`).
#     writes <run-dir>/plan.json and prints its path on stdout; progress goes
#     to stderr, so `plan_file="$(yt_plan ...)"` is the intended use.
#     Returns 0 on a plan, 1 on ANY failure — see "hard failure" below.
#
#   yt_plan_inventory                  the SOURCE_GLOBS inventory, one path/line
#   yt_plan_tasks <plan.json>          "<name><TAB><bucket><TAB><files...>"
#   yt_plan_collisions <plan.json>     "<bucket><TAB><tasks><TAB><files><TAB><reason>"
#
# The three buckets, one per task:
#   DISJOINT              shares no predicted file with any other task
#   COLLIDING-SPLITTABLE  overlaps, but a shared module could be split apart
#   INHERENTLY-COUPLED    overlaps in the same logic; must run sequentially
#
# plan.json, exactly as this file writes it (canonical, 2-space indented, task
# order = backlog order):
#
#     {
#       "tasks": [
#         { "name": "alpha", "bucket": "DISJOINT", "files": ["src/alpha.js"] }
#       ],
#       "collisions": [
#         { "tasks": ["beta", "gamma"], "files": ["src/shared.js"],
#           "bucket": "COLLIDING-SPLITTABLE", "reason": "both rewrite the router" }
#       ]
#     }
#
# A collision's "bucket" is derived here from its member tasks (which must all
# agree), so a reader never has to cross-reference to render a group.
#
# HARD FAILURE, NEVER A GUESS. A response that is unparseable, incomplete, or
# self-contradictory fails the whole call, names exactly what was wrong, and
# writes no plan.json. There is deliberately no lenient path and no fallback to
# "everything is disjoint": that fallback is the single most dangerous failure
# this tool could have, because it green-lights a fan-out of tasks that will
# stomp each other's files. Rejected, specifically:
#   - no JSON object in the response, or JSON that does not parse
#   - a missing/duplicated/unknown task name, or a bucket outside the three
#   - a task with no predicted files
#   - a collision naming fewer than two tasks, an unknown task, a DISJOINT
#     task, or tasks whose buckets disagree
#   - a collision whose shared file only one of its tasks predicts
#   - a task bucketed as colliding that appears in no collision
#   - ANY two tasks that predict the same file without a collision reporting
#     them together — the model's own file lists are checked against its own
#     collision report here, so an agreeable "all disjoint" cannot slip through
#
# All JSON parsing and generation happens in node (CLAUDE.md: node one-liners,
# no jq, no dependencies). The validator is the one node program here that is
# not a one-liner, because every check it makes is JSON-shape work that bash
# cannot do; the orchestration around it stays in bash.

# Error prefix; a CLI entrypoint can set YT_PROG to its own name.
: "${YT_PROG:=yolotown}"

_yt_plan_die() { printf '%s: plan: %s\n' "$YT_PROG" "$*" >&2; return 1; }

# The planner prompt carries a stable marker, exactly as the reachability probe
# does (lib/task.sh), so a test shim can tell a PLANNER call from a TASK-AGENT
# call: at Stage 3 one `run` makes both through the same CLAUDE_BIN.
# tests/fake-claude answers a prompt carrying this marker from its own
# FAKE_CLAUDE_PLAN_MODE, leaving FAKE_CLAUDE_MODE to mean "how the task agent
# behaves". Change the marker here and you must change it there.
YT_PLAN_MARKER="yolotown-conflict-detection-plan"

# _yt_plan_show <file> — echo a captured model response to stderr, indented and
# bounded, so a rejection is diagnosable without rerunning the planner.
_yt_plan_show() {
  local file="$1" line n=0
  if [ ! -s "$file" ]; then
    printf '  (empty)\n' >&2
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$n" -gt 60 ]; then
      printf '  ... (truncated; the planner said more)\n' >&2
      return 0
    fi
    printf '  %s\n' "$line" >&2
  done < "$file"
}

# yt_plan_inventory — print the SOURCE_GLOBS file inventory, one repo-relative
# path per line. Must run from the repo root. Fails (naming SOURCE_GLOBS) when
# the key is empty or matches nothing tracked: planning against an empty
# inventory would produce confident nonsense.
yt_plan_inventory() {
  if [ -z "${SOURCE_GLOBS:-}" ]; then
    _yt_plan_die "SOURCE_GLOBS is empty; it must name at least one glob
  SOURCE_GLOBS=\"*.js *.ts *.md\"    # in .yolotown.conf"
    return 1
  fi

  # SOURCE_GLOBS is a space-separated list of git pathspecs; split it on
  # whitespace but keep the shell from expanding the globs itself (they are
  # git's to interpret, and git matches at any depth).
  local -a globs=()
  local g noglob_was_set=0
  case "$-" in *f*) noglob_was_set=1 ;; esac
  set -f
  for g in $SOURCE_GLOBS; do globs+=("$g"); done
  [ "$noglob_was_set" -eq 1 ] || set +f

  local out
  if ! out="$(git ls-files -- "${globs[@]}" 2>&1)"; then
    _yt_plan_die "git ls-files failed for SOURCE_GLOBS \"$SOURCE_GLOBS\": $out"
    return 1
  fi
  if [ -z "$out" ]; then
    _yt_plan_die "SOURCE_GLOBS matched no tracked files in $PWD
  SOURCE_GLOBS=\"$SOURCE_GLOBS\"
check the globs against: git ls-files | head"
    return 1
  fi
  printf '%s\n' "$out"
}

# _yt_plan_prompt <tasks-tsv> <inventory> — print the planner prompt. The task
# and inventory lines carry the "TASK "/"FILE " prefixes so a consumer (the
# model, and tests/fake-claude) can pick them out of the prose unambiguously.
_yt_plan_prompt() {
  local tasks="$1" inv="$2" name desc path

  cat <<EOF
${YT_PLAN_MARKER}

You are the conflict detector for a parallel task runner. Every task below is
about to be executed by its own agent, in its own git worktree, at the same
time as all the others. Predict which files each task will have to touch, and
report every group of tasks whose predicted files overlap.

TASKS (one per line, "TASK <name> | <description>"):
EOF

  while IFS=$'\t' read -r name desc; do
    [ -n "$name" ] || continue
    printf 'TASK %s | %s\n' "$name" "$desc"
  done <<< "$tasks"

  cat <<'EOF'

FILE INVENTORY (the repository's source files, one per line, "FILE <path>"):
EOF

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf 'FILE %s\n' "$path"
  done <<< "$inv"

  cat <<'EOF'

BUCKETS — sort every task into exactly one:
  DISJOINT              shares no predicted file with any other task
  COLLIDING-SPLITTABLE  overlaps another task, but the shared module could be
                        split so that the tasks become disjoint
  INHERENTLY-COUPLED    overlaps another task in the same logic; they must run
                        sequentially, each rebased on the previous result

ANSWER FORMAT — reply with ONE JSON object and nothing else:
{
  "tasks": [
    {"name": "<task name>", "files": ["<path>", ...], "bucket": "<bucket>"}
  ],
  "collisions": [
    {"tasks": ["<name>", "<name>"], "files": ["<shared path>", ...],
     "reason": "<one line: why these tasks overlap>"}
  ]
}

RULES — a response that breaks one of these is rejected, not repaired:
- "tasks" lists every task above exactly once, by its exact name, and no others.
- "files" holds repo-relative paths; a task may predict a file that does not
  exist yet. Every task predicts at least one file.
- Every task named in a collision is bucketed COLLIDING-SPLITTABLE or
  INHERENTLY-COUPLED, and all tasks in one collision share that same bucket.
- Every task bucketed COLLIDING-SPLITTABLE or INHERENTLY-COUPLED appears in at
  least one collision.
- Each path in a collision's "files" is predicted by at least two of that
  collision's tasks.
- Any two tasks that predict the same file MUST appear together in a collision.
  A missed collision green-lights a parallel run whose agents overwrite each
  other; when in doubt, report the collision.
EOF
}

# _yt_plan_validator — print the node validator. It reads the raw response from
# $YT_PLAN_RAW and the expected task names (one per line, backlog order) from
# $YT_PLAN_NAMES; on success it writes canonical plan JSON to stdout, on any
# violation it writes one line naming the violation to stderr and exits 1.
_yt_plan_validator() {
  cat <<'JS'
const fs = require("fs");
const raw = fs.readFileSync(process.env.YT_PLAN_RAW, "utf8");
const want = fs.readFileSync(process.env.YT_PLAN_NAMES, "utf8").split("\n").filter(Boolean);
const die = (m) => { console.error(m); process.exit(1); };
const q = JSON.stringify;

// Tolerate chatter around the object, never tolerate a missing or broken one.
const s = raw.indexOf("{"), e = raw.lastIndexOf("}");
if (s < 0 || e < s) die("the response carries no JSON object (no \"{ ... }\" in it)");
let p;
try { p = JSON.parse(raw.slice(s, e + 1)); }
catch (err) { die("the response is not parseable JSON: " + err.message); }

if (!p || typeof p !== "object" || Array.isArray(p)) die("the top-level JSON value is not an object");
if (!Array.isArray(p.tasks)) die("\"tasks\" is missing or not an array");
if (!Array.isArray(p.collisions)) die("\"collisions\" is missing or not an array (use [] when there are none)");

const BUCKETS = ["DISJOINT", "COLLIDING-SPLITTABLE", "INHERENTLY-COUPLED"];
// Object.create(null): a task may legally be named "constructor".
const bucket = Object.create(null), files = Object.create(null);

for (const t of p.tasks) {
  if (!t || typeof t !== "object" || Array.isArray(t)) die("\"tasks\" holds an entry that is not an object");
  if (typeof t.name !== "string" || !t.name) die("a \"tasks\" entry has no \"name\"");
  if (!want.includes(t.name)) die("\"tasks\" names " + q(t.name) + ", which is not a task in this backlog");
  if (t.name in bucket) die("task " + q(t.name) + " appears more than once in \"tasks\"");
  if (!BUCKETS.includes(t.bucket)) die("task " + q(t.name) + " has bucket " + q(t.bucket) + " (expected one of " + BUCKETS.join(", ") + ")");
  if (!Array.isArray(t.files) || t.files.length === 0) die("task " + q(t.name) + " predicts no files (\"files\" is missing or empty)");
  const fl = [];
  for (const f of t.files) {
    if (typeof f !== "string" || !f.trim()) die("task " + q(t.name) + " has an empty or non-string entry in \"files\"");
    fl.push(f.trim());
  }
  bucket[t.name] = t.bucket;
  files[t.name] = fl;
}
for (const n of want) if (!(n in bucket)) die("task " + q(n) + " is missing from \"tasks\"");

const pairs = new Set(), colliding = new Set();
// Task names cannot contain a space ([a-z0-9-]+), so this key is unambiguous.
const pair = (a, b) => (a < b ? a + " " + b : b + " " + a);

p.collisions.forEach((c, i) => {
  const at = "collision #" + (i + 1);
  if (!c || typeof c !== "object" || Array.isArray(c)) die(at + " is not an object");
  if (!Array.isArray(c.tasks) || c.tasks.length < 2) die(at + " must name at least two tasks");
  const seen = new Set();
  const groupBucket = bucket[c.tasks[0]];
  for (const n of c.tasks) {
    if (typeof n !== "string" || !(n in bucket)) die(at + " names " + q(n) + ", which is not a task in \"tasks\"");
    if (seen.has(n)) die(at + " names task " + q(n) + " twice");
    seen.add(n);
    if (bucket[n] === "DISJOINT") die(at + " names task " + q(n) + ", which is bucketed DISJOINT (a colliding task is COLLIDING-SPLITTABLE or INHERENTLY-COUPLED)");
    if (bucket[n] !== groupBucket) die(at + " mixes buckets: " + q(c.tasks[0]) + " is " + groupBucket + " but " + q(n) + " is " + bucket[n]);
    colliding.add(n);
  }
  if (!Array.isArray(c.files) || c.files.length === 0) die(at + " reports no shared files (\"files\" is missing or empty)");
  const fl = [];
  for (const f of c.files) {
    if (typeof f !== "string" || !f.trim()) die(at + " has an empty or non-string entry in \"files\"");
    const path = f.trim();
    const owners = c.tasks.filter((n) => files[n].includes(path));
    if (owners.length < 2) die(at + " lists shared file " + q(path) + ", but " + owners.length + " of its tasks predict it (a shared file is predicted by at least two)");
    fl.push(path);
  }
  for (let a = 0; a < c.tasks.length; a++)
    for (let b = a + 1; b < c.tasks.length; b++) pairs.add(pair(c.tasks[a], c.tasks[b]));
  c.tasks = c.tasks.slice();
  c.files = fl;
  c.bucket = groupBucket;
});

for (const n of want)
  if (bucket[n] !== "DISJOINT" && !colliding.has(n))
    die("task " + q(n) + " is bucketed " + bucket[n] + " but appears in no collision");

// The load-bearing check: the report is cross-examined against the model's own
// file predictions, so an unreported overlap cannot pass as DISJOINT.
for (let i = 0; i < want.length; i++) {
  for (let j = i + 1; j < want.length; j++) {
    const a = want[i], b = want[j];
    const shared = files[a].filter((f) => files[b].includes(f));
    if (shared.length && !pairs.has(pair(a, b)))
      die("tasks " + q(a) + " and " + q(b) + " both predict " + q(shared[0]) + ", but no collision reports them together (bucketed " + bucket[a] + " and " + bucket[b] + "); an unreported overlap would green-light a colliding parallel run");
  }
}

const out = {
  tasks: want.map((n) => ({ name: n, bucket: bucket[n], files: files[n] })),
  collisions: p.collisions.map((c) => ({
    tasks: c.tasks,
    files: c.files,
    bucket: c.bucket,
    reason: typeof c.reason === "string" ? c.reason.trim() : "",
  })),
};
process.stdout.write(JSON.stringify(out, null, 2) + "\n");
JS
}

yt_plan() {
  local run="$1" tasks="${2:-}"

  if [ -z "$run" ] || [ ! -d "$run" ]; then
    _yt_plan_die "no run dir at ${run:-<unset>} (create it with yt_run_create first)"
    return 1
  fi
  if [ -z "$tasks" ]; then
    _yt_plan_die "no tasks given (expected yt_parse_tasks output: \"<name><TAB><description>\" per line)"
    return 1
  fi
  if [ -z "${CLAUDE_BIN:-}" ]; then
    _yt_plan_die "CLAUDE_BIN is empty (load the config first)"
    return 1
  fi

  local inv
  inv="$(yt_plan_inventory)" || return 1

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/yt-plan.XXXXXX")" || {
    _yt_plan_die "cannot create a temp dir for the planner call"
    return 1
  }
  local names="$tmp/names" rawf="$tmp/response" errf="$tmp/stderr"
  : > "$names"

  local name desc ntasks=0
  while IFS=$'\t' read -r name desc; do
    [ -n "$name" ] || continue
    printf '%s\n' "$name" >> "$names"
    ntasks=$((ntasks + 1))
  done <<< "$tasks"
  if [ "$ntasks" -eq 0 ]; then
    rm -rf "$tmp"
    _yt_plan_die "the task list is empty; there is nothing to plan"
    return 1
  fi

  local nfiles
  nfiles="$(printf '%s\n' "$inv" | wc -l | tr -d ' ')"
  printf '%s: plan: planner: %s (model: %s) on %d task(s), %d inventory file(s)\n' \
    "$YT_PROG" "$CLAUDE_BIN" "${PLANNER_MODEL:-cli default}" "$ntasks" "$nfiles" >&2

  local prompt rc
  prompt="$(_yt_plan_prompt "$tasks" "$inv")"

  # Read-only tools: the planner predicts, it never edits. stdin from /dev/null
  # for the same reason as every other headless call here — it must not inherit,
  # or stall on, the caller's stdin. stdout is the answer, stderr is kept apart
  # so CLI chatter can never be mistaken for part of the JSON.
  "$CLAUDE_BIN" -p "$prompt" \
    ${PLANNER_MODEL:+--model "$PLANNER_MODEL"} \
    --allowedTools "Read" "Glob" "Grep" </dev/null >"$rawf" 2>"$errf"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    _yt_plan_die "the planner exited nonzero ($rc): $CLAUDE_BIN"
    printf 'planner stderr:\n' >&2
    _yt_plan_show "$errf"
    printf 'planner stdout:\n' >&2
    _yt_plan_show "$rawf"
    printf 'refusing to write plan.json: a guessed plan would green-light a colliding fan-out.\n' >&2
    rm -rf "$tmp"
    return 1
  fi

  if [ ! -s "$rawf" ]; then
    _yt_plan_die "the planner returned no output at all (exit 0, empty stdout)"
    printf 'planner stderr:\n' >&2
    _yt_plan_show "$errf"
    printf 'refusing to write plan.json: a guessed plan would green-light a colliding fan-out.\n' >&2
    rm -rf "$tmp"
    return 1
  fi

  local canonical verr
  canonical="$(YT_PLAN_RAW="$rawf" YT_PLAN_NAMES="$names" node -e "$(_yt_plan_validator)" 2>"$errf")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    verr="$(cat "$errf")"
    _yt_plan_die "the planner's response is malformed: ${verr:-node failed to run the validator (exit $rc)}"
    printf 'planner response was:\n' >&2
    _yt_plan_show "$rawf"
    printf 'refusing to write plan.json: a guessed plan would green-light a colliding fan-out.\n' >&2
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$tmp"

  local plan="$run/plan.json"
  printf '%s\n' "$canonical" > "$plan" || {
    _yt_plan_die "cannot write $plan"
    return 1
  }
  printf '%s: plan: wrote %s\n' "$YT_PROG" "$plan" >&2
  printf '%s\n' "$plan"
}

# yt_plan_tasks <plan.json> — print "<name><TAB><bucket><TAB><files, space-separated>"
# per task, in backlog order.
yt_plan_tasks() {
  local f="${1:-}"
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    _yt_plan_die "no plan file at ${f:-<unset>}"
    return 1
  fi
  YT_PLAN_FILE="$f" node -e 'const p=JSON.parse(require("fs").readFileSync(process.env.YT_PLAN_FILE,"utf8"));for(const t of p.tasks)process.stdout.write(t.name+"\t"+t.bucket+"\t"+t.files.join(" ")+"\n")' \
    || { _yt_plan_die "cannot read the plan at $f (not the JSON yt_plan writes)"; return 1; }
}

# yt_plan_collisions <plan.json> — print
# "<bucket><TAB><tasks, space-separated><TAB><files, space-separated><TAB><reason>"
# per reported collision. No output at all means a fully disjoint plan.
yt_plan_collisions() {
  local f="${1:-}"
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    _yt_plan_die "no plan file at ${f:-<unset>}"
    return 1
  fi
  YT_PLAN_FILE="$f" node -e 'const p=JSON.parse(require("fs").readFileSync(process.env.YT_PLAN_FILE,"utf8"));for(const c of p.collisions)process.stdout.write(c.bucket+"\t"+c.tasks.join(" ")+"\t"+c.files.join(" ")+"\t"+c.reason+"\n")' \
    || { _yt_plan_die "cannot read the plan at $f (not the JSON yt_plan writes)"; return 1; }
}
