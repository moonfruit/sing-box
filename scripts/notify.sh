#!/usr/bin/env bash
# Bark 推送与 GitHub issue。Bark 是主渠道，所有事件都发；
# issue 只在没有审查 PR 可指的时候才开（见 spec §7）。
set -euo pipefail

NOTIFY_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$NOTIFY_DIR/lib.sh"

# bark <title> <body> <url>
# 无论未配置端点还是推送失败，都只记录不向调用方传播 —— 通知永远不该成为
# 发布失败的原因。调用方普遍开着 set -e，一个非零返回会直接中止整条流水线。
bark() {
  if [[ -z "${BARK_URL:-}" ]]; then
    log "BARK_URL 未配置，跳过推送"
    return 0
  fi
  if ! jq -cn --arg t "$1" --arg b "$2" --arg u "$3" \
       '{title:$t, body:$b, url:$u, group:"sing-box"}' \
     | curl -fsS -X POST -H 'Content-Type: application/json' --data @- "$BARK_URL" >/dev/null
  then
    log "Bark 推送失败，已忽略"
  fi
  return 0
}

# open_or_comment_issue <target-tag> <body-file>
#
# 不用 gh issue list --search：GitHub 的搜索索引是最终一致的，issue 刚开出来
# 几秒内搜不到；而且搜索按标点分词，目标 tag 这种标点极多的版本串 in:title
# 未必字面匹配。tap-bump 早年在等待 tap PR 时就在生产上踩过同一个坑（见
# scripts/tap-bump.sh 的注释）。改用列表接口（强一致）取回后在 bash 里逐条
# 字面比较标题。
open_or_comment_issue() {
  local tag=$1 body=$2 num
  local title="发布受阻：${tag}"
  num=$(gh issue list --label release-conflict --state open --limit 100 \
          --json number,title --jq '.[] | "\(.number)\t\(.title)"' \
        | while IFS=$'\t' read -r n t; do
            if [[ "$t" == "$title" ]]; then printf '%s\n' "$n"; break; fi
          done)
  if [[ -n "$num" ]]; then
    gh issue comment "$num" --body-file "$body"
  else
    gh issue create --label release-conflict --title "$title" --body-file "$body"
  fi
}
