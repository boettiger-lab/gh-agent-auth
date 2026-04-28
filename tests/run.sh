#!/usr/bin/env bash
# Run all test_*.sh files in this directory, summarize results.
set -uo pipefail

cd "$(dirname "$0")"

ANY_FAIL=0
shopt -s nullglob
for f in test_*.sh; do
  echo "=== $f ==="
  if bash "$f"; then
    :
  else
    ANY_FAIL=1
  fi
done

echo
if (( ANY_FAIL == 0 )); then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
