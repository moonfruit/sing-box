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

# 端点不可达时也必须返回 0 —— 否则调用方的 set -e 会中止整条发布流水线
export BARK_FAIL=1
assert_ok "推送失败不向上传播" bark "标题" "正文" "https://example.com"
unset BARK_FAIL
rm -f "$CURL_STUB_LOG"
unset BARK_URL

# open_or_comment_issue：无既有 issue 时新建
GH_STUB_LOG=$(mktemp); export GH_STUB_LOG
body=$(mktemp); printf '冲突详情\n' > "$body"
open_or_comment_issue v1.0-reF1nd-moonfruit "$body"
logged=$(cat "$GH_STUB_LOG")
assert_contains "$logged" "issue list"        "先检索既有 issue"
assert_contains "$logged" "issue create"      "无既有 issue 时新建"
assert_contains "$logged" "release-conflict"  "带 release-conflict 标签"
# Important-1：不再依赖最终一致、按标点分词的 --search 索引，改用强一致的
# 列表接口 + bash 里的字面比较（同 tap-bump.sh 的做法）
assert_eq "$(grep -c -- '--search' "$GH_STUB_LOG" || true)" 0 \
  "不再使用最终一致的 --search 索引"

# 已有 issue 时只追加评论，不重复新建
: > "$GH_STUB_LOG"
export GH_STUB_MODE=issue-exists
open_or_comment_issue v1.0-reF1nd-moonfruit "$body"
assert_contains "$(cat "$GH_STUB_LOG")" "issue comment 7" "已有 issue 时追加评论"
assert_eq "$(grep -c 'issue create' "$GH_STUB_LOG" || true)" 0 "已有 issue 时不重复新建"

unset GH_STUB_MODE
rm -f "$GH_STUB_LOG" "$body"
