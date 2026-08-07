#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$HERE/assert.sh"
# shellcheck disable=SC1091
. "$HERE/../scripts/lib.sh"

# git_auth_header：Basic Auth 头，格式须与 actions/checkout 内部写入
# .git/config 的 extraheader 一致（"AUTHORIZATION: basic base64(x-access-token:TOKEN)"）。
header=$(git_auth_header 'a-real-token')
assert_eq "$header" \
  "AUTHORIZATION: basic $(printf 'x-access-token:a-real-token' | base64 | tr -d '\n')" \
  "git_auth_header：与 actions/checkout 的 extraheader 格式一致"
decoded=$(printf '%s' "$header" | sed 's/^AUTHORIZATION: basic //' | base64 -d)
assert_eq "$decoded" "x-access-token:a-real-token" "git_auth_header：base64 解码后是 x-access-token:<token>"

# git_auth_set / git_auth_clear：用完即清，不能在 .git/config 里留下痕迹 ——
# 这正是 C3 的核心：checkout 关掉 persist-credentials 后，凭据只应在真正推送/
# 拉取的那一刻短暂存在，claude -p 跑的那个窗口期内 .git/config 里不该有它。
d=$(mktemp -d); git init -q "$d"
assert_eq "$(git -C "$d" config --local --get http.https://github.com/.extraheader || true)" "" \
  "git_auth_set 之前：仓库里没有这条凭据"

( cd "$d" && git_auth_set 'a-real-token' )
assert_eq "$(git -C "$d" config --local --get http.https://github.com/.extraheader)" \
  "$header" "git_auth_set：写入的凭据与 git_auth_header 的输出一致"

( cd "$d" && git_auth_clear )
assert_eq "$(git -C "$d" config --local --get http.https://github.com/.extraheader || true)" "" \
  "git_auth_clear：用完即清，仓库里不再留有凭据"

# git_auth_clear 在没设置过的仓库上调用不能报错（resolve/review 等步骤即便
# 提前失败退出，也可能在没设置过凭据的情况下被要求清理一次）
d2=$(mktemp -d); git init -q "$d2"
assert_ok "git_auth_clear 在未设置过凭据时也不报错" bash -c \
  "cd '$d2' && . '$HERE/../scripts/lib.sh' && git_auth_clear"

rm -rf "$d" "$d2"
