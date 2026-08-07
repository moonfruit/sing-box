#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
. "$HERE/fixture.sh"
. "$HERE/../scripts/lib.sh"

d=$(mktemp -d); make_fixture "$d" clean
# 造出「上一版」这个真实存在的已发布 tag（这是唯一允许手动摆放的东西：一个已发布
# 版本天然就是一个 git tag）。v1.0-reF1nd-moonfruit 才是旧基点 v1.0-reF1nd 下的
# 上一版，不是凭空传给 pr_body 的字符串。
git -C "$d" tag v1.0-reF1nd-moonfruit moonfruit
( cd "$d" && bash "$HERE/../scripts/rebase.sh" v1.1-reF1nd moonfruit )
# 模拟「claude 解决冲突时顺带对 patch 做了改动」，让新旧两版的 range-diff 里
# 真的出现一行差异，而不只是「同一个提交换了个 SHA」这种平凡等价。
printf 'line1\npatched\nextra\n' > "$d/app.go"
( cd "$d" && git add -A && git commit -q --amend -m 'personal patch' )

log_file=$(mktemp); printf '我把两侧改动合并了。\n' > "$log_file"
# 走真实契约：CUR_BASE 是旧基点，prev 由 resolved_prev_target 从 git tag 反查得到，
# 不再像之前那样把 v1.0-reF1nd-moonfruit 当字符串字面量直接塞给 pr_body ——
# 那样会掩盖 review-pr.sh 自己算错比较基准的问题（C1）。
prev=$( cd "$d" && . "$HERE/../scripts/review-pr.sh" && resolved_prev_target v1.0-reF1nd )
assert_eq "$prev" v1.0-reF1nd-moonfruit \
  "resolved_prev_target 从 git tag 反查旧基点下的上一版，而非依赖 detect 的 prev_target（相对新基点算，此刻恒空）"

body=$( cd "$d" \
        && . "$HERE/../scripts/review-pr.sh" \
        && pr_body v1.0-reF1nd v1.1-reF1nd "$prev" v1.1-reF1nd-moonfruit "$log_file" )

assert_contains "$body" "v1.0-reF1nd"            "正文含旧基点"
assert_contains "$body" "v1.1-reF1nd"            "正文含新基点"
assert_contains "$body" "我把两侧改动合并了。"    "正文含 claude 的说明"
assert_contains "$body" "range-diff"             "正文含 range-diff 段落"
assert_contains "$body" "/ship"                  "正文含放行说明"
assert_contains "$body" "git rebase --onto"      "正文含人工接管命令"
# 机械证据本身不能是空的：range-diff 段落要能看出真实的行级差异，
# 而不是「该基点下没有上一版」的占位文案（那正是 C1 修复前的恒定状态）。
assert_contains "$body" "extra" "range-diff 含真实的行级差异，证明比较基准非空"
assert_eq "$(printf '%s' "$body" | grep -c '该基点下没有上一版')" 0 \
  "range-diff 不是「无从比较」的占位文案"

# Minor：解决日志为空时拒绝生成 PR 正文，而不是悄悄贴出一段空白的
# 「claude 的解决说明」——空日志本身就说明上一步没有正常留痕，该早失败。
empty_log=$(mktemp)
assert_fail "解决日志为空时 pr_body 拒绝生成正文" bash -c \
  "cd '$d' && . '$HERE/../scripts/review-pr.sh' \
   && pr_body v1.0-reF1nd v1.1-reF1nd '$prev' v1.1-reF1nd-moonfruit '$empty_log'"
rm -f "$empty_log"

rm -rf "$d" "$log_file"
