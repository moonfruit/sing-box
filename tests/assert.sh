#!/usr/bin/env bash
# 极简断言。失败即置位 ASSERT_FAILED，由 tests/run.sh 汇总退出码。
ASSERT_FAILED=${ASSERT_FAILED:-0}

assert_eq() {
  local actual=$1 expected=$2 label=${3:-assert_eq}
  if [[ "$actual" == "$expected" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s\n       期望: %q\n       实际: %q\n' "$label" "$expected" "$actual"
    ASSERT_FAILED=1
  fi
}

assert_ok() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then printf '  ok   %s\n' "$label"
  else printf '  FAIL %s（命令应成功却失败: %s）\n' "$label" "$*"; ASSERT_FAILED=1; fi
}

assert_fail() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then printf '  FAIL %s（命令应失败却成功: %s）\n' "$label" "$*"; ASSERT_FAILED=1
  else printf '  ok   %s\n' "$label"; fi
}

assert_contains() {
  local haystack=$1 needle=$2 label=${3:-assert_contains}
  if [[ "$haystack" == *"$needle"* ]]; then printf '  ok   %s\n' "$label"
  else printf '  FAIL %s\n       未包含: %q\n' "$label" "$needle"; ASSERT_FAILED=1; fi
}
