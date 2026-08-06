#!/usr/bin/env bash
# 全部脚本共享的日志与 GitHub Actions 交互工具。

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# emit <key> <value> —— 写 step output；本地运行（无 GITHUB_OUTPUT）时打到 stdout 便于观察。
emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

# summary <markdown> —— 追加到 Actions 的 job summary。
summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  else
    printf '%s\n' "$1"
  fi
}
