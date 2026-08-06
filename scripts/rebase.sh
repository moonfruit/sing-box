#!/usr/bin/env bash
# 把集成分支上的 patch 栈搬到新的 reF1nd 基点上。
# 冲突时故意 **不 abort**：真实的 rebase 现场（index 中的 stage 1/2/3）是
# scripts/resolve.sh 唯一能用上的东西，abort 掉就只剩冲突标记文本了。
set -euo pipefail

REBASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$REBASE_DIR/lib.sh"

# current_base <branch> —— 从 git 历史反查当前基点，而非从 tag 名推导。
# 这使得 rebase 步骤幂等：人工已在本地 rebase 并推送时，CI 重跑会自动跳过。
#
# --exclude 不可省：moonfruit tag 形如 <基点>-moonfruit[.N]，本身也匹配 *-reF1nd*。
# 少了它，第一个 moonfruit tag 出现后基点会解析成 tag 自己，rebase --onto 的区间
# 变成空区间，patch 被静默全部丢弃 —— 而三道闸门全会放行（无标记、能编译、测试过）。
current_base() {
  git describe --tags --match '*-reF1nd*' --exclude '*-moonfruit*' --abbrev=0 "${1:-moonfruit}"
}

# assert_no_markers —— 打 tag 前的硬性检查。已核对 reF1nd 源码树不含此类行，不会误报。
assert_no_markers() {
  if git grep -n '^<<<<<<< ' -- . ; then
    die "工作树中存在冲突标记，拒绝继续"
  fi
}

# rebase_onto <new-base> <branch> —— 0 成功 / 2 冲突（现场保留）
rebase_onto() {
  local new=$1 branch=${2:-moonfruit} cur
  cur=$(current_base "$branch")
  if [[ "$cur" == "$new" ]]; then
    log "集成分支已在 ${new} 上，跳过 rebase"
    return 0
  fi
  log "rebase ${branch}：${cur} → ${new}"
  git checkout -q "$branch"
  if git rebase --onto "$new" "$cur" "$branch"; then
    return 0
  fi
  log "rebase 冲突，保留现场供自动解决"
  return 2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rebase_onto "$@"
fi
