#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"

# tests.yml 的定时 gates 是在替 release.yml 的冲突闸门做空跑；两边的 Go 版本
# 一旦漂移，空跑验证的就是另一个 Go 下的闸门，过了也说明不了什么。
go_version_of() {
  sed -nE 's/^  GO_VERSION: *"?([^"]*)"?$/\1/p' "$HERE/../.github/workflows/$1"
}
release_go=$(go_version_of release.yml)
assert_ok "release.yml 声明了 GO_VERSION" test -n "$release_go"
assert_eq "$(go_version_of tests.yml)" "$release_go" "tests.yml 与 release.yml 的 GO_VERSION 一致"
