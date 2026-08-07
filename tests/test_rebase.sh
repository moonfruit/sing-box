#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
. "$HERE/fixture.sh"
REBASE_SH="$HERE/../scripts/rebase.sh"

run_in() { ( cd "$1" && shift && bash "$REBASE_SH" "$@" ); }

# 干净 rebase
d=$(mktemp -d); make_fixture "$d" clean
assert_eq "$(git -C "$d" describe --tags --match '*-reF1nd*' --exclude '*-moonfruit*' --abbrev=0 moonfruit)" \
          v1.0-reF1nd "current_base：rebase 前"
assert_ok "干净 rebase 成功" run_in "$d" v1.1-reF1nd moonfruit
assert_eq "$(git -C "$d" describe --tags --match '*-reF1nd*' --exclude '*-moonfruit*' --abbrev=0 moonfruit)" \
          v1.1-reF1nd "current_base：rebase 后"
assert_eq "$(git -C "$d" log --oneline -1 --format=%s moonfruit)" \
          'personal patch' "patch 提交保留在顶端"
rm -rf "$d"

# 幂等：已在新基点上则跳过
d=$(mktemp -d); make_fixture "$d" clean
run_in "$d" v1.1-reF1nd moonfruit
before=$(git -C "$d" rev-parse moonfruit)
assert_ok "重复调用幂等" run_in "$d" v1.1-reF1nd moonfruit
assert_eq "$(git -C "$d" rev-parse moonfruit)" "$before" "重复调用不改变 tip"
rm -rf "$d"

# 冲突：退出码 2，且 rebase 现场保留
d=$(mktemp -d); make_fixture "$d" conflict
set +e; run_in "$d" v1.1-reF1nd moonfruit >/dev/null 2>&1; rc=$?; set -e
assert_eq "$rc" 2 "冲突时退出码为 2"
assert_ok "冲突现场保留" test -d "$d/$(git -C "$d" rev-parse --git-path rebase-merge)"
git -C "$d" rebase --abort
rm -rf "$d"

# 已存在 moonfruit tag 时，基点解析绝不能匹配到 tag 自己 ——
# 否则 rebase 区间为空，patch 会被静默丢弃而三道闸门全会放行
d=$(mktemp -d); make_fixture "$d" clean
git -C "$d" tag v1.0-reF1nd-moonfruit moonfruit
assert_eq "$(cd "$d" && . "$HERE/../scripts/rebase.sh" && current_base moonfruit)" \
          v1.0-reF1nd "current_base 跳过 moonfruit tag 自身"
run_in "$d" v1.1-reF1nd moonfruit
assert_eq "$(git -C "$d" rev-list --count v1.1-reF1nd..moonfruit)" \
          1 "已有 moonfruit tag 时 patch 未被丢弃"
assert_eq "$(git -C "$d" log --oneline -1 --format=%s moonfruit)" \
          'personal patch' "存活的正是那个 patch 提交"
rm -rf "$d"

# 标记扫描
d=$(mktemp -d); make_fixture "$d" clean
printf '<<<<<<< HEAD\n' >> "$d/app.go"
assert_fail "assert_no_markers 命中冲突标记" \
  bash -c "cd '$d' && . '$HERE/../scripts/rebase.sh' && assert_no_markers"
rm -rf "$d"

# Minor：分支名不再硬编码 moonfruit，改走 INTEGRATION_BRANCH（默认值仍是
# moonfruit，不影响上面所有用默认值的用例）。用一个真正叫别的名字的分支证明
# 默认参数确实取的是这个环境变量，而不是常量。
d=$(mktemp -d); make_fixture "$d" clean
git -C "$d" branch -m moonfruit patch-stack
assert_eq "$(cd "$d" && INTEGRATION_BRANCH=patch-stack bash -c \
              '. "'"$HERE"'/../scripts/rebase.sh"; current_base')" \
          v1.0-reF1nd "current_base 的分支名默认值来自 INTEGRATION_BRANCH，而非硬编码"
rm -rf "$d"
