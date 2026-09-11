#!/usr/bin/env bash
# yolotown lane checking (SPEC.md section 2; run at gate time per section 3.4).
#
# Sourcing this file only defines functions; call yt_lane_check to check a task.
#
# WHAT A LANE IS. Conflict detection (lib/plan.sh) predicts, per task, the files
# that task will have to touch, and writes them to the run dir as plan.json.
# That prediction is the task's lane. At gate time the core asks the only
# question that can be asked afterwards: did the agent stay in it? The answer is
# a diff of the branch against the base — the files the agent ACTUALLY touched —
# against the files the plan said it would.
#
# WARN ONLY. A stray is never a failure. It writes warnings/<task>, which
# lib/report.sh already reads to render PASSED-WITH-WARNING, and nothing else:
# no status transition, no nonzero return, no abandoned commit. Whether lane
# violations ever become blocking is an explicitly deferred decision (SPEC.md
# section 7), so this file has no path that can fail a task even by accident —
# yt_lane_check returns 0 unconditionally and reports through globals.
#
# NO PREDICTION IS NOT A VIOLATION. `yolotown run-one` (and any `run` that
# skipped conflict detection) never writes a plan.json, so most of a task's
# life there is nothing to compare against. A missing plan.json, a plan that
# does not name this task, or a plan that names it with no files, all mean
# "unchecked" — which is silent. Warning there would mean warning on every
# single-task run, which is noise, not signal.
#
#   yt_lane_check <run-dir> <task> <worktree> <base-branch>
#     always returns 0; writes <run-dir>/warnings/<task> only on a stray, and
#     publishes the verdict for the caller's log:
#       YT_LANE_VERDICT  in-lane | strayed | unchecked
#       YT_LANE_STRAY    on "strayed", the stray paths, comma-separated
#       YT_LANE_WARNING  on "strayed", the path of the record it wrote
#
#   yt_lane_predicted <plan.json> <task>   the lane, one path per line
#   yt_lane_touched <worktree> <base>      what was touched, one path per line
#
# Matching is exact on repo-relative paths, both sides being what git and the
# plan already speak. There is deliberately no prefix or directory leniency: a
# warning that quietly forgives a whole subtree is a warning nobody can trust,
# and the cost of being wrong here is one line in a report.

# Error prefix; a CLI entrypoint can set YT_PROG to its own name.
: "${YT_PROG:=yolotown}"

# yt_lane_predicted <plan.json> <task> — print the files plan.json predicts for
#   <task>, one repo-relative path per line. Returns 1 with NO message when
#   there is no usable prediction — no plan file, unreadable or non-plan JSON,
#   the task absent from it, or an empty file list. Absence is an expected
#   answer here (see NO PREDICTION IS NOT A VIOLATION above), not an error.
yt_lane_predicted() {
  local plan="${1:-}" task="${2:-}"
  [ -n "$plan" ] && [ -f "$plan" ] || return 1
  [ -n "$task" ] || return 1
  YT_LANE_PLAN="$plan" YT_LANE_TASK="$task" node -e 'const fs=require("fs");let p;try{p=JSON.parse(fs.readFileSync(process.env.YT_LANE_PLAN,"utf8"))}catch(e){process.exit(1)}const ts=(p&&Array.isArray(p.tasks))?p.tasks:[];const t=ts.find((t)=>t&&t.name===process.env.YT_LANE_TASK);if(!t||!Array.isArray(t.files))process.exit(1);const f=t.files.filter((x)=>typeof x==="string"&&x.trim()).map((x)=>x.trim());if(!f.length)process.exit(1);process.stdout.write(f.join("\n")+"\n")' 2>/dev/null
}

# yt_lane_touched <worktree> <base-branch> — print the repo-relative paths the
#   task's branch changed against <base-branch>, one per line. Run AFTER the
#   commit, so this is exactly the commit's file set; the three-dot form diffs
#   from the merge base, so it stays correct even if the base moved after the
#   worktree was cut (the refactor gate can advance it). Returns 1 with no
#   message if git cannot answer.
yt_lane_touched() {
  local wt="${1:-}" base="${2:-}"
  [ -n "$wt" ] && [ -n "$base" ] || return 1
  git -C "$wt" diff --name-only "$base...HEAD" 2>/dev/null
}

yt_lane_check() {
  local run="${1:-}" task="${2:-}" wt="${3:-}" base="${4:-}"
  YT_LANE_VERDICT="unchecked"
  YT_LANE_STRAY=""
  YT_LANE_WARNING=""

  local predicted touched
  predicted="$(yt_lane_predicted "$run/plan.json" "$task")" || return 0
  touched="$(yt_lane_touched "$wt" "$base")" || return 0

  # Every touched path that the lane does not name. Plain nested string
  # compare: both sides are already repo-relative paths, and a task's file
  # lists are tens of entries, not thousands.
  local -a stray=()
  local f p hit
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hit=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ "$f" = "$p" ]; then hit=1; break; fi
    done <<< "$predicted"
    [ "$hit" -eq 1 ] || stray+=("$f")
  done <<< "$touched"

  if [ "${#stray[@]}" -eq 0 ]; then
    YT_LANE_VERDICT="in-lane"
    return 0
  fi

  YT_LANE_VERDICT="strayed"
  local list=""
  for f in ${stray[@]+"${stray[@]}"}; do
    if [ -z "$list" ]; then list="$f"; else list="$list, $f"; fi
  done
  YT_LANE_STRAY="$list"

  # The record. warnings/ is made on demand, so a run where nothing strayed
  # leaves no empty directory behind. Line 1 is what lib/report.sh surfaces in
  # the table, so it has to stand alone; the rest is for whoever cats the file.
  local dir="$run/warnings" record="$run/warnings/$task"
  mkdir -p "$dir" 2>/dev/null || { YT_LANE_VERDICT="unchecked"; return 0; }
  {
    printf 'strayed outside predicted lane: touched %s\n' "$list"
    printf 'predicted: %s\n' "$(printf '%s' "$predicted" | tr '\n' ' ')"
    printf 'touched:   %s\n' "$(printf '%s' "$touched" | tr '\n' ' ')"
    printf 'warn only: a lane violation never fails a task (SPEC.md sections 2 and 7).\n'
  } > "$record" 2>/dev/null || { YT_LANE_VERDICT="unchecked"; YT_LANE_STRAY=""; return 0; }
  YT_LANE_WARNING="$record"
  return 0
}
