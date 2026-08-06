#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
. "$HERE/../scripts/lib.sh"
. "$HERE/../scripts/tap-bump.sh"

PATH="$HERE/stubs:$PATH"
BREW_STUB_LOG=$(mktemp); export BREW_STUB_LOG

tap_bump v1.14.0-beta.5-reF1nd-moonfruit >/dev/null
logged=$(cat "$BREW_STUB_LOG")

assert_contains "$logged" "bump-formula-pr"                             "调用 bump-formula-pr"
assert_contains "$logged" "--version=1.14.0-beta.5-reF1nd-moonfruit"    "版本号去掉了前导 v"
assert_contains "$logged" "moonfruit/tap/sing-box-ref1nd"               "目标 formula 正确"
assert_contains "$logged" "--no-browse"                                 "不打开浏览器"
rm -f "$BREW_STUB_LOG"
