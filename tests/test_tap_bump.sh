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

tap_bump v1.14.0-beta.5-reF1nd-moonfruit >/dev/null
logged=$(cat "$BREW_STUB_LOG")

assert_contains "$logged" "bump-formula-pr"                             "调用 bump-formula-pr"
assert_contains "$logged" "--version=1.14.0-beta.5-reF1nd-moonfruit"    "版本号去掉了前导 v"
assert_contains "$logged" "moonfruit/tap/sing-box-ref1nd"               "目标 formula 正确"
assert_contains "$logged" "--no-browse"                                 "不打开浏览器"
rm -f "$BREW_STUB_LOG"
