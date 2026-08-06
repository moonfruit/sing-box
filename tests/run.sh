#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
rc=0
for t in "$HERE"/test_*.sh; do
  printf '%s\n' "$(basename "$t")"
  ASSERT_FAILED=0
  # shellcheck disable=SC1090
  ( . "$t"; exit "$ASSERT_FAILED" ) || rc=1
done
if (( rc )); then printf '\n测试失败\n'; else printf '\n全部通过\n'; fi
exit "$rc"
