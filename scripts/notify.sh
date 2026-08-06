#!/usr/bin/env bash
# Bark 推送与 GitHub issue。Bark 是主渠道，所有事件都发；
# issue 只在没有审查 PR 可指的时候才开（见 spec §7）。
set -euo pipefail

NOTIFY_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$NOTIFY_DIR/lib.sh"

# bark <title> <body> <url>
bark() {
  if [[ -z "${BARK_URL:-}" ]]; then
    log "BARK_URL 未配置，跳过推送"
    return 0
  fi
  jq -cn --arg t "$1" --arg b "$2" --arg u "$3" \
     '{title:$t, body:$b, url:$u, group:"sing-box"}' \
  | curl -fsS -X POST -H 'Content-Type: application/json' --data @- "$BARK_URL" >/dev/null
}

# open_or_comment_issue <target-tag> <body-file>
open_or_comment_issue() {
  local tag=$1 body=$2 num
  num=$(gh issue list --label release-conflict --state open \
          --search "$tag in:title" --json number --jq '.[0].number // empty')
  if [[ -n "$num" ]]; then
    gh issue comment "$num" --body-file "$body"
  else
    gh issue create --label release-conflict \
      --title "发布受阻：${tag}" --body-file "$body"
  fi
}
