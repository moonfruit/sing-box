#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
. "$HERE/../scripts/lib.sh"
. "$HERE/../scripts/tap-bump.sh"

PATH="$HERE/stubs:$PATH"
BREW_STUB_LOG=$(mktemp); export BREW_STUB_LOG

# 测试自带凭据：tap_bump 用 ${HOMEBREW_GITHUB_API_TOKEN:?} 断言其存在，
# 不自带就只在开发机恰好导出了真实 PAT 时才通过。值无所谓，brew 与 gh 都是 stub。
export HOMEBREW_GITHUB_API_TOKEN=stub-token
GH_STUB_LOG=$(mktemp); export GH_STUB_LOG

# 缩短轮询间隔，测试不必真等
export TAP_CHECK_INTERVAL=0 TAP_CHECK_TRIES=3
# 指向临时文件而不是清掉它：emit 在 CI 里写 $GITHUB_OUTPUT、在本地打 stdout，
# 断言若只看 stdout，就只在没有该变量的机器上成立。这里验生产实际走的那条路。
GITHUB_OUTPUT=$(mktemp); export GITHUB_OUTPUT
out=$(tap_bump v1.14.0-beta.5-reF1nd-moonfruit)
logged=$(cat "$BREW_STUB_LOG")

assert_contains "$logged" "bump-formula-pr"                             "调用 bump-formula-pr"
assert_contains "$logged" "--version=1.14.0-beta.5-reF1nd-moonfruit"    "版本号去掉了前导 v"
assert_contains "$logged" "moonfruit/tap/sing-box-ref1nd"               "目标 formula 正确"
assert_contains "$logged" "--no-browse"                                 "不打开浏览器"
# fine-grained token 无权创建 fork，brew 一旦退回 fork 路径就会直接失败
assert_contains "$logged" "--no-fork"                                   "禁用 fork，直推 tap"

# 打标签这一步是 tap 构建 bottle 的触发器。这里对 pr edit 那一行做整行精确匹配，
# 而不是在整块日志上做子串匹配：子串匹配挡不住把标签写成 pr-pulled，也挡不住
# 漏掉 pr edit 的 --repo（因为 pr list 那行本来就带着一个正确的 --repo）。
assert_eq "$(grep '^GH pr edit' "$GH_STUB_LOG")" \
          "GH pr edit 42 --repo moonfruit/homebrew-tap --add-label pr-pull" \
          "打标签的调用与预期逐字相符"
assert_contains "$(cat "$GITHUB_OUTPUT")" \
          "tap_pr=https://github.com/moonfruit/homebrew-tap/pull/42" "输出 tap PR 链接"

rm -f "$BREW_STUB_LOG" "$GH_STUB_LOG" "$GITHUB_OUTPUT"

# CI 未通过时绝不能打标签 —— 抢跑会让 pr-pull 拿不到 bottle
: > "$GH_STUB_LOG"
export GH_STUB_CHECKS=fail
assert_fail "tap CI 失败时不打标签" \
  bash -c ". '$HERE/../scripts/tap-bump.sh' && TAP_CHECK_INTERVAL=0 TAP_CHECK_TRIES=2 tap_bump v1.0-reF1nd-moonfruit"
assert_eq "$(grep -c 'pr edit' "$GH_STUB_LOG" || true)" 0 "失败路径下未发出打标签调用"
unset GH_STUB_CHECKS
