#!/usr/bin/env bash
# yolotown tasks parser: read a backlog file in the documented format and emit
# its (name, description) pairs, or fail fast with line-numbered errors.
#
# Sourcing this file only defines functions; call yt_parse_tasks to do work.
#
# Format, one task per line:
#
#     <short-name> | <description>
#
#   - <short-name> is the text before the first "|", trimmed; it must match
#     [a-z0-9-]+ and be unique across the whole file.
#   - <description> is the text after the first "|", trimmed; it must be
#     non-empty. A "|" inside the description is kept verbatim (only the first
#     "|" splits).
#   - Blank lines and lines whose first non-blank character is "#" are ignored.
#
# yt_parse_tasks <file>
#   On success: prints one line per task to stdout as "<name><TAB><description>"
#   (both trimmed) in file order, and returns 0.
#   On malformed input: prints every offending line to stderr as
#   "<file>:<lineno>: <message>" and returns 1. Nothing is written to stdout,
#   so a caller can safely `read` the output only when the call succeeds.
#   A missing or unreadable file is reported to stderr and returns 2.
#
# Line numbers count every physical line (comments and blanks included), so an
# error always points at the line you would `sed -n '<n>p'`.

# Error prefix; a CLI entrypoint can set YT_PROG to its own name.
: "${YT_PROG:=yolotown}"

# _yt_trim <string> — echo the string with leading/trailing whitespace removed.
_yt_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"   # strip leading whitespace
  s="${s%"${s##*[![:space:]]}"}"   # strip trailing whitespace
  printf '%s' "$s"
}

yt_parse_tasks() {
  local file="$1"

  if [ -z "$file" ]; then
    printf '%s: tasks: no tasks file given\n' "$YT_PROG" >&2
    return 2
  fi
  if [ ! -f "$file" ]; then
    printf '%s: tasks: file not found: %s\n' "$YT_PROG" "$file" >&2
    return 2
  fi
  if [ ! -r "$file" ]; then
    printf '%s: tasks: file not readable: %s\n' "$YT_PROG" "$file" >&2
    return 2
  fi

  local lineno=0 errors=0
  local line trimmed name desc i dup_line
  local -a out=() seen_names=() seen_lines=()

  # `|| [ -n "$line" ]` so a final line with no trailing newline is not dropped.
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))

    # Blank line, or a comment (first non-blank char is "#") — skip it.
    trimmed="$(_yt_trim "$line")"
    [ -z "$trimmed" ] && continue
    case "$trimmed" in \#*) continue ;; esac

    # A real task line must carry the "|" separator.
    case "$line" in
      *"|"*) ;;
      *)
        printf '%s:%d: missing "|" separator (expected "<name> | <description>")\n' \
          "$file" "$lineno" >&2
        errors=$((errors + 1))
        continue
        ;;
    esac

    name="$(_yt_trim "${line%%|*}")"
    desc="$(_yt_trim "${line#*|}")"

    # Name must match [a-z0-9-]+ : non-empty, no character outside the set.
    if [ -z "$name" ]; then
      printf '%s:%d: empty task name (names must match [a-z0-9-]+)\n' \
        "$file" "$lineno" >&2
      errors=$((errors + 1))
      continue
    fi
    case "$name" in
      *[!a-z0-9-]*)
        printf '%s:%d: invalid task name "%s" (names must match [a-z0-9-]+)\n' \
          "$file" "$lineno" "$name" >&2
        errors=$((errors + 1))
        continue
        ;;
    esac

    # Description must be non-empty after trimming.
    if [ -z "$desc" ]; then
      printf '%s:%d: empty description for task "%s"\n' \
        "$file" "$lineno" "$name" >&2
      errors=$((errors + 1))
      continue
    fi

    # Name must be unique across the file; point at where it was first seen.
    dup_line=""
    i=0
    while [ "$i" -lt "${#seen_names[@]}" ]; do
      if [ "${seen_names[$i]}" = "$name" ]; then
        dup_line="${seen_lines[$i]}"
        break
      fi
      i=$((i + 1))
    done
    if [ -n "$dup_line" ]; then
      printf '%s:%d: duplicate task name "%s" (first defined on line %s)\n' \
        "$file" "$lineno" "$name" "$dup_line" >&2
      errors=$((errors + 1))
      continue
    fi

    seen_names+=("$name")
    seen_lines+=("$lineno")
    out+=("$(printf '%s\t%s' "$name" "$desc")")
  done < "$file"

  if [ "$errors" -ne 0 ]; then
    return 1
  fi

  local task
  if [ "${#out[@]}" -ne 0 ]; then
    for task in "${out[@]}"; do
      printf '%s\n' "$task"
    done
  fi
  return 0
}
