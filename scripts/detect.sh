#!/usr/bin/env bash
# 确定 reF1nd 基点、目标 moonfruit tag，以及本次是否需要构建。
# 被 source 时只提供函数；被直接执行时读环境变量并 emit step output。
set -euo pipefail

DETECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$DETECT_DIR/lib.sh"
# shellcheck source=scripts/version.sh
. "$DETECT_DIR/version.sh"
# current_base 归 rebase.sh 所有。基点解析出错会静默丢弃全部 patch 且三道闸门
# 都放行，这种逻辑只能有一份实现、由一处回归测试守着。
# shellcheck source=scripts/rebase.sh
. "$DETECT_DIR/rebase.sh"

UPSTREAM_REPO=${UPSTREAM_REPO:-reF1nd/sing-box}
INTEGRATION_BRANCH=${INTEGRATION_BRANCH:-moonfruit}

# latest_upstream_tag —— reF1nd 最新发布的 tag。
# 以 Release 的发布顺序为准（最忠实于实际发布），无 Release 时回退 tag 列表按版本排序。
# 回退路径用正则而非 endswith，否则会漏掉 -reF1nd.1 这类修订 tag。
latest_upstream_tag() {
  local tag
  tag=$(gh api "repos/${UPSTREAM_REPO}/releases?per_page=1" --jq '.[0].tag_name' 2>/dev/null) || tag=
  if [[ -z "$tag" || "$tag" == "null" ]]; then
    tag=$(gh api "repos/${UPSTREAM_REPO}/tags?per_page=100" --paginate \
            --jq '.[].name | select(test("-reF1nd(\\.[0-9]+)?$"))' \
          | sort -V -r | head -n1)
  fi
  [[ -n "$tag" ]] || die "未能确定 ${UPSTREAM_REPO} 的最新 tag"
  printf '%s\n' "$tag"
}

# decide_build <base> <cur_base> <branch_sha> <latest_target_sha> <force>
decide_build() {
  local base=$1 cur_base=$2 branch_sha=$3 target_sha=$4 force=$5
  if [[ "$force" == true ]]; then printf 'true\n'; return; fi
  if [[ "$base" != "$cur_base" ]]; then printf 'true\n'; return; fi   # 上游出新版
  if [[ -z "$target_sha" ]]; then printf 'true\n'; return; fi          # 该基点尚未发布过
  if [[ "$branch_sha" != "$target_sha" ]]; then printf 'true\n'; return; fi  # patch 栈变了
  printf 'false\n'
}

main() {
  local base=${BASE_TAG:-}
  [[ -n "$base" ]] || base=$(latest_upstream_tag)

  local existing; mapfile -t existing < <(git tag --list '*-moonfruit' '*-moonfruit.*')
  local cur_base; cur_base=$(current_base "$INTEGRATION_BRANCH")
  local branch_sha; branch_sha=$(git rev-parse "$INTEGRATION_BRANCH")

  local prev; prev=$(latest_target "$base" "${existing[@]}")
  local prev_sha=; [[ -n "$prev" ]] && prev_sha=$(git rev-parse "${prev}^{commit}")

  local should; should=$(decide_build "$base" "$cur_base" "$branch_sha" "$prev_sha" "${FORCE:-false}")
  local target; target=$(next_target "$base" "${existing[@]}")

  log "基点 ${cur_base} → ${base}；目标 ${target}；构建 ${should}"
  emit should_build "$should"
  emit base         "$base"
  emit cur_base     "$cur_base"
  emit target       "$target"
  emit prev_target  "$prev"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
