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

# 日志必须落在工作树之外：resolve_conflicts 用 git add -A 收拢模型的改动，
# 工作树内的日志会被一并提交进 patch，随发布源码永久留存并逐次增长。
# .git/ 目录天然不在 add 的范围内。
RESOLVE_LOG=${RESOLVE_LOG:-$(git rev-parse --git-dir 2>/dev/null || echo .)/claude-resolution.md}

# build_prompt <cur_base> <new_base>
build_prompt() {
  local cur=$1 new=$2 conflicts patch_files msg
  conflicts=$(git diff --name-only --diff-filter=U)
  # 冲突现场里 HEAD 已经站在新基点上（rebase --onto 先把 HEAD 移到那，再逐个
  # 重放 patch 提交）。$cur..HEAD 因此是「上游改了什么」，不是「patch 碰了什么」。
  # patch 自己的提交区间是 $cur..ORIG_HEAD —— ORIG_HEAD 是 rebase 开始前
  # 分支原本指向的提交，即 patch 栈变基前的旧 tip。
  patch_files=$(git log --name-only --format= "$cur..$(git rev-parse ORIG_HEAD)" 2>/dev/null \
                | sort -u || true)
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
# 调用方（review-pr.sh 的 pr_body）保证 prev_target 非空；该基点尚无上一版时
# 它根本不会调用本函数。
newly_touched() {
  local new_base=$1 prev_target=$2 cur_base=$3
  comm -13 \
    <(git diff --name-only "$cur_base..$prev_target" | sort) \
    <(git diff --name-only "$new_base..HEAD"        | sort)
}

# resolve_conflicts <cur_base> <new_base>
resolve_conflicts() {
  local cur=$1 new=$2 guard=0 orig

  # 守卫：workflow 按 steps.rebase.outcome == 'failure' 分派到这里，但 rebase.sh
  # 也会因为非冲突原因（git describe 找不到 tag、git checkout 失败等）在 set -e
  # 下以 exit 1 收场，此时 outcome 同样是 failure，而 rebase-merge 根本不存在。
  # 少了这道守卫，下面的 while 循环一轮不跑，三道闸门在一棵完全没 rebase 过的树上
  # 通过，把未变基的旧分支当成「解决成功」的结果继续往下推。
  [[ -d "$(git rev-parse --git-path rebase-merge)" ]] || die "没有进行中的 rebase，拒绝继续"

  # 立刻把 ORIG_HEAD 存成字面 SHA，而不是在闸门失败时才去读这个引用。
  # ORIG_HEAD 是全局状态，claude 在 --permission-mode auto 下执行任何一次
  # git reset（哪怕只是想撤销自己刚刚的暂存、完全合法的操作）都会顺手把它
  # 重写成当时的 HEAD——而循环期间 HEAD 站在新基点上，那不是我们想回退到的
  # 提交。用一份在循环开始前就固定下来的 SHA，不管期间发生什么都不受影响。
  orig=$(git rev-parse ORIG_HEAD)

  while [[ -d "$(git rev-parse --git-path rebase-merge)" ]]; do
    (( ++guard <= 50 )) || { git rebase --abort; die "冲突轮次超过 50，放弃"; }

    # prompt 走 stdin：--allowedTools 一类的变长参数会吞掉后面的位置参数，
    # 从管道喂入可以完全绕开这个坑。
    if ! build_prompt "$cur" "$new" \
         | claude -p --permission-mode auto >> "$RESOLVE_LOG"; then
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
    # 回退到循环开始前固定下来的字面 SHA（$orig），不再现读 ORIG_HEAD ——
    # 那个引用可能已经被 claude 期间跑的 git reset 覆写。
    log "闸门未通过，回退到 ${orig}"
    git reset --hard "$orig"
    return 1
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resolve_conflicts "$@"
fi
