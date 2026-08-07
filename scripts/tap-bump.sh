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

TAP_CHECK_TRIES=${TAP_CHECK_TRIES:-80}     # 每次 30 秒，约 40 分钟上限
TAP_CHECK_INTERVAL=${TAP_CHECK_INTERVAL:-30}

# wait_for_checks <pr-number> —— 等 tap 的 test-bot 全部通过。
# 只看 test-bot：pr-pull 自己也是一项检查，等它就成了死锁。
wait_for_checks() {
  local num=$1 i state
  for ((i = 0; i < TAP_CHECK_TRIES; i++)); do
    state=$(GH_TOKEN="${HOMEBREW_GITHUB_API_TOKEN:?}" \
            gh pr checks "$num" --repo "$TAP_REPO" --json bucket,name \
              --jq '[.[] | select(.name | startswith("test-bot")) | .bucket]
                    | if length == 0 then "pending"
                      elif any(. == "fail" or . == "cancel") then "fail"
                      elif all(. == "pass" or . == "skipping") then "pass"
                      else "pending" end' 2>/dev/null) || state=pending
    case "$state" in
      pass) log "tap CI 已通过"; return 0 ;;
      fail) log "tap CI 失败"; return 1 ;;
    esac
    sleep "$TAP_CHECK_INTERVAL"
  done
  log "等待 tap CI 超时"
  return 1
}

# tap_bump <target-tag>
tap_bump() {
  local target=$1 version=${1#v} out num

  # brew 会把它开出的 PR 链接打在输出里，直接取那个号。
  # 不要改用 gh pr list --search：GitHub 的搜索索引是最终一致的，PR 刚建出来
  # 几秒内搜不到；而且搜索按标点分词，这个版本串标点极多，in:title 未必字面匹配。
  # 经 tee 边流边存：直接 out=$(...) 的话，brew 一失败 set -e 就在赋值处退出，
  # 后面的 printf 永远执行不到，它的诊断信息随之石沉大海（这正好坑过一次）。
  out=$(brew bump-formula-pr --version="$version" --no-audit --no-browse "$TAP_FORMULA" 2>&1 | tee /dev/stderr)

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

  # 必须等 test-bot 构建完 bottle 再打标签：pr-pull 由打标签触发，而它要下载
  # test-bot 的产物，抢跑会直接报 "The newest workflow run is still in progress"。
  # 人工流程里也是看到 CI 通过才打标签的。
  wait_for_checks "$num" || die "tap CI 未通过，未打标签；PR: https://github.com/${TAP_REPO}/pull/${num}"

  GH_TOKEN="${HOMEBREW_GITHUB_API_TOKEN}" \
    gh pr edit "$num" --repo "$TAP_REPO" --add-label pr-pull

  log "已开 tap PR #${num} 并打上 pr-pull，目标 ${target}"
  emit tap_pr "https://github.com/${TAP_REPO}/pull/${num}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then tap_bump "$@"; fi
