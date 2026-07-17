#!/usr/bin/env bash
# yolotown test runner: executes each tests/*.test.sh in its own process,
# serially. Nonzero exit if any test file fails.
#   RUN_LIVE=1  also run the live smoke test (costs tokens)
#   KEEP_TMP=1  preserve test temp dirs for autopsy
set -u
cd "$(dirname "$0")"

pass=0
fail=0
failed_files=""

for t in tests/*.test.sh; do
  echo "=== $t"
  if bash "$t"; then
    echo "--- PASS $t"
    pass=$((pass + 1))
  else
    echo "--- FAIL $t"
    fail=$((fail + 1))
    failed_files="$failed_files $t"
  fi
  echo
done

echo "test.sh: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  echo "failed:$failed_files"
  exit 1
fi
exit 0
