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

# git_auth_header <token> —— 构造供 `git config http.<url>.extraheader` 使用的
# Basic Auth 值，与 actions/checkout 内部使用的格式一致。
#
# 只应通过 git_auth_set/git_auth_clear 临时写入、用完即清 —— 见 release.yml 里
# checkout 改用 persist-credentials: false 的说明：凭据不该在整个 job 期间
# 持久存在于 .git/config，因为同一目录里随后会跑 claude -p，它的提示词里含
# 第三方内容（reF1nd 的提交说明），一份长期存在的强凭据是不必要的暴露面。
git_auth_header() {
  printf 'AUTHORIZATION: basic %s' "$(printf 'x-access-token:%s' "$1" | base64 | tr -d '\n')"
}

# git_auth_set <token> —— 为当前仓库临时配置 GitHub 的推送/拉取凭据。
git_auth_set() {
  git config --local http.https://github.com/.extraheader "$(git_auth_header "$1")"
}

# git_auth_clear —— 清除 git_auth_set 写入的凭据。调用方必须在推送/拉取完成后
# 立即调用，不依赖 job 结束时的工作区回收。
git_auth_clear() {
  git config --local --unset-all http.https://github.com/.extraheader 2>/dev/null || true
}
