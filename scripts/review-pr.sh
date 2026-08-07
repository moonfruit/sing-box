#!/usr/bin/env bash
# 把 claude 的解决结果做成一个可审查的 PR。
#
# base 分支只是指向 reF1nd tag commit 的一条光秃秃的分支 —— 存在的唯一理由是
# PR 的 base 必须是分支而不能是 tag。因为 GitHub 的 Files changed 用三点 diff
# （merge-base 即该 tag），PR 的 diff 恰好等于 patch 栈本身。
set -euo pipefail

PR_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$PR_DIR/lib.sh"
# shellcheck source=scripts/version.sh
. "$PR_DIR/version.sh"
# shellcheck source=scripts/resolve.sh
. "$PR_DIR/resolve.sh"

# resolved_prev_target <cur_base> —— 该基点下已发布的最新 moonfruit tag，range-diff 的比较基准。
#
# 不能用 detect.sh 传来的 prev_target：那是相对*新*基点算的（latest_target "$base" ...），
# 而冲突只在基点变更时发生 —— 新基点上此刻必然还没有任何 moonfruit tag，这个值恒为空，
# 导致 review PR 里的 range-diff 与「新触及文件」两段永远是空的。detect 的 prev_target
# 仍然是对的，只是那是给 decide_build 用的，跟这里要比较的对象根本不是同一个东西。
#
# 正确的比较基准是旧基点（$cur_base）下的上一个发布 tag，从实际存在的 git tag 反查。
resolved_prev_target() {
  local cur=$1
  local existing; mapfile -t existing < <(git tag --list '*-moonfruit' '*-moonfruit.*')
  latest_target "$cur" "${existing[@]}"
}

# pr_body <cur_base> <new_base> <prev_target> <target> <resolution-log>
pr_body() {
  local cur=$1 new=$2 prev=$3 target=$4 logfile=$5
  local rangediff newfiles
  [[ -s "$logfile" ]] || die "解决日志为空，拒绝生成审查 PR 正文：${logfile}"
  if [[ -n "$prev" ]]; then
    rangediff=$(git range-diff "$cur..$prev" "$new..HEAD" 2>&1 || true)
    newfiles=$(newly_touched "$new" "$prev" "$cur" || true)
  else
    rangediff='（该基点下没有上一版 patch，无从比较）'
    newfiles=
  fi

  cat <<BODY
自动解决 rebase 冲突的结果，等待审查。

**基点变更：** \`${cur}\` → \`${new}\`
**目标 tag：** \`${target}\`

### 本次解决相对上一版新触及的文件

${newfiles:-（无）}

### claude 的解决说明

$(cat "$logfile")

### range-diff（patch 相对上一版的变化）

\`\`\`
${rangediff}
\`\`\`

---

**放行：** 在本 PR 内评论 \`/ship\`。CI 会把 \`moonfruit\` 指向本 PR 的 head、
打 tag \`${target}\`、走完构建发布，并清理临时分支。

**不满意就别评论。** 本地自行解决：

\`\`\`bash
git fetch origin --tags && git fetch ref1nd --tags
git rebase --onto ${new} ${cur} moonfruit
git push -f origin moonfruit
\`\`\`

解决后手动 dispatch \`release.yml\` 即可 —— detect 会发现基点已匹配，跳过 rebase。
BODY
}

# create_review_pr <new_base> <target>；其余上下文由环境变量传入
create_review_pr() {
  local new=$1 target=$2
  local base_branch="base/${target}" auto_branch="auto/resolve-${target}"

  git push -f origin "${new}^{commit}:refs/heads/${base_branch}"
  git push -f origin "HEAD:refs/heads/${auto_branch}"

  local prev; prev=$(resolved_prev_target "${CUR_BASE:?}")
  local body; body=$(mktemp)
  # RESOLVE_LOG 的默认值由 resolve.sh 在被 source 时确定（工作树之外），此处直接沿用
  pr_body "${CUR_BASE:?}" "$new" "$prev" "$target" "$RESOLVE_LOG" > "$body"
  gh pr create --base "$base_branch" --head "$auto_branch" \
    --title "自动解决冲突：${target}" --body-file "$body"
  rm -f "$body"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  create_review_pr "$@"
fi
