#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
. "$HERE/../scripts/lib.sh"
. "$HERE/../scripts/notify.sh"

PATH="$HERE/stubs:$PATH"
CURL_STUB_LOG=$(mktemp); export CURL_STUB_LOG

# 未配置 BARK_URL 时静默跳过
unset BARK_URL
assert_ok "无 BARK_URL 时不报错" bark "标题" "正文" "https://example.com"
assert_eq "$(wc -c < "$CURL_STUB_LOG" | tr -d ' ')" 0 "无 BARK_URL 时不发请求"

# 配置后发出 JSON
export BARK_URL=https://api.day.app/testkey
bark "新版本" "v1.0-reF1nd-moonfruit 已打 tag" "https://example.com/r"
logged=$(cat "$CURL_STUB_LOG")
assert_contains "$logged" "https://api.day.app/testkey" "请求打到 BARK_URL"
assert_contains "$logged" '"title":"新版本"'            "JSON 含 title"
assert_contains "$logged" '"group":"sing-box"'          "JSON 含 group"
assert_contains "$logged" '"url":"https://example.com/r"' "JSON 含 url"
rm -f "$CURL_STUB_LOG"
