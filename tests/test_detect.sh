#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
. "$HERE/../scripts/lib.sh"
. "$HERE/../scripts/version.sh"
. "$HERE/../scripts/detect.sh"

# latest_upstream_tag 走 gh stub，见 tests/stubs/gh
PATH="$HERE/stubs:$PATH"

# stub 是子进程，必须 export；且不能写成 `VAR=x assert_eq "$(f)"` ——
# 命令替换先于该前缀赋值求值，变量传不进 f。
export GH_STUB_MODE=releases
assert_eq "$(latest_upstream_tag)" \
  v1.14.0-beta.5-reF1nd "latest_upstream_tag：取最新 Release"

export GH_STUB_MODE=no-releases
assert_eq "$(latest_upstream_tag)" \
  v1.14.0-beta.5-reF1nd.1 "latest_upstream_tag：无 Release 时回退 tag 列表，且不漏 -reF1nd.1"

unset GH_STUB_MODE

# decide_build <base> <cur_base> <branch_sha> <latest_target_sha> <force>
assert_eq "$(decide_build v1.1-reF1nd v1.0-reF1nd aaa aaa false)" true  "上游出新版 → 构建"
assert_eq "$(decide_build v1.0-reF1nd v1.0-reF1nd aaa '' false)"  true  "基点相同但从未发布 → 构建"
assert_eq "$(decide_build v1.0-reF1nd v1.0-reF1nd bbb aaa false)" true  "patch 栈变了 → 构建"
assert_eq "$(decide_build v1.0-reF1nd v1.0-reF1nd aaa aaa false)" false "毫无变化 → 跳过"
assert_eq "$(decide_build v1.0-reF1nd v1.0-reF1nd aaa aaa true)"  true  "force → 构建"
