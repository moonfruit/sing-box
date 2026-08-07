#!/usr/bin/env bash
# 更新 moonfruit/homebrew-tap 的 sing-box-ref1nd。
# 只传 --version 就够：brew 用新版本串替换 formula 中 url 里的旧版本串，
# 再自行下载计算 sha256。前提是 url 内含完整版本串，本方案的
# .../tags/v${version}.tar.gz 满足。
set -euo pipefail

TAP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$TAP_DIR/lib.sh"

TAP_FORMULA=${TAP_FORMULA:-moonfruit/tap/sing-box-ref1nd}
TAP_REPO=${TAP_REPO:-moonfruit/homebrew-tap}

# tap_bump <target-tag>
tap_bump() {
  local target=$1 version=${1#v} out num

  # brew 会把它开出的 PR 链接打在输出里，直接取那个号。
  # 不要改用 gh pr list --search：GitHub 的搜索索引是最终一致的，PR 刚建出来
  # 几秒内搜不到；而且搜索按标点分词，这个版本串标点极多，in:title 未必字面匹配。
  out=$(brew bump-formula-pr --version="$version" --no-audit --no-browse "$TAP_FORMULA" 2>&1)
  printf '%s\n' "$out"

  num=$(printf '%s\n' "$out" | sed -n 's|.*/pull/\([0-9][0-9]*\).*|\1|p' | tail -n1)

  # 兜底：按标题在列表接口里精确匹配（列表是强一致的，不走搜索索引）。
  # gh 的 --jq 不支持 --arg，所以取出 TSV 后在 bash 里做字面比较。
  if [[ -z "$num" ]]; then
    log "未能从 brew 输出中解析 PR 号，改用列表接口按标题匹配"
    local want="sing-box-ref1nd ${version}"
    num=$(GH_TOKEN="${HOMEBREW_GITHUB_API_TOKEN:?}" \
          gh pr list --repo "$TAP_REPO" --state open --limit 100 \
            --json number,title --jq '.[] | "\(.number)\t\(.title)"' \
          | while IFS=$'\t' read -r n t; do
              if [[ "$t" == "$want" ]]; then printf '%s\n' "$n"; break; fi
            done)
  fi
  [[ -n "$num" ]] || die "未能确定 ${TAP_REPO} 中版本 ${version} 对应的 PR"

  GH_TOKEN="${HOMEBREW_GITHUB_API_TOKEN}" \
    gh pr edit "$num" --repo "$TAP_REPO" --add-label pr-pull

  log "已开 tap PR #${num} 并打上 pr-pull，目标 ${target}"
  emit tap_pr "https://github.com/${TAP_REPO}/pull/${num}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then tap_bump "$@"; fi
