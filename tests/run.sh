#!/usr/bin/env bash
# Run every tests/test_*.sh. No network access is needed or used.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
rc=0
for t in test_*.sh; do
  printf '== %s\n' "$t"
  bash "$t" || rc=1
done
[[ $rc -eq 0 ]] && echo "all tests passed" || echo "TESTS FAILED"
exit $rc
