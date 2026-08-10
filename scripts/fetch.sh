#!/usr/bin/env bash
# 按各自约定的范围更新三个远程：
#   moonfruit —— 全量分支 + tag（我们自己的仓库，什么都要）
#   origin    —— 只要 stable / testing 两条分支 + tag
#   ref1nd    —— 只要 reF1nd-stable / reF1nd-testing 两条分支 + tag
#
# 范围限制真正生效的地方是 .git/config 里的 remote.<name>.fetch refspec，而不是
# 这里的命令行参数 —— 这样手敲 `git fetch --all` 也不会把上游那几十条
# dev-*/dependabot/*/renovate/* 分支重新灌回本地。每次运行都会重新校准一遍
# refspec（ensure_refspec），所以换机器重新 clone 后跑一次就能恢复同样的布局。
#
# 注意 tag 是全局命名空间，三个远程共用。origin 与 ref1nd 目前存在一个同名不同
# 提交的 tag（v1.14.0-beta.3），后跑的一方会被 git 拒绝并打印一行
# "! [rejected] ... (would clobber existing tag)"。这是预期噪音，不是错误：
# 脚本刻意不加 --force，先落地的（origin，见 REMOTES 顺序）说了算。
set -euo pipefail

FETCH_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$FETCH_DIR/lib.sh"

# 更新顺序：上游在前，我们的集成仓库在后。见文件头关于 tag 冲突的说明。
REMOTES=(origin ref1nd moonfruit)

# branches_for <remote> —— 该远程要保留的分支名，单个 `*` 表示全量。
branches_for() {
  case "$1" in
    origin)    printf 'stable testing' ;;
    ref1nd)    printf 'reF1nd-stable reF1nd-testing' ;;
    moonfruit) printf '*' ;;
    *)         die "未知 remote：$1" ;;
  esac
}

# ensure_refspec <remote> —— 把 remote.<name>.fetch 校准成 branches_for 的白名单。
# 已经一致就不动，避免每次运行都改写 .git/config。
ensure_refspec() {
  local remote=$1 b spec want=()
  for b in $(branches_for "$remote"); do
    if [[ $b == '*' ]]; then
      want+=("+refs/heads/*:refs/remotes/$remote/*")
    else
      want+=("+refs/heads/$b:refs/remotes/$remote/$b")
    fi
  done
  if [[ "$(git config --get-all "remote.$remote.fetch" || true)" == "$(printf '%s\n' "${want[@]}")" ]]; then
    return 0
  fi
  log "校准 remote.$remote.fetch"
  git config --unset-all "remote.$remote.fetch" || true
  for spec in "${want[@]}"; do
    git config --add "remote.$remote.fetch" "$spec"
  done
}

# prune_stale_refs <remote> —— 删掉白名单之外的远程跟踪引用。
#
# 不能指望 `git fetch --prune` 干这件事：prune 只清理 refspec 覆盖范围内的 ref，
# 而收窄 refspec 之后，那些历史遗留的 refs/remotes/origin/dev-* 恰恰落在覆盖范围
# 之外，反倒成了 prune 够不着的孤儿。所以按白名单直接删。
prune_stale_refs() {
  local remote=$1 branches keep ref n=0
  branches=$(branches_for "$remote")
  # 全量远程的取舍交给 fetch --prune，它的 refspec 覆盖得到。
  [[ "$branches" == '*' ]] && return 0

  keep=' '
  for ref in $branches; do
    keep+="refs/remotes/$remote/$ref "
  done
  while read -r ref; do
    case "$keep" in *" $ref "*) continue ;; esac
    git update-ref -d "$ref"
    log "  删除 $ref"
    n=$((n + 1))
  done < <(git for-each-ref --format='%(refname)' "refs/remotes/$remote")
  # ${remote} 的花括号不可省：紧跟其后的是全角冒号，bash 5 会把它并进变量名。
  [[ $n -gt 0 ]] && log "  ${remote}：清理了 $n 条白名单外的引用"
  return 0
}

main() {
  local remotes=("$@") remote
  [[ ${#remotes[@]} -eq 0 ]] && remotes=("${REMOTES[@]}")

  # 三个 worktree 共享同一份 refs，所以在脚本自己所在的仓库里执行就够了，
  # 不必关心调用者的当前目录。
  cd "$FETCH_DIR"

  for remote in "${remotes[@]}"; do
    log "==> $remote"
    ensure_refspec "$remote"
    prune_stale_refs "$remote"
    # --tags 拉全部 tag；它与 --prune 组合是安全的 —— 仅因 --tags 而拉取的 tag
    # 不参与 prune（要删本地多余 tag 得显式 --prune-tags，这里刻意不加：那会让
    # 每个远程都拿自己的 tag 集合去裁剪另外两个远程留下的 tag）。
    git fetch --prune --tags "$remote"
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
