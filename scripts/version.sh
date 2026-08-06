#!/usr/bin/env bash
# 基点 tag 与 moonfruit tag 之间的换算。命名规则见 docs/specs/2026-08-05-patch-release-design.md §3
#
#   v1.14.0-beta.5-reF1nd          基点（reF1nd 打的）
#   v1.14.0-beta.5-reF1nd-moonfruit    首个派生
#   v1.14.0-beta.5-reF1nd-moonfruit.1  同一基点上的第二个

# base_of <moonfruit-tag> —— 反推基点 tag。
base_of() { printf '%s\n' "${1%-moonfruit*}"; }

# tags_for_base <base-tag> <tag>... —— 属于该基点、且计数器连续的 moonfruit tag，升序输出。
tags_for_base() {
  local base=$1; shift
  local n=0 candidate="${base}-moonfruit"
  while printf '%s\n' "$@" | grep -qxF -- "$candidate"; do
    printf '%s\n' "$candidate"
    n=$((n + 1))
    candidate="${base}-moonfruit.${n}"
  done
}

# latest_target <base-tag> <tag>... —— 该基点下计数器最大的 tag，无则输出空。
latest_target() { tags_for_base "$@" | tail -n1; }

# next_target <base-tag> <tag>... —— 下一个可用的 moonfruit tag。
next_target() {
  local base=$1
  local last; last=$(latest_target "$@")
  if [[ -z "$last" ]]; then
    printf '%s\n' "${base}-moonfruit"
    return
  fi
  local suffix=${last#"${base}-moonfruit"}   # "" 或 ".N"
  printf '%s-moonfruit.%d\n' "$base" "$(( ${suffix#.} + 1 ))"
}
