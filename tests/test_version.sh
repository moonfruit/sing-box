#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$HERE/assert.sh"
# shellcheck disable=SC1091
. "$HERE/../scripts/version.sh"

B=v1.14.0-beta.5-reF1nd

assert_eq "$(base_of "$B-moonfruit")"       "$B"   "base_of：无计数器"
assert_eq "$(base_of "$B-moonfruit.3")"     "$B"   "base_of：有计数器"
assert_eq "$(base_of v1.14.0-beta.5-reF1nd.1-moonfruit.2)" \
          v1.14.0-beta.5-reF1nd.1                  "base_of：基点自带修订号"

assert_eq "$(next_target "$B")"             "$B-moonfruit"   "next_target：首个"
assert_eq "$(next_target "$B" "$B-moonfruit")" \
          "$B-moonfruit.1"                                   "next_target：第二个"
assert_eq "$(next_target "$B" "$B-moonfruit" "$B-moonfruit.1")" \
          "$B-moonfruit.2"                                   "next_target：第三个"
assert_eq "$(next_target "$B" v1.13.0-reF1nd-moonfruit)" \
          "$B-moonfruit"                   "next_target：忽略其它基点的 tag"

assert_eq "$(latest_target "$B")"           ""               "latest_target：无"
assert_eq "$(latest_target "$B" "$B-moonfruit" "$B-moonfruit.1")" \
          "$B-moonfruit.1"                                   "latest_target：取最大"

# 计数器不连续时，视为在最后一个连续项之后继续
assert_eq "$(next_target "$B" "$B-moonfruit" "$B-moonfruit.2")" \
          "$B-moonfruit.1"                 "next_target：填补空洞"
