#!/usr/bin/env bash
# Run every test_*.sh file in this directory; print per-file PASS/FAIL plus
# an overall summary. Exits non-zero if any file failed.
set -uo pipefail

cd "$(dirname "$0")"
shopt -s nullglob

PASSED=()
FAILED=()

for f in test_*.sh; do
  echo "=== $f ==="
  if bash "$f"; then
    PASSED+=("$f")
  else
    FAILED+=("$f")
  fi
done

echo
echo "Summary:"
if (( ${#PASSED[@]} > 0 )); then
  for f in "${PASSED[@]}"; do echo "  PASS: $f"; done
fi
if (( ${#FAILED[@]} > 0 )); then
  for f in "${FAILED[@]}"; do echo "  FAIL: $f"; done
fi
echo

if (( ${#FAILED[@]} == 0 )); then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
