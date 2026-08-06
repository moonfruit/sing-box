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
  local target=$1 version=${1#v} num

  brew bump-formula-pr --version="$version" --no-audit --no-browse "$TAP_FORMULA"

  num=$(GH_TOKEN="${HOMEBREW_GITHUB_API_TOKEN:?}" \
        gh pr list --repo "$TAP_REPO" --state open \
          --search "$version in:title" --json number --jq '.[0].number // empty')
  [[ -n "$num" ]] || die "未找到 ${TAP_REPO} 中版本 ${version} 的 PR"

  GH_TOKEN="${HOMEBREW_GITHUB_API_TOKEN}" \
    gh pr edit "$num" --repo "$TAP_REPO" --add-label pr-pull

  log "已开 tap PR #${num} 并打上 pr-pull，目标 ${target}"
  emit tap_pr "https://github.com/${TAP_REPO}/pull/${num}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then tap_bump "$@"; fi
