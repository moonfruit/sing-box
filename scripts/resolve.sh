#!/usr/bin/env bash
# 在真实的 rebase 冲突现场调用 claude，然后跑三道闸门。
# 不预先把上下文切片喂给模型：冲突未必是「同一处代码被改动」，也可能是
# 「上游变更了别处的 API，patch 必须跟着适配另一个文件」，后者只能靠探索发现。
set -euo pipefail

RESOLVE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$RESOLVE_DIR/lib.sh"
# shellcheck source=scripts/rebase.sh
. "$RESOLVE_DIR/rebase.sh"

RESOLVE_LOG=${RESOLVE_LOG:-claude-resolution.md}

# build_prompt <cur_base> <new_base>
build_prompt() {
  local cur=$1 new=$2 conflicts patch_files msg
  conflicts=$(git diff --name-only --diff-filter=U)
  patch_files=$(git diff --name-only "$cur..$(git rev-parse HEAD)" 2>/dev/null || true)
  msg=$(git log -1 --format=%B REBASE_HEAD 2>/dev/null || printf '(无法读取)')

  cat <<PROMPT
你正处在一次 git rebase 的冲突现场：仓库中的个人 patch 正在从基点 ${cur}
搬到 ${new}。请解决冲突，使 patch 的原始意图在新基点上继续成立。

正在被应用的 patch，其提交说明如下（它解释了每处改动的原因，是关键上下文）：

${msg}

冲突文件：
${conflicts}

该 patch 原本触及的文件：
${patch_files}

请按以下顺序工作：

1. 先判定冲突成因属于哪一类：
   (a) 上游改动与 patch 落在同一处代码；
   (b) 上游变更了别处的 API/签名，patch 必须跟着适配。
   用 \`git log -p ${cur}..${new}\` 查阅区间内的上游改动来判断。
2. 若属于 (b)，必须检查该 patch 触及的所有文件以及相关调用点，
   不要只改冲突文件。
3. 解决冲突，删除全部冲突标记。
4. 自行运行 \`go build -tags "\$(cat release/DEFAULT_BUILD_TAGS)" ./cmd/sing-box\`
   与 \`go test ./...\` 验证，直到通过。
5. 最后用中文简述你的判断与改动理由。不要执行任何 git commit 或 git rebase 命令。
PROMPT
}

gate_markers() {
  log "闸门①：冲突标记扫描"
  # assert_no_markers 命中标记时会调用 die（内部直接 exit），
  # 必须包一层子 shell，否则会连带炸穿本脚本，
  # 让 resolve_conflicts 里紧随其后的 ORIG_HEAD 回退永远执行不到。
  ( assert_no_markers )
}

gate_build() {
  [[ -z "${SKIP_GO_GATES:-}" ]] || { log "闸门②：已跳过"; return 0; }
  log "闸门②：go build"
  go build -tags "$(cat release/DEFAULT_BUILD_TAGS)" ./cmd/sing-box
}

gate_test() {
  [[ -z "${SKIP_GO_GATES:-}" ]] || { log "闸门③：已跳过"; return 0; }
  log "闸门③：go test（根模块，不含需要 Docker 的 test/ 子模块）"
  go test ./...
}

# newly_touched <new_base> <prev_target> <cur_base>
# 相对上一版 patch 新触及的文件。仅作报告，不作闸门 —— 硬性限制文件集会误杀
# 「上游 API 变更导致 patch 必须适配新文件」这类合法解法。
newly_touched() {
  local new_base=$1 prev_target=$2 cur_base=$3
  comm -13 \
    <(git diff --name-only "$cur_base..$prev_target" | sort) \
    <(git diff --name-only "$new_base..HEAD"        | sort)
}

# resolve_conflicts <cur_base> <new_base>
resolve_conflicts() {
  local cur=$1 new=$2 guard=0
  while [[ -d "$(git rev-parse --git-path rebase-merge)" ]]; do
    (( ++guard <= 50 )) || { git rebase --abort; die "冲突轮次超过 50，放弃"; }

    if ! build_prompt "$cur" "$new" \
         | claude -p --dangerously-skip-permissions >> "$RESOLVE_LOG"; then
      git rebase --abort
      log "claude 调用失败"
      return 1
    fi

    git add -A
    if ! GIT_EDITOR=true git rebase --continue; then
      git rebase --abort
      log "rebase --continue 失败"
      return 1
    fi
  done

  if ! gate_markers || ! gate_build || ! gate_test; then
    # 闸门跑在 rebase 收尾之后，此时已不在 rebase 现场，abort 无从谈起。
    # git rebase 在开始前会写 ORIG_HEAD，直接回到那里即可。
    log "闸门未通过，回退到 ORIG_HEAD"
    git reset --hard ORIG_HEAD
    return 1
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resolve_conflicts "$@"
fi
