#!/usr/bin/env bash
# lib/tasks.sh: parse the documented backlog format, emit (name, description)
# pairs, and fail with line-numbered errors on malformed input.
# Exercises the parser directly in a scratch dir — no git, no agent needed.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$YOLOTOWN_ROOT/lib/tasks.sh"

TASKS_DIR="$TMP_ROOT/tasks"
mkdir -p "$TASKS_DIR"
TASKS_FILE="$TASKS_DIR/tasks.txt"
TAB="$(printf '\t')"

# parse <file-content> — writes the content to TASKS_FILE and runs the parser.
# Sets PARSE_RC, PARSE_OUT (stdout), PARSE_ERR (stderr). SEED_OUT mirrors both
# so helpers.sh's asserts dump something useful on failure.
parse() {
  printf '%s' "$1" > "$TASKS_FILE"
  PARSE_OUT="$(yt_parse_tasks "$TASKS_FILE" 2>"$TASKS_DIR/err")"
  PARSE_RC=$?
  PARSE_ERR="$(cat "$TASKS_DIR/err")"
  SEED_OUT="stdout:
$PARSE_OUT
stderr:
$PARSE_ERR"
}

# line_count <string> — number of non-empty lines.
line_count() {
  [ -z "$1" ] && { echo 0; return; }
  printf '%s\n' "$1" | grep -c .
}

# ---- a clean file: comments, blanks, and well-formed tasks ------------------
parse '# a header comment
   # an indented comment

first-task | do the first thing
second-2 | do the second thing

# trailing comment
'
assert_eq "$PARSE_RC" 0 "clean file parses"
assert_eq "$PARSE_ERR" "" "clean file produces no errors"
assert_eq "$(line_count "$PARSE_OUT")" 2 "two task lines emitted"
assert_contains "$PARSE_OUT" "first-task${TAB}do the first thing"   "first task emitted as name<TAB>desc"
assert_contains "$PARSE_OUT" "second-2${TAB}do the second thing"    "second task emitted as name<TAB>desc"
ok "clean file"

# ---- names may use lowercase letters, digits, and hyphens -------------------
parse 'run-dir | make run dirs
fan-out | bounded workers
a | single char name
config-loader-2 | mix of all'
assert_eq "$PARSE_RC" 0 "valid names accepted"
assert_eq "$(line_count "$PARSE_OUT")" 4 "all four valid-named tasks emitted"
ok "valid name character set"

# ---- leading/trailing whitespace is trimmed off name and description --------
parse '   spaced-name    |    a padded description   '
assert_eq "$PARSE_RC" 0 "padded line parses"
assert_contains "$PARSE_OUT" "spaced-name${TAB}a padded description" "name and desc are trimmed"
assert_not_contains "$PARSE_OUT" "spaced-name${TAB} " "no leading space left on description"
ok "whitespace trimmed"

# ---- a "|" inside the description is preserved (only the first splits) -------
parse 'cli | dispatch plan | run | status'
assert_eq "$PARSE_RC" 0 "description with pipes parses"
assert_contains "$PARSE_OUT" "cli${TAB}dispatch plan | run | status" "only the first pipe splits"
ok "pipe inside description preserved"

# ---- missing separator ------------------------------------------------------
parse 'good-task | fine
this line has no separator'
assert_eq "$PARSE_RC" 1 "missing separator fails"
assert_eq "$PARSE_OUT" "" "no stdout when the file is malformed"
assert_contains "$PARSE_ERR" ":2:" "error names the offending line number"
assert_contains "$PARSE_ERR" "separator" "error explains the missing separator"
ok "missing separator"

# ---- invalid name characters ------------------------------------------------
parse 'Bad_Name | uppercase and underscore not allowed'
assert_eq "$PARSE_RC" 1 "invalid name fails"
assert_contains "$PARSE_ERR" ":1:" "error names the line"
assert_contains "$PARSE_ERR" "Bad_Name" "error quotes the offending name"
assert_contains "$PARSE_ERR" "[a-z0-9-]+" "error shows the required pattern"
ok "invalid name characters"

# ---- empty name (line starts with the separator) ----------------------------
parse ' | description but no name'
assert_eq "$PARSE_RC" 1 "empty name fails"
assert_contains "$PARSE_ERR" ":1:" "error names the line"
assert_contains "$PARSE_ERR" "empty task name" "error says the name is empty"
ok "empty name"

# ---- empty description ------------------------------------------------------
parse 'lonely |    '
assert_eq "$PARSE_RC" 1 "empty description fails"
assert_contains "$PARSE_ERR" ":1:" "error names the line"
assert_contains "$PARSE_ERR" "empty description" "error says the description is empty"
assert_contains "$PARSE_ERR" "lonely" "error names the task"
ok "empty description"

# ---- duplicate name ---------------------------------------------------------
parse 'dup | first definition
other | unrelated
dup | second definition'
assert_eq "$PARSE_RC" 1 "duplicate name fails"
assert_contains "$PARSE_ERR" ":3:" "error points at the second occurrence"
assert_contains "$PARSE_ERR" "duplicate task name" "error explains the duplicate"
assert_contains "$PARSE_ERR" "dup" "error names the duplicated task"
assert_contains "$PARSE_ERR" "line 1" "error points back at the first definition"
ok "duplicate name"

# ---- multiple malformed lines are all reported ------------------------------
parse 'ok-one | fine
no separator here
Bad | invalid name
ok-two | also fine
still-ok |   '
assert_eq "$PARSE_RC" 1 "any malformed line fails the parse"
assert_contains "$PARSE_ERR" ":2:" "line 2 reported"
assert_contains "$PARSE_ERR" ":3:" "line 3 reported"
assert_contains "$PARSE_ERR" ":5:" "line 5 reported"
assert_eq "$(line_count "$PARSE_ERR")" 3 "exactly the three bad lines reported"
ok "multiple errors"

# ---- line numbers account for comments and blank lines ----------------------
parse '# comment on line 1

good | line 3 is fine
# comment on line 4
broken line 5'
assert_eq "$PARSE_RC" 1 "trailing broken line fails"
assert_contains "$PARSE_ERR" ":5:" "line number counts comments and blanks"
ok "line numbering with comments and blanks"

# ---- empty file and comments-only file are valid, emit nothing --------------
parse ''
assert_eq "$PARSE_RC" 0 "empty file is valid"
assert_eq "$PARSE_OUT" "" "empty file emits nothing"

parse '# just comments

# nothing but comments and blanks
'
assert_eq "$PARSE_RC" 0 "comments-only file is valid"
assert_eq "$PARSE_OUT" "" "comments-only file emits nothing"
ok "empty and comments-only files"

# ---- final line with no trailing newline is not dropped ---------------------
printf '%s' 'no-newline | this line ends without a newline' > "$TASKS_FILE"
PARSE_OUT="$(yt_parse_tasks "$TASKS_FILE" 2>/dev/null)"; PARSE_RC=$?
assert_eq "$PARSE_RC" 0 "unterminated final line parses"
assert_contains "$PARSE_OUT" "no-newline${TAB}this line ends without a newline" "final line captured"
ok "unterminated final line"

# ---- missing / unreadable file ----------------------------------------------
PARSE_OUT="$(yt_parse_tasks "$TASKS_DIR/does-not-exist.txt" 2>"$TASKS_DIR/err")"; PARSE_RC=$?
PARSE_ERR="$(cat "$TASKS_DIR/err")"
assert_eq "$PARSE_RC" 2 "missing file returns 2"
assert_contains "$PARSE_ERR" "not found" "error says the file is missing"
assert_contains "$PARSE_ERR" "does-not-exist.txt" "error names the missing file"

PARSE_OUT="$(yt_parse_tasks "" 2>"$TASKS_DIR/err")"; PARSE_RC=$?
PARSE_ERR="$(cat "$TASKS_DIR/err")"
assert_eq "$PARSE_RC" 2 "no file argument returns 2"
assert_contains "$PARSE_ERR" "no tasks file" "error says no file was given"
ok "missing / unreadable file"

# ---- the repo's own tasks.txt is valid under this parser --------------------
# Ties the parser to the documented format the backlog is actually written in.
PARSE_OUT="$(yt_parse_tasks "$YOLOTOWN_ROOT/tasks.txt" 2>"$TASKS_DIR/err")"; PARSE_RC=$?
PARSE_ERR="$(cat "$TASKS_DIR/err")"
assert_eq "$PARSE_RC" 0 "repo tasks.txt parses cleanly"
assert_eq "$PARSE_ERR" "" "repo tasks.txt has no errors"
# Structural, so this keeps its teeth as completed tasks leave the backlog:
# every emitted line must carry a valid name, a TAB, and a non-empty
# description. Asserting only on hardcoded task names would rot the moment a
# task ships and is removed from the file.
[ -n "$PARSE_OUT" ] || _fail "repo tasks.txt should yield at least one task"
while IFS= read -r emitted; do
  case "$emitted" in
    *"$TAB"*) ;;
    *) _fail "repo tasks.txt line emitted without a TAB separator: $emitted" ;;
  esac
  emitted_name="${emitted%%"$TAB"*}"
  emitted_desc="${emitted#*"$TAB"}"
  case "$emitted_name" in
    ""|*[!a-z0-9-]*) _fail "repo tasks.txt emitted an invalid task name: \"$emitted_name\"" ;;
  esac
  [ -n "$emitted_desc" ] || _fail "repo tasks.txt task \"$emitted_name\" has an empty description"
done <<EOF
$PARSE_OUT
EOF
# The next task to dispatch must be present by name, so an accidental
# truncation of the backlog fails loudly rather than silently passing.
assert_contains "$PARSE_OUT" "fan-out${TAB}" "repo tasks.txt still carries the final Stage 1 task"
ok "repo tasks.txt is well-formed"

echo "tasks: all cases passed"
