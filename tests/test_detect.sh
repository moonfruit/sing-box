#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
. "$HERE/../scripts/lib.sh"
. "$HERE/../scripts/version.sh"
. "$HERE/../scripts/detect.sh"

# latest_upstream_tag 走 gh stub，见 tests/stubs/gh
PATH="$HERE/stubs:$PATH"

assert_eq "$(latest_upstream_tag)" \
  v1.14.0-beta.5-reF1nd.1 "latest_upstream_tag：按版本序取首个，且不漏 -reF1nd.1"

# Important-9：reF1nd 是第三方，git 允许 tag 名含单引号/反引号/$( 等 shell
# 特殊字符（已实测验证）。这个值后续会插值进 release.yml 的多处 shell 文本，
# 不做白名单校验就是脚本注入。
#
# 包一层子 shell 再调用：latest_upstream_tag 校验失败时走 die()，die 直接
# exit——若不隔离在子 shell 里，会把整个测试脚本一并炸穿，assert_fail 的
# else 分支永远执行不到。
try_malicious_tag() { ( latest_upstream_tag ); }
export GH_STUB_MALICIOUS_TAG=1
assert_fail "latest_upstream_tag 拒绝含 shell 特殊字符的 tag 名" try_malicious_tag
unset GH_STUB_MALICIOUS_TAG

# decide_build <base> <cur_base> <branch_sha> <latest_target_sha> <force>
assert_eq "$(decide_build v1.1-reF1nd v1.0-reF1nd aaa aaa false)" true  "上游出新版 → 构建"
assert_eq "$(decide_build v1.0-reF1nd v1.0-reF1nd aaa '' false)"  true  "基点相同但从未发布 → 构建"
assert_eq "$(decide_build v1.0-reF1nd v1.0-reF1nd bbb aaa false)" true  "patch 栈变了 → 构建"
assert_eq "$(decide_build v1.0-reF1nd v1.0-reF1nd aaa aaa false)" false "毫无变化 → 跳过"
assert_eq "$(decide_build v1.0-reF1nd v1.0-reF1nd aaa aaa true)"  true  "force → 构建"
