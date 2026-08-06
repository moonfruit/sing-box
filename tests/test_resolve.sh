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
assert_eq "$(git -C "$d" describe --tags --match '*-reF1nd*' --abbrev=0 moonfruit)" \
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
assert_eq "$(git -C "$d" describe --tags --match '*-reF1nd*' --abbrev=0 moonfruit)" \
          v1.0-reF1nd "abort 后基点回到原处"
rm -rf "$d"

# claude 调用失败 → 退出非 0，rebase 已 abort
d=$(mktemp -d); start_conflict "$d"
assert_fail "claude 失败被处理" bash -c \
  "cd '$d' && CLAUDE_STUB_MODE=fail SKIP_GO_GATES=1 bash '$HERE/../scripts/resolve.sh' v1.0-reF1nd v1.1-reF1nd"
assert_fail "rebase 现场已清理" test -d "$d/$(git -C "$d" rev-parse --git-path rebase-merge)"
rm -rf "$d"
