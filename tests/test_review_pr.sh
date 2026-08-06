#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
. "$HERE/fixture.sh"
. "$HERE/../scripts/lib.sh"

d=$(mktemp -d); make_fixture "$d" clean
# 造出「上一版」与「新一版」两条 patch 序列，供 range-diff 使用
git -C "$d" tag v1.0-reF1nd-moonfruit moonfruit
( cd "$d" && bash "$HERE/../scripts/rebase.sh" v1.1-reF1nd moonfruit )

log_file=$(mktemp); printf '我把两侧改动合并了。\n' > "$log_file"
# review-pr.sh 自身 source 了 resolve.sh（需要 newly_touched），这里只 source 它。
body=$( cd "$d" \
        && . "$HERE/../scripts/review-pr.sh" \
        && pr_body v1.0-reF1nd v1.1-reF1nd v1.0-reF1nd-moonfruit v1.1-reF1nd-moonfruit "$log_file" )

assert_contains "$body" "v1.0-reF1nd"            "正文含旧基点"
assert_contains "$body" "v1.1-reF1nd"            "正文含新基点"
assert_contains "$body" "我把两侧改动合并了。"    "正文含 claude 的说明"
assert_contains "$body" "range-diff"             "正文含 range-diff 段落"
assert_contains "$body" "/ship"                  "正文含放行说明"
assert_contains "$body" "git rebase --onto"      "正文含人工接管命令"
rm -rf "$d" "$log_file"
