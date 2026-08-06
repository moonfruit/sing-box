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

out=$(tap_bump v1.14.0-beta.5-reF1nd-moonfruit)
logged=$(cat "$BREW_STUB_LOG")
gh_logged=$(cat "$GH_STUB_LOG")

assert_contains "$logged" "bump-formula-pr"                             "调用 bump-formula-pr"
assert_contains "$logged" "--version=1.14.0-beta.5-reF1nd-moonfruit"    "版本号去掉了前导 v"
assert_contains "$logged" "moonfruit/tap/sing-box-ref1nd"               "目标 formula 正确"
assert_contains "$logged" "--no-browse"                                 "不打开浏览器"

# 打标签这一步是 tap 构建 bottle 的触发器，必须逐项守住
assert_contains "$gh_logged" "pr edit 42"                    "对检索到的 PR 号打标签"
assert_contains "$gh_logged" "--add-label pr-pull"           "标签正是 pr-pull"
assert_contains "$gh_logged" "--repo moonfruit/homebrew-tap" "作用在 tap 仓库上"
assert_contains "$out" "tap_pr=https://github.com/moonfruit/homebrew-tap/pull/42" \
                                                             "输出 tap PR 链接"

rm -f "$BREW_STUB_LOG" "$GH_STUB_LOG"
