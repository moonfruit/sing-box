#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
. "$HERE/fixture.sh"
PATH="$HERE/stubs:$PATH"

# 三道闸门中的 build/test 在夹具仓库里没有 Go 代码，用 SKIP_GO_GATES 关掉，
# 单独验证「标记闸门」与「rebase 收尾」逻辑。
export SKIP_GO_GATES=1

start_conflict() {   # start_conflict <dir> —— 制造并停在冲突现场
  make_fixture "$1" conflict
  ( cd "$1" && bash "$HERE/../scripts/rebase.sh" v1.1-reF1nd moonfruit ) || true
}

# claude 解决成功 → 退出 0，rebase 收尾，无标记残留
d=$(mktemp -d); start_conflict "$d"
assert_ok "解决成功" bash -c \
  "cd '$d' && CLAUDE_STUB_MODE=resolve SKIP_GO_GATES=1 bash '$HERE/../scripts/resolve.sh' v1.0-reF1nd v1.1-reF1nd"
assert_eq "$(git -C "$d" describe --tags --match '*-reF1nd*' --exclude '*-moonfruit*' --abbrev=0 moonfruit)" \
          v1.1-reF1nd "解决后落在新基点上"
assert_eq "$(sed -n 2p "$d/app.go")" resolved "解决结果写入文件"
# git add -A 会收拢工作树里的一切；诊断日志绝不能混进 patch 提交
assert_eq "$(git -C "$d" show --pretty= --name-only HEAD | grep -c 'claude-resolution' || true)" \
          0 "诊断日志未被提交进 patch"
rm -rf "$d"

# claude 留下标记 → 闸门①拦截，退出非 0，rebase 已 abort
d=$(mktemp -d); start_conflict "$d"
assert_fail "标记残留被拦截" bash -c \
  "cd '$d' && CLAUDE_STUB_MODE=leave SKIP_GO_GATES=1 bash '$HERE/../scripts/resolve.sh' v1.0-reF1nd v1.1-reF1nd"
assert_fail "rebase 现场已清理" test -d "$d/$(git -C "$d" rev-parse --git-path rebase-merge)"
assert_eq "$(git -C "$d" describe --tags --match '*-reF1nd*' --exclude '*-moonfruit*' --abbrev=0 moonfruit)" \
          v1.0-reF1nd "abort 后基点回到原处"
rm -rf "$d"

# claude 调用失败 → 退出非 0，rebase 已 abort
d=$(mktemp -d); start_conflict "$d"
assert_fail "claude 失败被处理" bash -c \
  "cd '$d' && CLAUDE_STUB_MODE=fail SKIP_GO_GATES=1 bash '$HERE/../scripts/resolve.sh' v1.0-reF1nd v1.1-reF1nd"
assert_fail "rebase 现场已清理" test -d "$d/$(git -C "$d" rev-parse --git-path rebase-merge)"
rm -rf "$d"

# C2：没有进行中的 rebase 时调用 resolve_conflicts 必须拒绝，而不是把一棵完全
# 没变基过的树当成「解决成功」的结果往下推。workflow 按 steps.rebase.outcome
# == 'failure' 分派到这里，但 rebase.sh 也会因非冲突原因（找不到 tag、checkout
# 失败等）同样以 failure 收场——那种情况下根本没有 rebase-merge 目录。
d=$(mktemp -d); make_fixture "$d" clean   # 干净仓库，从未进入过 rebase
assert_fail "无 rebase 进行时 resolve_conflicts 拒绝执行" bash -c \
  "cd '$d' && SKIP_GO_GATES=1 bash '$HERE/../scripts/resolve.sh' v1.0-reF1nd v1.1-reF1nd"
rm -rf "$d"

# Important-5：闸门失败时的回退不能依赖 ORIG_HEAD——它是全局状态，claude 在
# auto 模式下执行任何一次 git reset 都会把它重写成 mid-rebase 时的 HEAD（新
# 基点）。用 leave-corrupt 模式模拟这个覆写，验证回退落到的仍是 rebase 前的
# 真实 patch 提交，而不是被覆写后指向的新基点。
d=$(mktemp -d); start_conflict "$d"
orig_before=$(git -C "$d" rev-parse ORIG_HEAD)
assert_fail "ORIG_HEAD 被模型覆写后，闸门仍然拦截（标记残留）" bash -c \
  "cd '$d' && CLAUDE_STUB_MODE=leave-corrupt SKIP_GO_GATES=1 bash '$HERE/../scripts/resolve.sh' v1.0-reF1nd v1.1-reF1nd"
assert_eq "$(git -C "$d" rev-parse moonfruit)" "$orig_before" \
  "回退到的是 rebase 前的真实 patch 提交，而不是被覆写后的 ORIG_HEAD（新基点）"
rm -rf "$d"

# Important-4：build_prompt 里「patch 原本触及的文件」必须来自 $cur..ORIG_HEAD
# （patch 自己的提交区间），而不是冲突现场里的 $cur..HEAD —— mid-rebase 时 HEAD
# 已经站在新基点上，那个区间是「上游改了什么」。用一个专门的夹具把两种算法的
# 结果照出差异：upstream 在冲突文件之外，还顺手改了一个 patch 从没碰过的文件。
d=$(mktemp -d)
git init -q -b main "$d"
git -C "$d" config user.email t@example.com
git -C "$d" config user.name  Tester
printf 'line1\nline2\n' > "$d/app.go"
printf 'other\n'        > "$d/other.go"
printf 'third\n'        > "$d/third.go"
git -C "$d" add . && git -C "$d" commit -qm 'upstream base' && git -C "$d" tag v1.0-reF1nd

git -C "$d" checkout -q -b moonfruit
printf 'line1\npatched\n' > "$d/app.go"
git -C "$d" commit -qam 'personal patch'

git -C "$d" checkout -q main
printf 'line1\nupstream-changed\n' > "$d/app.go"     # 与 patch 冲突
printf 'third-changed\n'           > "$d/third.go"   # patch 从没碰过的文件
git -C "$d" commit -qam 'upstream moves on, touches an unrelated file too'
git -C "$d" tag v1.1-reF1nd
git -C "$d" checkout -q moonfruit

( cd "$d" && bash "$HERE/../scripts/rebase.sh" v1.1-reF1nd moonfruit ) || true
# 取标题行到下一个空行之间的全部内容（文件数不固定，不能只取「下一行」）。
# 用 awk 而非 sed 的 `{n;p}` 花括号语法：BSD/GNU sed 对该语法的换行/分号
# 要求不一致，awk 在两边都能跑。
patch_files=$(cd "$d" && . "$HERE/../scripts/resolve.sh" \
              && build_prompt v1.0-reF1nd v1.1-reF1nd \
              | awk '/^该 patch 原本触及的文件：$/{f=1;next} f && NF==0{exit} f{print}')
assert_eq "$patch_files" app.go \
  "patch 原本触及的文件来自 \$cur..ORIG_HEAD（patch 自己的提交），不含 upstream 顺手改的 third.go"
git -C "$d" rebase --abort 2>/dev/null || true
rm -rf "$d"
