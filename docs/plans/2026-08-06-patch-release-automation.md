# sing-box patch 化发布自动化 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让个人 patch 以「rebase 到最新 reF1nd tag」的形式自动进入 Homebrew tap 与 linux-arm64 二进制两条发布链。

**Architecture:** `moonfruit/sing-box` 的 orphan 默认分支 `ci` 存放全部自动化；集成分支 `moonfruit` 承载 patch 栈，由 CI rebase 到新基点后打 tag 触发构建。冲突时由 `claude -p` 在真实 rebase 现场尝试解决，过三道闸门后开 PR 等人工评论 `/ship` 放行。

**Tech Stack:** Bash（POSIX-ish，`set -euo pipefail`）、GitHub Actions、`gh` CLI、`jq`、Homebrew（`brew bump-formula-pr`）、`claude` CLI。

## Global Constraints

- 设计依据：`docs/specs/2026-08-05-patch-release-design.md`。本计划中的行为与之冲突时以 spec 为准。
- 所有 shell 脚本以 `#!/usr/bin/env bash` 开头，并 `set -euo pipefail`。
- 版本命名：`<reF1nd tag>-moonfruit[.N]`，`N` 从 1 起（首个不带数字）。基点 = 去掉尾部 `-moonfruit[.N]`。
- 集成分支名 `moonfruit`；默认分支名 `ci`；临时分支 `auto/resolve-<TARGET>`、`base/<TARGET>`。
- fork 内部操作一律用 `GITHUB_TOKEN`。两处例外用统一的 secret `GH_PAT`（需 `repo` + `workflow`）：`prepare` 的 checkout（要推送带上游 workflow 文件的分支），以及 tap-bump（跨仓库）。注入 tap-bump 时映射为环境变量 `HOMEBREW_GITHUB_API_TOKEN`，那是 `brew` 认得的名字。
- 上游仓库常量 `UPSTREAM_REPO=reF1nd/sing-box`。
- 脚本一律放在 `scripts/`，测试放在 `tests/`，用 `bash tests/run.sh` 全量运行，零外部测试框架依赖。
- 所有脚本必须通过 `shellcheck`；所有 workflow 必须通过 `actionlint`。
- 提交信息用英文，正文说明「为什么」；用户可见的文档与注释用简体中文。

---

## File Structure

| 文件 | 职责 |
| --- | --- |
| `scripts/lib.sh` | 日志、致命错误、GitHub Actions output 写入 |
| `scripts/version.sh` | 纯函数：基点 ↔ moonfruit tag 的换算与计数器推进 |
| `scripts/detect.sh` | 确定基点、目标 tag、是否需要构建；支持 ship 模式 |
| `scripts/rebase.sh` | 集成分支 rebase 到新基点；冲突标记扫描 |
| `scripts/resolve.sh` | 冲突现场调用 `claude -p` + 三道闸门 |
| `scripts/review-pr.sh` | 推 `auto/*`、`base/*` 分支，开审查 PR |
| `scripts/notify.sh` | Bark 推送与 GitHub issue 的开启/追加 |
| `scripts/tap-bump.sh` | `brew bump-formula-pr` 并打 `pr-pull` 标签 |
| `tests/assert.sh` | 极简断言与 stub 工具 |
| `tests/fixture.sh` | 构造用于 rebase 测试的临时 git 仓库 |
| `tests/run.sh` | 运行 `tests/test_*.sh` 全部用例 |
| `.github/workflows/release.yml` | 唯一的 workflow：detect → rebase → build → release → gitee/tap |

---

### Task 1: 测试脚手架与版本换算

**Files:**
- Create: `scripts/lib.sh`
- Create: `scripts/version.sh`
- Create: `tests/assert.sh`
- Create: `tests/run.sh`
- Test: `tests/test_version.sh`

**Interfaces:**
- Consumes: 无
- Produces:
  - `log <msg>` / `die <msg>`（`lib.sh`）
  - `emit <key> <value>`：写 `$GITHUB_OUTPUT`，未设置时写 stdout（`lib.sh`）
  - `base_of <target-tag> -> <base-tag>`（`version.sh`）
  - `tags_for_base <base-tag> <tag>... -> 该基点下的 moonfruit tag，按计数器升序，每行一个`
  - `latest_target <base-tag> <tag>... -> 计数器最大的那个，无则空`
  - `next_target <base-tag> <tag>... -> 下一个可用的 moonfruit tag`
  - `assert_eq <actual> <expected> <label>`、`assert_ok <label> <cmd...>`、`assert_fail <label> <cmd...>`、`assert_contains <haystack> <needle> <label>`（`tests/assert.sh`）

- [ ] **Step 1: 写失败的测试**

`tests/test_version.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
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
```

`tests/assert.sh`：

```bash
#!/usr/bin/env bash
# 极简断言。失败即置位 ASSERT_FAILED，由 tests/run.sh 汇总退出码。
ASSERT_FAILED=${ASSERT_FAILED:-0}

assert_eq() {
  local actual=$1 expected=$2 label=${3:-assert_eq}
  if [[ "$actual" == "$expected" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s\n       期望: %q\n       实际: %q\n' "$label" "$expected" "$actual"
    ASSERT_FAILED=1
  fi
}

assert_ok() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then printf '  ok   %s\n' "$label"
  else printf '  FAIL %s（命令应成功却失败: %s）\n' "$label" "$*"; ASSERT_FAILED=1; fi
}

assert_fail() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then printf '  FAIL %s（命令应失败却成功: %s）\n' "$label" "$*"; ASSERT_FAILED=1
  else printf '  ok   %s\n' "$label"; fi
}

assert_contains() {
  local haystack=$1 needle=$2 label=${3:-assert_contains}
  if [[ "$haystack" == *"$needle"* ]]; then printf '  ok   %s\n' "$label"
  else printf '  FAIL %s\n       未包含: %q\n' "$label" "$needle"; ASSERT_FAILED=1; fi
}
```

`tests/run.sh`：

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
rc=0
for t in "$HERE"/test_*.sh; do
  printf '%s\n' "$(basename "$t")"
  ASSERT_FAILED=0
  # shellcheck disable=SC1090
  ( . "$t"; exit "$ASSERT_FAILED" ) || rc=1
done
if (( rc )); then printf '\n测试失败\n'; else printf '\n全部通过\n'; fi
exit "$rc"
```

- [ ] **Step 2: 运行测试确认失败**

```bash
bash tests/run.sh
```

Expected: FAIL，报 `scripts/version.sh` 不存在。

- [ ] **Step 3: 写最小实现**

`scripts/lib.sh`：

```bash
#!/usr/bin/env bash
# 全部脚本共享的日志与 GitHub Actions 交互工具。

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# emit <key> <value> —— 写 step output；本地运行（无 GITHUB_OUTPUT）时打到 stdout 便于观察。
emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

# summary <markdown> —— 追加到 Actions 的 job summary。
summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  else
    printf '%s\n' "$1"
  fi
}
```

`scripts/version.sh`：

```bash
#!/usr/bin/env bash
# 基点 tag 与 moonfruit tag 之间的换算。命名规则见 docs/specs/2026-08-05-patch-release-design.md §3
#
#   v1.14.0-beta.5-reF1nd          基点（reF1nd 打的）
#   v1.14.0-beta.5-reF1nd-moonfruit    首个派生
#   v1.14.0-beta.5-reF1nd-moonfruit.1  同一基点上的第二个

# base_of <moonfruit-tag> —— 反推基点 tag。
base_of() { printf '%s\n' "${1%-moonfruit*}"; }

# tags_for_base <base-tag> <tag>... —— 属于该基点、且计数器连续的 moonfruit tag，升序输出。
tags_for_base() {
  local base=$1; shift
  local n=0 candidate="${base}-moonfruit"
  while printf '%s\n' "$@" | grep -qxF -- "$candidate"; do
    printf '%s\n' "$candidate"
    n=$((n + 1))
    candidate="${base}-moonfruit.${n}"
  done
}

# latest_target <base-tag> <tag>... —— 该基点下计数器最大的 tag，无则输出空。
latest_target() { tags_for_base "$@" | tail -n1; }

# next_target <base-tag> <tag>... —— 下一个可用的 moonfruit tag。
next_target() {
  local base=$1
  local last; last=$(latest_target "$@")
  if [[ -z "$last" ]]; then
    printf '%s\n' "${base}-moonfruit"
    return
  fi
  local suffix=${last#"${base}-moonfruit"}   # "" 或 ".N"
  printf '%s-moonfruit.%d\n' "$base" "$(( ${suffix#.} + 1 ))"
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
bash tests/run.sh
```

Expected: `test_version.sh` 全部 ok，末行「全部通过」。

- [ ] **Step 5: shellcheck 通过**

```bash
brew install shellcheck   # 若尚未安装
shellcheck scripts/*.sh tests/*.sh
```

Expected: 无输出。

- [ ] **Step 6: 提交**

```bash
git add scripts/lib.sh scripts/version.sh tests/
git commit -m "Add version arithmetic for moonfruit tags

The counter advances only within one reF1nd base, so a release triggered
by a new upstream tag restarts at the bare -moonfruit suffix while a new
patch on an unchanged base becomes .1, .2, and so on. Deriving the base
by stripping that suffix keeps the mapping exact even when reF1nd itself
carries a revision number."
```

---

### Task 2: 基点检测与构建判定

**Files:**
- Create: `scripts/detect.sh`
- Create: `tests/stubs/gh`
- Test: `tests/test_detect.sh`

**Interfaces:**
- Consumes: `lib.sh` 的 `log`/`die`/`emit`；`version.sh` 的 `next_target`/`latest_target`/`base_of`
- Produces:
  - `latest_upstream_tag -> <reF1nd tag>`
  - `decide_build <base> <cur_base> <branch_sha> <latest_target_sha> <force> -> "true"|"false"`
  - `scripts/detect.sh` 作为可执行入口，emit 出：`should_build`、`base`、`target`、`cur_base`

- [ ] **Step 1: 写失败的测试**

`tests/test_detect.sh`：

```bash
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

# decide_build <base> <cur_base> <branch_sha> <latest_target_sha> <force>
assert_eq "$(decide_build v1.1-reF1nd v1.0-reF1nd aaa aaa false)" true  "上游出新版 → 构建"
assert_eq "$(decide_build v1.0-reF1nd v1.0-reF1nd aaa '' false)"  true  "基点相同但从未发布 → 构建"
assert_eq "$(decide_build v1.0-reF1nd v1.0-reF1nd bbb aaa false)" true  "patch 栈变了 → 构建"
assert_eq "$(decide_build v1.0-reF1nd v1.0-reF1nd aaa aaa false)" false "毫无变化 → 跳过"
assert_eq "$(decide_build v1.0-reF1nd v1.0-reF1nd aaa aaa true)"  true  "force → 构建"
```

`tests/stubs/gh`（须 `chmod +x`）：

```bash
#!/usr/bin/env bash
# gh 的测试替身。
set -euo pipefail
case "${1:-}" in
  api)
    case "$2" in
      # 夹具里混入一个 -reF1nd-moonfruit：它不以 -reF1nd[.N] 结尾，必须被过滤掉，
      # 否则我们自己的发布 tag 会被当成上游基点。它在版本序里排最高，正则一旦
      # 放松就会被选中，断言随即变红。
      #
      # 真跑调用方传来的 --jq 过滤条件，而不是自己重新实现一遍：stub 若只按端点
      # 返回固定文本，被测的正则根本不会被执行，断言只是「正确答案恰好排在最前」
      # 而通过 —— 这正是本项目此处踩过的坑。
      repos/reF1nd/sing-box/tags*)
        shift 2
        filter=
        while [[ $# -gt 0 ]]; do
          if [[ "$1" == --jq ]]; then filter=${2:?"stub: --jq 缺少参数"}; break; fi
          shift
        done
        [[ -n "$filter" ]] || filter='.[].name'
        jq -r "$filter" <<'JSON'
[
  {"name": "v1.14.0-alpha.43-reF1nd"},
  {"name": "v1.14.0-beta.5-reF1nd"},
  {"name": "v1.14.0-beta.5-reF1nd.1"},
  {"name": "v1.14.0-beta.9-reF1nd-moonfruit"}
]
JSON
        ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
```

- [ ] **Step 2: 运行测试确认失败**

```bash
chmod +x tests/stubs/gh
bash tests/run.sh
```

Expected: FAIL，报 `scripts/detect.sh` 不存在。

- [ ] **Step 3: 写最小实现**

`scripts/detect.sh`：

```bash
#!/usr/bin/env bash
# 确定 reF1nd 基点、目标 moonfruit tag，以及本次是否需要构建。
# 被 source 时只提供函数；被直接执行时读环境变量并 emit step output。
set -euo pipefail

DETECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$DETECT_DIR/lib.sh"
# shellcheck source=scripts/version.sh
. "$DETECT_DIR/version.sh"
# current_base 归 rebase.sh 所有。基点解析出错会静默丢弃全部 patch 且三道闸门
# 都放行，这种逻辑只能有一份实现、由一处回归测试守着。
# shellcheck source=scripts/rebase.sh
. "$DETECT_DIR/rebase.sh"

UPSTREAM_REPO=${UPSTREAM_REPO:-reF1nd/sing-box}
INTEGRATION_BRANCH=${INTEGRATION_BRANCH:-moonfruit}

# latest_upstream_tag —— reF1nd 最新的 tag。
#
# 不读 Release 列表：reF1nd 只打 tag、从不发布 Release，该路径实测恒为空。
# 留着它反而是隐患 —— 一旦上游哪天开始发 Release，检测依据会毫无征兆地改变。
#
# 用正则而非 endswith("-reF1nd")：后者会漏掉 -reF1nd.1 这类修订 tag。
latest_upstream_tag() {
  local tag
  tag=$(gh api "repos/${UPSTREAM_REPO}/tags?per_page=100" --paginate \
          --jq '.[].name | select(test("-reF1nd(\\.[0-9]+)?$"))' \
        | sort -V -r | head -n1)
  [[ -n "$tag" ]] || die "未能确定 ${UPSTREAM_REPO} 的最新 tag"
  printf '%s\n' "$tag"
}

# decide_build <base> <cur_base> <branch_sha> <latest_target_sha> <force>
decide_build() {
  local base=$1 cur_base=$2 branch_sha=$3 target_sha=$4 force=$5
  if [[ "$force" == true ]]; then printf 'true\n'; return; fi
  if [[ "$base" != "$cur_base" ]]; then printf 'true\n'; return; fi   # 上游出新版
  if [[ -z "$target_sha" ]]; then printf 'true\n'; return; fi          # 该基点尚未发布过
  if [[ "$branch_sha" != "$target_sha" ]]; then printf 'true\n'; return; fi  # patch 栈变了
  printf 'false\n'
}

main() {
  local base=${BASE_TAG:-}
  [[ -n "$base" ]] || base=$(latest_upstream_tag)

  local existing; mapfile -t existing < <(git tag --list '*-moonfruit' '*-moonfruit.*')
  local cur_base; cur_base=$(current_base "$INTEGRATION_BRANCH")
  local branch_sha; branch_sha=$(git rev-parse "$INTEGRATION_BRANCH")

  local prev; prev=$(latest_target "$base" "${existing[@]}")
  local prev_sha=; [[ -n "$prev" ]] && prev_sha=$(git rev-parse "${prev}^{commit}")

  local should; should=$(decide_build "$base" "$cur_base" "$branch_sha" "$prev_sha" "${FORCE:-false}")
  local target; target=$(next_target "$base" "${existing[@]}")

  log "基点 ${cur_base} → ${base}；目标 ${target}；构建 ${should}"
  emit should_build "$should"
  emit base         "$base"
  emit cur_base     "$cur_base"
  emit target       "$target"
  emit prev_target  "$prev"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

- [ ] **Step 4: 运行测试确认通过**

```bash
bash tests/run.sh
```

Expected: `test_detect.sh` 全部 ok。

- [ ] **Step 5: shellcheck 通过**

```bash
shellcheck scripts/*.sh tests/*.sh tests/stubs/gh
```

Expected: 无输出。

- [ ] **Step 6: 提交**

```bash
git add scripts/detect.sh tests/
git commit -m "Detect the upstream base and decide whether to build

Take reF1nd's newest tag from its release feed rather than from a version
sort of the tag list: the feed reflects the order things were actually
published, and the old sing-box-release filter matched only names ending
in -reF1nd, silently skipping revision tags like -reF1nd.1.

A build is warranted by a moved base, an unreleased base, or a changed
patch stack — the last one is what lets a new patch ship without waiting
for upstream."
```

---

### Task 3: 集成分支 rebase 与标记扫描

**Files:**
- Create: `scripts/rebase.sh`
- Create: `tests/fixture.sh`
- Test: `tests/test_rebase.sh`

**Interfaces:**
- Consumes: `lib.sh`
- Produces:
  - `current_base <branch> -> <reF1nd tag>`
  - `rebase_onto <new-base> <branch>` → 退出码 `0` 成功（含「已在新基点上，无需 rebase」）、`2` 冲突且**保留 rebase 现场**（不 abort，交给 `resolve.sh`）
  - `assert_no_markers`：工作树含 `^<<<<<<< ` 即 `die`
  - `tests/fixture.sh` 的 `make_fixture <dir> <clean|conflict>`

- [ ] **Step 1: 写失败的测试**

`tests/fixture.sh`：

```bash
#!/usr/bin/env bash
# 构造一个微型仓库，模拟「reF1nd 基点 + 个人 patch + 上游前进」的形状。
#   moonfruit 分支 = v1.0-reF1nd + 一个 patch 提交
#   v1.1-reF1nd    = 上游前进后的新基点
# mode=clean    上游改动与 patch 不冲突
# mode=conflict 上游改动与 patch 落在同一行
make_fixture() {
  local dir=$1 mode=$2
  git init -q -b main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name  Tester

  printf 'line1\nline2\n' > "$dir/app.go"
  printf 'other\n'         > "$dir/other.go"
  git -C "$dir" add .
  git -C "$dir" commit -qm 'upstream base'
  git -C "$dir" tag v1.0-reF1nd

  git -C "$dir" checkout -q -b moonfruit
  printf 'line1\npatched\n' > "$dir/app.go"
  git -C "$dir" commit -qam 'personal patch'

  git -C "$dir" checkout -q main
  if [[ "$mode" == conflict ]]; then
    printf 'line1\nupstream-changed\n' > "$dir/app.go"
  else
    printf 'other-changed\n' > "$dir/other.go"
  fi
  git -C "$dir" commit -qam 'upstream moves on'
  git -C "$dir" tag v1.1-reF1nd
  git -C "$dir" checkout -q moonfruit
}
```

`tests/test_rebase.sh`：

```bash
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
```

- [ ] **Step 2: 运行测试确认失败**

```bash
bash tests/run.sh
```

Expected: FAIL，报 `scripts/rebase.sh` 不存在。

- [ ] **Step 3: 写最小实现**

`scripts/rebase.sh`：

```bash
#!/usr/bin/env bash
# 把集成分支上的 patch 栈搬到新的 reF1nd 基点上。
# 冲突时故意 **不 abort**：真实的 rebase 现场（index 中的 stage 1/2/3）是
# scripts/resolve.sh 唯一能用上的东西，abort 掉就只剩冲突标记文本了。
set -euo pipefail

REBASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$REBASE_DIR/lib.sh"

# current_base <branch> —— 从 git 历史反查当前基点，而非从 tag 名推导。
# 这使得 rebase 步骤幂等：人工已在本地 rebase 并推送时，CI 重跑会自动跳过。
#
# --exclude 不可省：moonfruit tag 形如 <基点>-moonfruit[.N]，本身也匹配 *-reF1nd*。
# 少了它，第一个 moonfruit tag 出现后基点会解析成 tag 自己，rebase --onto 的区间
# 变成空区间，patch 被静默全部丢弃 —— 而三道闸门全会放行（无标记、能编译、测试过）。
current_base() {
  git describe --tags --match '*-reF1nd*' --exclude '*-moonfruit*' --abbrev=0 "${1:-moonfruit}"
}

# assert_no_markers —— 打 tag 前的硬性检查。已核对 reF1nd 源码树不含此类行，不会误报。
assert_no_markers() {
  if git grep -n '^<<<<<<< ' -- . ; then
    die "工作树中存在冲突标记，拒绝继续"
  fi
}

# rebase_onto <new-base> <branch> —— 0 成功 / 2 冲突（现场保留）
rebase_onto() {
  local new=$1 branch=${2:-moonfruit} cur
  cur=$(current_base "$branch")
  if [[ "$cur" == "$new" ]]; then
    log "集成分支已在 ${new} 上，跳过 rebase"
    return 0
  fi
  log "rebase ${branch}：${cur} → ${new}"
  git checkout -q "$branch"
  if git rebase --onto "$new" "$cur" "$branch"; then
    return 0
  fi
  log "rebase 冲突，保留现场供自动解决"
  return 2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rebase_onto "$@"
fi
```

- [ ] **Step 4: 运行测试确认通过**

```bash
bash tests/run.sh
```

Expected: `test_rebase.sh` 全部 ok。

- [ ] **Step 5: 用真实仓库交叉验证一次**

在 sing-box 仓库的一份临时 clone 中（不要在 `ci` 工作目录里做）：

```bash
tmp=$(mktemp -d)
git clone -q --no-checkout . "$tmp/sb"
# --update-head-ok：新克隆的 HEAD 指向 ci，普通 fetch 会拒绝更新它
git -C "$tmp/sb" fetch -q --update-head-ok origin \
  'refs/tags/*:refs/tags/*' 'refs/heads/*:refs/heads/*'
# fix-mdns-timeout 的基点 8a42af329 只带上游的 v1.14.0-alpha.29 标签，没有
# -reF1nd 后缀，current_base 按 *-reF1nd* 匹配不到它。真正形状正确的 moonfruit
# 分支要到 Task 11 才建出来，所以这里在一次性克隆中补一个同形状的标签来复现。
git -C "$tmp/sb" tag v1.14.0-alpha.29-reF1nd 8a42af329
git -C "$tmp/sb" checkout -q -B moonfruit fix-mdns-timeout
( cd "$tmp/sb" && bash "$OLDPWD/scripts/rebase.sh" v1.14.0-beta.5-reF1nd moonfruit ); echo "rc=$?"
```

Expected: `rc=2`（这正是 spec 中记录的 `mdns.go` 6 行冲突），且 `.git/rebase-merge`
仍在（冲突现场保留）。随后 `git -C "$tmp/sb" rebase --abort && rm -rf "$tmp"`。

- [ ] **Step 6: 提交**

```bash
git add scripts/rebase.sh tests/
git commit -m "Rebase the integration branch onto a new reF1nd base

Read the current base out of git history instead of parsing it from a tag
name, so the step is idempotent: after a human resolves a conflict locally
and pushes, a re-run sees the branch already sitting on the new base and
does nothing.

Leave a conflicting rebase in progress rather than aborting it. The index
stages are the only thing that makes an automated resolution better than
editing marker text, and aborting throws them away."
```

---

### Task 4: 通知（Bark 与 issue）

**Files:**
- Create: `scripts/notify.sh`
- Create: `tests/stubs/curl`
- Test: `tests/test_notify.sh`

**Interfaces:**
- Consumes: `lib.sh`
- Produces:
  - `bark <title> <body> <url>`：`BARK_URL` 未配置时静默跳过并返回 0
  - `open_or_comment_issue <target-tag> <body-file>`：以标签 `release-conflict` 检索同标题 open issue，有则追加评论，无则新建

- [ ] **Step 1: 写失败的测试**

`tests/stubs/curl`（须 `chmod +x`）：

```bash
#!/usr/bin/env bash
# curl 的测试替身：把 stdin 与参数记到 $CURL_STUB_LOG。
set -euo pipefail
{ printf 'ARGS %s\n' "$*"; printf 'BODY '; cat; printf '\n'; } >> "${CURL_STUB_LOG:?}"
```

`tests/test_notify.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
. "$HERE/../scripts/lib.sh"
. "$HERE/../scripts/notify.sh"

PATH="$HERE/stubs:$PATH"
CURL_STUB_LOG=$(mktemp); export CURL_STUB_LOG

# 未配置 BARK_URL 时静默跳过
unset BARK_URL
assert_ok "无 BARK_URL 时不报错" bark "标题" "正文" "https://example.com"
assert_eq "$(wc -c < "$CURL_STUB_LOG" | tr -d ' ')" 0 "无 BARK_URL 时不发请求"

# 配置后发出 JSON
export BARK_URL=https://api.day.app/testkey
bark "新版本" "v1.0-reF1nd-moonfruit 已打 tag" "https://example.com/r"
logged=$(cat "$CURL_STUB_LOG")
assert_contains "$logged" "https://api.day.app/testkey" "请求打到 BARK_URL"
assert_contains "$logged" '"title":"新版本"'            "JSON 含 title"
assert_contains "$logged" '"group":"sing-box"'          "JSON 含 group"
assert_contains "$logged" '"url":"https://example.com/r"' "JSON 含 url"

# 端点不可达时也必须返回 0 —— 否则调用方的 set -e 会中止整条发布流水线
export BARK_FAIL=1
assert_ok "推送失败不向上传播" bark "标题" "正文" "https://example.com"
unset BARK_FAIL
rm -f "$CURL_STUB_LOG"
unset BARK_URL

# open_or_comment_issue：无既有 issue 时新建
GH_STUB_LOG=$(mktemp); export GH_STUB_LOG
body=$(mktemp); printf '冲突详情\n' > "$body"
open_or_comment_issue v1.0-reF1nd-moonfruit "$body"
logged=$(cat "$GH_STUB_LOG")
assert_contains "$logged" "issue list"        "先检索既有 issue"
assert_contains "$logged" "issue create"      "无既有 issue 时新建"
assert_contains "$logged" "release-conflict"  "带 release-conflict 标签"

# 已有 issue 时只追加评论，不重复新建
: > "$GH_STUB_LOG"
export GH_STUB_MODE=issue-exists
open_or_comment_issue v1.0-reF1nd-moonfruit "$body"
assert_contains "$(cat "$GH_STUB_LOG")" "issue comment 7" "已有 issue 时追加评论"
assert_eq "$(grep -c 'issue create' "$GH_STUB_LOG" || true)" 0 "已有 issue 时不重复新建"

unset GH_STUB_MODE
rm -f "$GH_STUB_LOG" "$body"
```

`tests/stubs/curl` 需要一条失败开关；在 `set -euo pipefail` 之后、写日志之前插入：

```bash
[[ -z "${BARK_FAIL:-}" ]] || exit 7
```

同时扩展 `tests/stubs/gh`，让它认得 `issue` 子命令（`api` 分支保持不变）：

```bash
  issue)
    printf 'GH %s\n' "$*" >> "${GH_STUB_LOG:?}"
    if [[ "${2:-}" == list && "${GH_STUB_MODE:-}" == issue-exists ]]; then
      printf '7\n'
    fi
    ;;
```

- [ ] **Step 2: 运行测试确认失败**

```bash
chmod +x tests/stubs/curl
bash tests/run.sh
```

Expected: FAIL，报 `scripts/notify.sh` 不存在。

- [ ] **Step 3: 写最小实现**

`scripts/notify.sh`：

```bash
#!/usr/bin/env bash
# Bark 推送与 GitHub issue。Bark 是主渠道，所有事件都发；
# issue 只在没有审查 PR 可指的时候才开（见 spec §7）。
set -euo pipefail

NOTIFY_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$NOTIFY_DIR/lib.sh"

# bark <title> <body> <url>
# 无论未配置端点还是推送失败，都只记录不向调用方传播 —— 通知永远不该成为
# 发布失败的原因。调用方普遍开着 set -e，一个非零返回会直接中止整条流水线。
bark() {
  if [[ -z "${BARK_URL:-}" ]]; then
    log "BARK_URL 未配置，跳过推送"
    return 0
  fi
  if ! jq -cn --arg t "$1" --arg b "$2" --arg u "$3" \
       '{title:$t, body:$b, url:$u, group:"sing-box"}' \
     | curl -fsS -X POST -H 'Content-Type: application/json' --data @- "$BARK_URL" >/dev/null
  then
    log "Bark 推送失败，已忽略"
  fi
  return 0
}

# open_or_comment_issue <target-tag> <body-file>
open_or_comment_issue() {
  local tag=$1 body=$2 num
  num=$(gh issue list --label release-conflict --state open \
          --search "$tag in:title" --json number --jq '.[0].number // empty')
  if [[ -n "$num" ]]; then
    gh issue comment "$num" --body-file "$body"
  else
    gh issue create --label release-conflict \
      --title "发布受阻：${tag}" --body-file "$body"
  fi
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
bash tests/run.sh
```

Expected: `test_notify.sh` 全部 ok。

- [ ] **Step 5: shellcheck 通过并提交**

```bash
shellcheck scripts/*.sh tests/*.sh tests/stubs/*
git add scripts/notify.sh tests/
git commit -m "Notify through Bark, and open an issue only when needed

A missing BARK_URL is not an error: notification is never the reason a
release should fail. Issues are reserved for failures with no review PR
to point at, so the successful-resolution path leaves exactly one object
to look at."
```

---

### Task 5: 冲突自动解决与三道闸门

**Files:**
- Create: `scripts/resolve.sh`
- Create: `tests/stubs/claude`
- Test: `tests/test_resolve.sh`

**Interfaces:**
- Consumes: `lib.sh`、`rebase.sh` 的 `assert_no_markers`、`tests/fixture.sh`
- Produces:
  - `build_prompt <cur_base> <new_base> -> <prompt 文本>`
  - `gate_markers`、`gate_build`、`gate_test`：失败即返回非 0
  - `newly_touched <base> <prev_target> <cur_base> -> 相对上一版新触及的文件，每行一个`
  - `resolve_conflicts <cur_base> <new_base>` → `0` 解决成功且过闸门；`1` 失败（已 `git rebase --abort`）

- [ ] **Step 1: 写失败的测试**

`tests/stubs/claude`（须 `chmod +x`）：

```bash
#!/usr/bin/env bash
# claude 的测试替身。CLAUDE_STUB_MODE 决定它如何「解决」冲突。
set -euo pipefail
# 先读空 stdin：真实的 claude -p 会读取完整提示词；这里不关心内容，但必须把
# 管道另一端（build_prompt 的 cat）写入的内容读完，否则一旦本进程提前退出、
# 关闭读端，写端会被 SIGPIPE 杀死，在 pipefail 下把「已解决」误判为「调用失败」。
cat >/dev/null
case "${CLAUDE_STUB_MODE:-resolve}" in
  resolve)   printf 'line1\nresolved\n' > app.go; printf '已合并两侧改动\n' ;;
  leave)     printf '我放弃了\n' ;;   # 不动文件，冲突标记留在原地
  fail)      exit 1 ;;
esac
```

`tests/test_resolve.sh`：

```bash
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
```

- [ ] **Step 2: 运行测试确认失败**

```bash
chmod +x tests/stubs/claude
bash tests/run.sh
```

Expected: FAIL，报 `scripts/resolve.sh` 不存在。

- [ ] **Step 3: 写最小实现**

`scripts/resolve.sh`：

```bash
#!/usr/bin/env bash
# 在真实的 rebase 冲突现场调用 claude，然后跑三道闸门。
# 不预先把上下文切片喂给模型：冲突未必是「同一处代码被改动」，也可能是
# 「上游变更了别处的 API，patch 必须跟着适配另一个文件」，后者只能靠探索发现。
set -euo pipefail

RESOLVE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$RESOLVE_DIR/lib.sh"
# shellcheck source=scripts/rebase.sh
. "$RESOLVE_DIR/rebase.sh"

# 日志必须落在工作树之外：resolve_conflicts 用 git add -A 收拢模型的改动，
# 工作树内的日志会被一并提交进 patch，随发布源码永久留存并逐次增长。
# .git/ 目录天然不在 add 的范围内。
RESOLVE_LOG=${RESOLVE_LOG:-$(git rev-parse --git-dir 2>/dev/null || echo .)/claude-resolution.md}

# build_prompt <cur_base> <new_base>
build_prompt() {
  local cur=$1 new=$2 conflicts patch_files msg
  conflicts=$(git diff --name-only --diff-filter=U)
  patch_files=$(git diff --name-only "$cur..$(git rev-parse HEAD)" 2>/dev/null || true)
  msg=$(git log -1 --format=%B REBASE_HEAD 2>/dev/null || printf '(无法读取)')

  cat <<PROMPT
你正处在一次 git rebase 的冲突现场：仓库中的个人 patch 正在从基点 ${cur}
搬到 ${new}。请解决冲突，使 patch 的原始意图在新基点上继续成立。

正在被应用的 patch，其提交说明如下（它解释了每处改动的原因，是关键上下文）：

${msg}

冲突文件：
${conflicts}

该 patch 原本触及的文件：
${patch_files}

请按以下顺序工作：

1. 先判定冲突成因属于哪一类：
   (a) 上游改动与 patch 落在同一处代码；
   (b) 上游变更了别处的 API/签名，patch 必须跟着适配。
   用 \`git log -p ${cur}..${new}\` 查阅区间内的上游改动来判断。
2. 若属于 (b)，必须检查该 patch 触及的所有文件以及相关调用点，
   不要只改冲突文件。
3. 解决冲突，删除全部冲突标记。
4. 自行运行 \`go build -tags "\$(cat release/DEFAULT_BUILD_TAGS)" ./cmd/sing-box\`
   与 \`go test ./...\` 验证，直到通过。
5. 最后用中文简述你的判断与改动理由。不要执行任何 git commit 或 git rebase 命令。
PROMPT
}

gate_markers() {
  log "闸门①：冲突标记扫描"
  # assert_no_markers 命中标记时会调用 die（内部直接 exit），
  # 必须包一层子 shell，否则会连带炸穿本脚本，
  # 让 resolve_conflicts 里紧随其后的 ORIG_HEAD 回退永远执行不到。
  ( assert_no_markers )
}

gate_build() {
  [[ -z "${SKIP_GO_GATES:-}" ]] || { log "闸门②：已跳过"; return 0; }
  log "闸门②：go build"
  go build -tags "$(cat release/DEFAULT_BUILD_TAGS)" ./cmd/sing-box
}

gate_test() {
  [[ -z "${SKIP_GO_GATES:-}" ]] || { log "闸门③：已跳过"; return 0; }
  log "闸门③：go test（根模块，不含需要 Docker 的 test/ 子模块）"
  go test ./...
}

# newly_touched <new_base> <prev_target> <cur_base>
# 相对上一版 patch 新触及的文件。仅作报告，不作闸门 —— 硬性限制文件集会误杀
# 「上游 API 变更导致 patch 必须适配新文件」这类合法解法。
# 调用方（review-pr.sh 的 pr_body）保证 prev_target 非空；该基点尚无上一版时
# 它根本不会调用本函数。
newly_touched() {
  local new_base=$1 prev_target=$2 cur_base=$3
  comm -13 \
    <(git diff --name-only "$cur_base..$prev_target" | sort) \
    <(git diff --name-only "$new_base..HEAD"        | sort)
}

# resolve_conflicts <cur_base> <new_base>
resolve_conflicts() {
  local cur=$1 new=$2 guard=0
  while [[ -d "$(git rev-parse --git-path rebase-merge)" ]]; do
    (( ++guard <= 50 )) || { git rebase --abort; die "冲突轮次超过 50，放弃"; }

    # prompt 走 stdin：--allowedTools 一类的变长参数会吞掉后面的位置参数，
    # 从管道喂入可以完全绕开这个坑。
    if ! build_prompt "$cur" "$new" \
         | claude -p --permission-mode auto >> "$RESOLVE_LOG"; then
      git rebase --abort
      log "claude 调用失败"
      return 1
    fi

    git add -A
    if ! GIT_EDITOR=true git rebase --continue; then
      git rebase --abort
      log "rebase --continue 失败"
      return 1
    fi
  done

  if ! gate_markers || ! gate_build || ! gate_test; then
    # 闸门跑在 rebase 收尾之后，此时已不在 rebase 现场，abort 无从谈起。
    # git rebase 在开始前会写 ORIG_HEAD，直接回到那里即可。
    log "闸门未通过，回退到 ORIG_HEAD"
    git reset --hard ORIG_HEAD
    return 1
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resolve_conflicts "$@"
fi
```

> 注意两条回退路径的区别：`claude` 或 `rebase --continue` 失败时仍处在 rebase
> 现场，用 `git rebase --abort`；闸门失败时 rebase 已收尾，用 `git reset --hard ORIG_HEAD`
> （`git rebase` 开始前会写入该引用）。

- [ ] **Step 4: 运行测试确认通过**

```bash
bash tests/run.sh
```

Expected: `test_resolve.sh` 全部 ok。若「标记残留被拦截」用例失败，检查
`gate_markers` 失败后的回退是否真的让 `moonfruit` 回到 `v1.0-reF1nd`。

- [ ] **Step 5: shellcheck 通过并提交**

```bash
shellcheck scripts/*.sh tests/*.sh tests/stubs/*
git add scripts/resolve.sh tests/
git commit -m "Let claude attempt the conflict, behind three gates

Hand it the live rebase worktree rather than a slice of context. A conflict
is not always a same-lines collision: an upstream signature change can force
the patch to adapt in a file that never conflicted, and no pre-selected
excerpt would reveal that.

The file-set check is a report, not a gate, for the same reason — it would
reject exactly those resolutions. Compilation and tests carry the objective
weight, and nothing reaches a release without a human comment either way."
```

---

### Task 6: 审查 PR 的创建

**Files:**
- Create: `scripts/review-pr.sh`
- Test: `tests/test_review_pr.sh`

**Interfaces:**
- Consumes: `lib.sh`、`resolve.sh` 的 `newly_touched`
- Produces:
  - `pr_body <cur_base> <new_base> <prev_target> <target> <resolution-log> -> markdown`
  - `create_review_pr <new_base> <target>`：推 `base/<target>` 与 `auto/resolve-<target>`，开 PR，输出 PR URL

- [ ] **Step 1: 写失败的测试**

`tests/test_review_pr.sh`：

```bash
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
```

- [ ] **Step 2: 运行测试确认失败**

```bash
bash tests/run.sh
```

Expected: FAIL，报 `scripts/review-pr.sh` 不存在。

- [ ] **Step 3: 写最小实现**

`scripts/review-pr.sh`：

```bash
#!/usr/bin/env bash
# 把 claude 的解决结果做成一个可审查的 PR。
#
# base 分支只是指向 reF1nd tag commit 的一条光秃秃的分支 —— 存在的唯一理由是
# PR 的 base 必须是分支而不能是 tag。因为 GitHub 的 Files changed 用三点 diff
# （merge-base 即该 tag），PR 的 diff 恰好等于 patch 栈本身。
set -euo pipefail

PR_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$PR_DIR/lib.sh"
# shellcheck source=scripts/resolve.sh
. "$PR_DIR/resolve.sh"

# pr_body <cur_base> <new_base> <prev_target> <target> <resolution-log>
pr_body() {
  local cur=$1 new=$2 prev=$3 target=$4 logfile=$5
  local rangediff newfiles
  if [[ -n "$prev" ]]; then
    rangediff=$(git range-diff "$cur..$prev" "$new..HEAD" 2>&1 || true)
    newfiles=$(newly_touched "$new" "$prev" "$cur" || true)
  else
    rangediff='（该基点下没有上一版 patch，无从比较）'
    newfiles=
  fi

  cat <<BODY
自动解决 rebase 冲突的结果，等待审查。

**基点变更：** \`${cur}\` → \`${new}\`
**目标 tag：** \`${target}\`

### 本次解决相对上一版新触及的文件

${newfiles:-（无）}

### claude 的解决说明

$(cat "$logfile")

### range-diff（patch 相对上一版的变化）

\`\`\`
${rangediff}
\`\`\`

---

**放行：** 在本 PR 内评论 \`/ship\`。CI 会把 \`moonfruit\` 指向本 PR 的 head、
打 tag \`${target}\`、走完构建发布，并清理临时分支。

**不满意就别评论。** 本地自行解决：

\`\`\`bash
git fetch origin --tags && git fetch ref1nd --tags
git rebase --onto ${new} ${cur} moonfruit
git push -f origin moonfruit
\`\`\`

解决后手动 dispatch \`release.yml\` 即可 —— detect 会发现基点已匹配，跳过 rebase。
BODY
}

# create_review_pr <new_base> <target>；其余上下文由环境变量传入
create_review_pr() {
  local new=$1 target=$2
  local base_branch="base/${target}" auto_branch="auto/resolve-${target}"

  git push -f origin "${new}^{commit}:refs/heads/${base_branch}"
  git push -f origin "HEAD:refs/heads/${auto_branch}"

  local body; body=$(mktemp)
  # RESOLVE_LOG 的默认值由 resolve.sh 在被 source 时确定（工作树之外），此处直接沿用
  pr_body "${CUR_BASE:?}" "$new" "${PREV_TARGET:-}" "$target" "$RESOLVE_LOG" > "$body"
  gh pr create --base "$base_branch" --head "$auto_branch" \
    --title "自动解决冲突：${target}" --body-file "$body"
  rm -f "$body"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  create_review_pr "$@"
fi
```

- [ ] **Step 4: 运行测试确认通过**

```bash
bash tests/run.sh
```

Expected: `test_review_pr.sh` 全部 ok。

- [ ] **Step 5: shellcheck 通过并提交**

```bash
shellcheck scripts/*.sh tests/*.sh
git add scripts/review-pr.sh tests/
git commit -m "Open the resolution as a reviewable PR

Point the PR at a throwaway branch on the reF1nd tag. GitHub diffs a PR
from its merge base, so with the tag as base the Files changed view is
exactly the patch stack and nothing else — the noise of an entire upstream
release never enters the review."
```

---

### Task 7: Homebrew tap 更新

**Files:**
- Create: `scripts/tap-bump.sh`
- Create: `tests/stubs/brew`
- Test: `tests/test_tap_bump.sh`

**Interfaces:**
- Consumes: `lib.sh`
- Produces:
  - `tap_bump <target-tag>`：调用 `brew bump-formula-pr`，随后给新 PR 打 `pr-pull` 标签，输出 PR URL

- [ ] **Step 1: 写失败的测试**

`tests/stubs/brew`（须 `chmod +x`）：

```bash
#!/usr/bin/env bash
# brew 的测试替身：把参数记到 $BREW_STUB_LOG。
set -euo pipefail
printf 'BREW %s\n' "$*" >> "${BREW_STUB_LOG:?}"
```

`tests/test_tap_bump.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/assert.sh"
. "$HERE/../scripts/lib.sh"
. "$HERE/../scripts/tap-bump.sh"

PATH="$HERE/stubs:$PATH"
BREW_STUB_LOG=$(mktemp); export BREW_STUB_LOG
# 测试自带凭据：tap_bump 用 ${HOMEBREW_GITHUB_API_TOKEN:?} 断言其存在，
# 不自带就只在开发机恰好导出了真实 PAT 时才通过。值无所谓，brew 与 gh 都是 stub。
export HOMEBREW_GITHUB_API_TOKEN=stub-token
GH_STUB_LOG=$(mktemp); export GH_STUB_LOG

out=$(tap_bump v1.14.0-beta.5-reF1nd-moonfruit)
logged=$(cat "$BREW_STUB_LOG")
gh_logged=$(cat "$GH_STUB_LOG")

assert_contains "$logged" "bump-formula-pr"                             "调用 bump-formula-pr"
assert_contains "$logged" "--version=1.14.0-beta.5-reF1nd-moonfruit"    "版本号去掉了前导 v"
assert_contains "$logged" "moonfruit/tap/sing-box-ref1nd"               "目标 formula 正确"
assert_contains "$logged" "--no-browse"                                 "不打开浏览器"

# 打标签这一步是 tap 构建 bottle 的触发器。这里对 pr edit 那一行做整行精确匹配，
# 而不是在整块日志上做子串匹配：子串匹配挡不住把标签写成 pr-pulled，也挡不住
# 漏掉 pr edit 的 --repo（因为 pr list 那行本来就带着一个正确的 --repo）。
assert_eq "$(grep '^GH pr edit' "$GH_STUB_LOG")" \
          "GH pr edit 42 --repo moonfruit/homebrew-tap --add-label pr-pull" \
          "打标签的调用与预期逐字相符"
assert_contains "$out" "tap_pr=https://github.com/moonfruit/homebrew-tap/pull/42" \
                                                             "输出 tap PR 链接"

rm -f "$BREW_STUB_LOG" "$GH_STUB_LOG"
```

同时在 `tests/stubs/gh` 的 `case` 中追加 `pr` 分支（`api` 与 `issue` 分支保持不变），
让 `pr list` 返回一个 PR 号、`pr edit` 直接成功：

```bash
  pr)
    printf 'GH %s\n' "$*" >> "${GH_STUB_LOG:?}"
    if [[ "${2:-}" == list ]]; then printf '42\n'; fi
    ;;
```

`pr edit` 必须记日志而不能是空操作：`pr-pull` 标签是触发 tap 构建 bottle 的开关，
掉了的话故障形态是「版本发布了但 formula 永远没 bottle」，静默且难查，必须有断言守着。

- [ ] **Step 2: 运行测试确认失败**

```bash
chmod +x tests/stubs/brew
bash tests/run.sh
```

Expected: FAIL，报 `scripts/tap-bump.sh` 不存在。

- [ ] **Step 3: 写最小实现**

`scripts/tap-bump.sh`：

```bash
#!/usr/bin/env bash
# 更新 moonfruit/homebrew-tap 的 sing-box-ref1nd。
# 只传 --version 就够：brew 用新版本串替换 formula 中 url 里的旧版本串，
# 再自行下载计算 sha256。前提是 url 内含完整版本串，本方案的
# .../tags/v${version}.tar.gz 满足。
set -euo pipefail

TAP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$TAP_DIR/lib.sh"

TAP_FORMULA=${TAP_FORMULA:-moonfruit/tap/sing-box-ref1nd}
TAP_REPO=${TAP_REPO:-moonfruit/homebrew-tap}

# tap_bump <target-tag>
tap_bump() {
  local target=$1 version=${1#v} num

  brew bump-formula-pr --version="$version" --no-audit --no-browse "$TAP_FORMULA"

  num=$(GH_TOKEN="${HOMEBREW_GITHUB_API_TOKEN:?}" \
        gh pr list --repo "$TAP_REPO" --state open \
          --search "$version in:title" --json number --jq '.[0].number // empty')
  [[ -n "$num" ]] || die "未找到 ${TAP_REPO} 中版本 ${version} 的 PR"

  GH_TOKEN="${HOMEBREW_GITHUB_API_TOKEN}" \
    gh pr edit "$num" --repo "$TAP_REPO" --add-label pr-pull

  log "已开 tap PR #${num} 并打上 pr-pull，目标 ${target}"
  emit tap_pr "https://github.com/${TAP_REPO}/pull/${num}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then tap_bump "$@"; fi
```

- [ ] **Step 4: 运行测试确认通过**

```bash
bash tests/run.sh
```

Expected: `test_tap_bump.sh` 全部 ok。

- [ ] **Step 5: shellcheck 通过并提交**

```bash
shellcheck scripts/*.sh tests/*.sh tests/stubs/*
git add scripts/tap-bump.sh tests/
git commit -m "Bump the tap formula from the released tag

Pass only --version and let brew rewrite the url and fetch the checksum
itself; the url embeds the full version string, so the substitution is
exact and we never carry a second copy of the sha256."
```

---

### Task 8: workflow 骨架（detect / rebase / ship 短路）

**Files:**
- Create: `.github/workflows/release.yml`
- Modify: `tests/run.sh`（追加 actionlint 检查）

**Interfaces:**
- Consumes: Task 1–7 的全部脚本
- Produces:
  - job `detect`，outputs：`should_build`、`base`、`cur_base`、`target`、`prev_target`、`ship_ref`
  - job `prepare`，outputs：`sha`（`moonfruit` 的新 tip）

- [ ] **Step 1: 写 workflow 骨架**

`.github/workflows/release.yml`：

```yaml
name: Release

on:
  schedule:
    - cron: "0 4 * * *"
  workflow_dispatch:
    inputs:
      base_tag:
        description: "指定 reF1nd 基点 tag，留空则自动检测"
        required: false
        type: string
      force:
        description: "目标 tag 已存在时仍重建"
        required: false
        type: boolean
        default: false
      resolve_ref:
        description: "人工放行冲突解决分支，形如 auto/resolve-<TARGET>"
        required: false
        type: string
  issue_comment:
    types: [created]

permissions:
  contents: write
  issues: write
  pull-requests: write

env:
  UPSTREAM_REPO: reF1nd/sing-box
  INTEGRATION_BRANCH: moonfruit
  GO_VERSION: "~1.25.9"

concurrency:
  group: release
  cancel-in-progress: false

jobs:
  detect:
    name: 检测基点
    runs-on: ubuntu-latest
    # issue_comment 会为仓库内任意评论创建 run，这里立即短路。
    if: >-
      github.event_name != 'issue_comment' || (
        github.event.issue.pull_request != null &&
        github.event.comment.author_association == 'OWNER' &&
        startsWith(github.event.comment.body, '/ship')
      )
    outputs:
      should_build: ${{ steps.decide.outputs.should_build }}
      base:         ${{ steps.decide.outputs.base }}
      cur_base:     ${{ steps.decide.outputs.cur_base }}
      target:       ${{ steps.decide.outputs.target }}
      prev_target:  ${{ steps.decide.outputs.prev_target }}
      ship_ref:     ${{ steps.ship.outputs.ship_ref }}
    steps:
      - name: 取出自动化分支
        uses: actions/checkout@v5
        with: { ref: ci, path: ci }

      - name: 取出完整仓库
        uses: actions/checkout@v5
        with: { fetch-depth: 0, path: src }

      - name: 拉取 reF1nd 的 tag 并落地集成分支
        working-directory: src
        run: |
          set -euo pipefail
          git remote add ref1nd "https://github.com/${UPSTREAM_REPO}.git"
          git fetch --tags --quiet ref1nd
          # actions/checkout 只建立 origin/* 远端引用；detect.sh 要对
          # $INTEGRATION_BRANCH 跑 git describe / rev-parse，需要本地分支存在。
          git branch -f "$INTEGRATION_BRANCH" "origin/$INTEGRATION_BRANCH"

      - name: 解析放行目标
        id: ship
        # 两条放行路径：PR 内评论 /ship（常规），或 dispatch 时直接给出分支名（逃生口）。
        if: github.event_name == 'issue_comment' || inputs.resolve_ref != ''
        env:
          GH_TOKEN:  ${{ github.token }}
          PR:        ${{ github.event.issue.number }}
          INPUT_REF: ${{ inputs.resolve_ref }}
        run: |
          set -euo pipefail
          if [[ -n "${INPUT_REF:-}" ]]; then
            ref="$INPUT_REF"
          else
            ref=$(gh pr view "$PR" --json headRefName --jq .headRefName)
          fi
          # 两条路径都必须过分支名校验，否则 dispatch 就成了绕过审查的后门
          case "$ref" in
            auto/resolve-*) ;;
            *) echo "::error::${ref} 不是冲突解决分支" >&2; exit 1 ;;
          esac
          echo "ship_ref=${ref}" >> "$GITHUB_OUTPUT"

      - name: 判定
        id: decide
        working-directory: src
        env:
          GH_TOKEN:  ${{ github.token }}
          BASE_TAG:  ${{ inputs.base_tag }}
          FORCE:     ${{ inputs.force }}
          SHIP_REF:  ${{ steps.ship.outputs.ship_ref }}
        run: |
          set -euo pipefail
          if [[ -n "${SHIP_REF:-}" ]]; then
            # 放行路径：目标 tag 直接从分支名反推，无需检测上游
            target="${SHIP_REF#auto/resolve-}"
            . ../ci/scripts/version.sh
            {
              echo "should_build=true"
              echo "base=$(base_of "$target")"
              echo "cur_base=$(base_of "$target")"
              echo "target=${target}"
              echo "prev_target="
            } >> "$GITHUB_OUTPUT"
          else
            bash ../ci/scripts/detect.sh
          fi
```

- [ ] **Step 2: 加入 actionlint 检查**

在 `tests/run.sh` 中、**汇总消息那一行之前**插入（必须在它之前：否则 actionlint
失败时会先打印「全部通过」再报错，读日志的人会被误导）：

```bash
if command -v actionlint >/dev/null 2>&1; then
  printf '\nactionlint\n'
  actionlint || rc=1
else
  printf '\nactionlint 未安装，跳过（brew install actionlint）\n'
fi
```

即最终顺序为：逐个 shell 套件 → actionlint → `测试失败`/`全部通过` → `exit "$rc"`。

- [ ] **Step 3: 运行校验**

```bash
brew install actionlint
bash tests/run.sh
```

Expected: 脚本测试全部通过，actionlint 无输出。

- [ ] **Step 4: 加入 prepare job（rebase 或放行）**

在 `release.yml` 的 `jobs:` 下追加：

```yaml
  prepare:
    name: 准备集成分支
    needs: detect
    if: needs.detect.outputs.should_build == 'true'
    runs-on: ubuntu-latest
    outputs:
      sha: ${{ steps.run.outputs.sha }}
      # prepare 自己已经发过专属通知的路径，notify-failure 据此避让
      notified: ${{ steps.review.outputs.notified || steps.conflict.outputs.notified }}
    steps:
      - uses: actions/checkout@v5
        with: { ref: ci, path: ci }
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0
          path: src
          # 集成分支与冲突路径的临时分支都带着上游的 .github/workflows/，
          # 而 GITHUB_TOKEN 是 App 令牌、被 GitHub 禁止创建或修改 workflow 文件，
          # 且没有任何 permissions: 键能授予该能力。必须用带 workflow scope 的 PAT。
          token: ${{ secrets.GH_PAT }}
      - uses: actions/setup-go@v5
        with: { go-version: "${{ env.GO_VERSION }}" }

      - name: 配置 git 身份并拉取 reF1nd tag
        working-directory: src
        run: |
          set -euo pipefail
          git config user.name  'github-actions[bot]'
          git config user.email 'github-actions[bot]@users.noreply.github.com'
          git remote add ref1nd "https://github.com/${UPSTREAM_REPO}.git"
          git fetch --tags --quiet ref1nd
          git checkout -q -B "$INTEGRATION_BRANCH" "origin/$INTEGRATION_BRANCH"

      - name: 放行冲突解决分支
        id: ship
        if: needs.detect.outputs.ship_ref != ''
        working-directory: src
        run: |
          set -euo pipefail
          git fetch -q origin "${{ needs.detect.outputs.ship_ref }}"
          git reset --hard FETCH_HEAD

      - name: rebase 到新基点
        id: rebase
        if: needs.detect.outputs.ship_ref == ''
        working-directory: src
        continue-on-error: true
        run: bash ../ci/scripts/rebase.sh "${{ needs.detect.outputs.base }}" "$INTEGRATION_BRANCH"

      - name: 自动解决冲突
        id: resolve
        if: steps.rebase.outcome == 'failure'
        working-directory: src
        continue-on-error: true
        env:
          CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
        run: |
          set -euo pipefail
          npm install -g @anthropic-ai/claude-code
          bash ../ci/scripts/resolve.sh \
            "${{ needs.detect.outputs.cur_base }}" "${{ needs.detect.outputs.base }}"

      - name: 开审查 PR
        id: review
        if: steps.rebase.outcome == 'failure' && steps.resolve.outcome == 'success'
        working-directory: src
        env:
          GH_TOKEN:     ${{ github.token }}
          BARK_URL:     ${{ secrets.BARK_URL }}
          CUR_BASE:     ${{ needs.detect.outputs.cur_base }}
          PREV_TARGET:  ${{ needs.detect.outputs.prev_target }}
        run: |
          set -euo pipefail
          . ../ci/scripts/notify.sh
          url=$(bash ../ci/scripts/review-pr.sh \
                  "${{ needs.detect.outputs.base }}" "${{ needs.detect.outputs.target }}")
          bark "冲突已自动解决，待审查" \
               "${{ needs.detect.outputs.target }}：在 PR 内评论 /ship 放行" "$url"
          echo "notified=review-pr" >> "$GITHUB_OUTPUT"

      # 中止单独成步：上一步必须成功结束，notified 这个 output 才会被记录下来，
      # notify-failure 才能据此把「有意中止」与「真失败」区分开。
      - name: 已开审查 PR，中止本次发布
        if: steps.review.outcome == 'success'
        run: exit 1

      - name: 冲突未能自动解决
        id: conflict
        if: steps.rebase.outcome == 'failure' && steps.resolve.outcome == 'failure'
        working-directory: src
        env:
          GH_TOKEN: ${{ github.token }}
          BARK_URL: ${{ secrets.BARK_URL }}
        run: |
          set -euo pipefail
          . ../ci/scripts/notify.sh
          body=$(mktemp)
          cat > "$body" <<EOF
          rebase \`${{ needs.detect.outputs.cur_base }}\` → \`${{ needs.detect.outputs.base }}\` 冲突，自动解决未通过。

          本地接管：

          \`\`\`bash
          git fetch origin --tags && git fetch ref1nd --tags
          git rebase --onto ${{ needs.detect.outputs.base }} ${{ needs.detect.outputs.cur_base }} moonfruit
          git push -f origin moonfruit
          \`\`\`

          Actions run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          EOF
          open_or_comment_issue "${{ needs.detect.outputs.target }}" "$body"
          bark "rebase 冲突待人工处理" "${{ needs.detect.outputs.target }}" \
               "${{ github.server_url }}/${{ github.repository }}/issues"
          echo "notified=conflict" >> "$GITHUB_OUTPUT"

      # 同样把中止拆出来，理由与上面那条一致
      - name: 冲突已通知，中止本次发布
        if: steps.conflict.outcome == 'success'
        run: exit 1

      - name: 推送集成分支与 tag
        id: run
        working-directory: src
        env:
          BARK_URL: ${{ secrets.BARK_URL }}
        run: |
          set -euo pipefail
          . ../ci/scripts/rebase.sh
          assert_no_markers
          target='${{ needs.detect.outputs.target }}'
          git push -f origin "HEAD:refs/heads/${INTEGRATION_BRANCH}"
          git tag "$target"
          git push origin "refs/tags/${target}"
          echo "sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
          . ../ci/scripts/notify.sh
          bark "已打 tag ${target}" \
               "基点 ${{ needs.detect.outputs.base }}；$(git log --oneline "${{ needs.detect.outputs.base }}..HEAD" | wc -l | tr -d ' ') 个 patch" \
               "${{ github.server_url }}/${{ github.repository }}/releases/tag/${target}"
```

- [ ] **Step 5: 校验并提交**

```bash
bash tests/run.sh
git add .github/workflows/release.yml tests/run.sh
git commit -m "Wire detect and prepare into a workflow

Trigger shipping from an issue_comment: that event reads its workflow file
from the default branch, so the review PR's base branch needs no workflow
commit of its own and no PAT to cross from one workflow to another. A label
on the PR would have required both, because pull_request events read the
merge ref instead.

The first job short-circuits on every unrelated comment in the repository."
```

---

### Task 9: 构建矩阵迁移

**Files:**
- Modify: `.github/workflows/release.yml`（追加 `build` job）
- Reference: `/Users/moon/Workspace.localized/proxy/sing-box-release/.github/workflows/build.yml` 的 `build` job

**Interfaces:**
- Consumes: `prepare` job 的 `sha`；`detect` job 的 `target`
- Produces: artifact `binary-linux_arm64-{purego,glibc,musl}`，各含 `sing-box-<version>-linux-arm64[-glibc|-musl].tar.gz`

- [ ] **Step 1: 追加 build job**

在 `release.yml` 中追加。逻辑与 `sing-box-release` 的 build job 完全一致，仅
checkout 目标改为本仓库的 tag：

```yaml
  build:
    name: 构建 ${{ matrix.variant }}
    needs: [detect, prepare]
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        variant: [purego, glibc, musl]
    steps:
      - uses: actions/checkout@v5
        with:
          ref: ${{ needs.detect.outputs.target }}
          fetch-depth: 0
      - uses: actions/setup-go@v5
        with: { go-version: "${{ env.GO_VERSION }}" }

      - name: 组装 build tags
        env:
          TARGET: ${{ needs.detect.outputs.target }}
        run: |
          set -xeuo pipefail
          TAGS=$(cat release/DEFAULT_BUILD_TAGS)
          case "${{ matrix.variant }}" in
            purego) TAGS="${TAGS},with_purego" ;;
            musl)   TAGS="${TAGS},with_musl" ;;
          esac
          {
            echo "BUILD_TAGS=${TAGS}"
            echo "LDFLAGS_SHARED=$(cat release/LDFLAGS)"
            echo "VERSION=${TARGET#v}"
          } >> "$GITHUB_ENV"

      - name: 克隆 cronet-go
        run: |
          set -xeuo pipefail
          CRONET_GO_VERSION=$(cat .github/CRONET_GO_VERSION)
          git init ~/cronet-go
          git -C ~/cronet-go remote add origin https://github.com/sagernet/cronet-go.git
          git -C ~/cronet-go fetch --depth=1 origin "$CRONET_GO_VERSION"
          git -C ~/cronet-go checkout FETCH_HEAD
          git -C ~/cronet-go submodule update --init --recursive --depth=1

      - name: 重建 Debian keyring
        run: |
          set -xeuo pipefail
          rm -f ~/cronet-go/naiveproxy/src/build/linux/sysroot_scripts/keyring.gpg
          cd ~/cronet-go
          GPG_TTY=/dev/null ./naiveproxy/src/build/linux/sysroot_scripts/generate_keyring.sh

      - name: 缓存 Chromium 工具链
        uses: actions/cache@v4
        with:
          path: |
            ~/cronet-go/naiveproxy/src/third_party/llvm-build/
            ~/cronet-go/naiveproxy/src/gn/out/
            ~/cronet-go/naiveproxy/src/chrome/build/pgo_profiles/
            ~/cronet-go/naiveproxy/src/out/sysroot-build/
          key: chromium-toolchain-arm64-${{ matrix.variant }}-${{ hashFiles('.github/CRONET_GO_VERSION') }}

      - name: 下载工具链并注入环境
        run: |
          set -xeuo pipefail
          cd ~/cronet-go
          libc=()
          [[ "${{ matrix.variant }}" == musl ]] && libc=(--libc=musl)
          go run ./cmd/build-naive --target=linux/arm64 "${libc[@]}" download-toolchain
          go run ./cmd/build-naive --target=linux/arm64 "${libc[@]}" env >> "$GITHUB_ENV"

      - name: 构建
        env:
          GOOS: linux
          GOARCH: arm64
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -xeuo pipefail
          if [[ "${{ matrix.variant }}" == purego ]]; then export CGO_ENABLED=0; else export CGO_ENABLED=1; fi
          mkdir -p dist
          go build -v -trimpath -o dist/sing-box -tags "${BUILD_TAGS}" \
            -ldflags "-X 'github.com/sagernet/sing-box/constant.Version=${VERSION}' ${LDFLAGS_SHARED} -s -w -buildid=" \
            ./cmd/sing-box

      - name: 提取 libcronet.so
        if: matrix.variant == 'purego'
        run: |
          set -xeuo pipefail
          cd ~/cronet-go
          CGO_ENABLED=0 go run -v ./cmd/build-naive extract-lib --target linux/arm64 -o "$GITHUB_WORKSPACE/dist"

      - name: 打包
        run: |
          set -xeuo pipefail
          DIR_NAME="sing-box-${VERSION}-linux-arm64"
          case "${{ matrix.variant }}" in
            glibc) DIR_NAME="${DIR_NAME}-glibc" ;;
            musl)  DIR_NAME="${DIR_NAME}-musl" ;;
          esac
          cd dist
          mkdir -p "$DIR_NAME"
          cp ../LICENSE sing-box "$DIR_NAME"
          [ -f libcronet.so ] && cp libcronet.so "$DIR_NAME"
          tar -czvf "${DIR_NAME}.tar.gz" "$DIR_NAME"
          rm -r "$DIR_NAME" sing-box
          rm -f libcronet.so

      - uses: actions/upload-artifact@v4
        with:
          name: binary-linux_arm64-${{ matrix.variant }}
          path: dist
          if-no-files-found: error
          retention-days: 7
```

- [ ] **Step 2: 校验**

```bash
bash tests/run.sh
```

Expected: actionlint 无输出。若报 `set -e` 与 `[ -f libcronet.so ] && cp ...`
在末行返回非 0 的问题，把该行改为 `if [ -f libcronet.so ]; then cp libcronet.so "$DIR_NAME"; fi`。

- [ ] **Step 3: 提交**

```bash
git add .github/workflows/release.yml
git commit -m "Port the linux-arm64 build matrix into the fork

Same three variants and the same cronet toolchain cache as sing-box-release
used; only the checkout target changes, from reF1nd's tag to the moonfruit
tag this workflow just created."
```

---

### Task 10: 发布、Gitee 推送、tap 更新接线

**Files:**
- Modify: `.github/workflows/release.yml`（追加 `release`、`gitee-push`、`tap-bump`、`notify-failure` 四个 job）

**Interfaces:**
- Consumes: `build` 的 artifact；`detect` 的 `target`/`base`
- Produces: GitHub Release、Gitee `binary` 分支、tap PR

- [ ] **Step 1: 追加 release job**

```yaml
  release:
    name: 发布
    needs: [detect, prepare, build]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with: { fetch-depth: 0 }
      - uses: actions/download-artifact@v5
        with: { path: dist, merge-multiple: true }
      - name: 创建 Release
        env:
          GH_TOKEN: ${{ github.token }}
          TARGET:   ${{ needs.detect.outputs.target }}
          BASE:     ${{ needs.detect.outputs.base }}
        run: |
          set -euo pipefail
          # $BASE 是 reF1nd 的 tag，从未推到本仓库；不取回它，下面的 git log 区间
          # 无法解析，整个 release job 会在生成 notes 时就挂掉。
          git remote add ref1nd "https://github.com/${UPSTREAM_REPO}.git"
          git fetch --tags --quiet ref1nd
          notes=$(mktemp)
          {
            printf '基于 [`%s`](https://github.com/%s/releases/tag/%s) 构建。\n\n' \
              "$BASE" "$UPSTREAM_REPO" "$BASE"
            printf '本版包含的 patch：\n\n'
            git log --format='- %s' "${BASE}..${TARGET}"
          } > "$notes"
          gh release create "$TARGET" --title "$TARGET" --notes-file "$notes" dist/*.tar.gz
```

- [ ] **Step 2: 追加 gitee-push job**

逻辑与 `sing-box-release` 一致；不设 `gitee_force_push` 输入，补救靠 GitHub
原生的 Re-run failed jobs（本 job 从 Release 下载，不依赖 build 的 artifact）：

```yaml
  gitee-push:
    name: 推送 Gitee
    needs: [detect, release]
    runs-on: ubuntu-latest
    steps:
      - name: 下载 musl 产物
        env:
          GH_TOKEN: ${{ github.token }}
          TARGET:   ${{ needs.detect.outputs.target }}
        run: |
          set -euo pipefail
          mkdir -p dist
          gh release download "$TARGET" --pattern '*linux-arm64-musl.tar.gz' --dir dist
      - name: 强推 binary 分支
        env:
          GITEE_USER:  ${{ secrets.GITEE_USER }}
          GITEE_TOKEN: ${{ secrets.GITEE_TOKEN }}
          TARGET:      ${{ needs.detect.outputs.target }}
        run: |
          set -euo pipefail
          test -n "$GITEE_USER"  || { echo "::error::GITEE_USER 缺失" >&2; exit 1; }
          test -n "$GITEE_TOKEN" || { echo "::error::GITEE_TOKEN 缺失" >&2; exit 1; }
          work=$(mktemp -d)
          cp dist/sing-box-*-linux-arm64-musl.tar.gz "$work/"
          printf '%s\n' "${TARGET#v}" > "$work/version.txt"
          cd "$work"
          git init -q -b binary
          git config user.name  'github-actions[bot]'
          git config user.email 'github-actions[bot]@users.noreply.github.com'
          git add .
          git commit -q -m "sing-box ${TARGET} linux-arm64-musl"
          git remote add gitee "https://${GITEE_USER}:${GITEE_TOKEN}@gitee.com/moonfruit/private.git"
          git push --progress --verbose -f gitee binary
```

- [ ] **Step 3: 追加 tap-bump job 与成功通知**

```yaml
  tap-bump:
    name: 更新 Homebrew tap
    needs: [detect, release]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with: { ref: ci }
      - name: 把 Homebrew 加入 PATH
        run: |
          set -euo pipefail
          # ubuntu 镜像自带 Homebrew，但默认不在 PATH 上 —— 首次真跑即因
          # `brew: command not found` 挂在这里，静态检查发现不了。
          brew_bin=/home/linuxbrew/.linuxbrew/bin
          [[ -x "$brew_bin/brew" ]] || { echo "::error::runner 上找不到 $brew_bin/brew" >&2; exit 1; }
          echo "$brew_bin" >> "$GITHUB_PATH"

      - name: bump 并打 pr-pull
        id: bump
        env:
          # brew 认这个环境变量名，值来自统一的 GH_PAT
          HOMEBREW_GITHUB_API_TOKEN: ${{ secrets.GH_PAT }}
          HOMEBREW_NO_AUTO_UPDATE: "1"
        run: |
          set -euo pipefail
          # bump-formula-pr 只认已 tap 的 formula，runner 上必须先 tap。
          brew tap moonfruit/tap
          bash scripts/tap-bump.sh "${{ needs.detect.outputs.target }}"
      - name: 完成通知
        env:
          BARK_URL: ${{ secrets.BARK_URL }}
          TARGET:   ${{ needs.detect.outputs.target }}
        run: |
          set -euo pipefail
          . scripts/notify.sh
          bark "${TARGET} 发布完成" "tap PR 已开并打上 pr-pull" "${{ steps.bump.outputs.tap_pr }}"
```

- [ ] **Step 4: 追加失败兜底通知**

```yaml
  notify-failure:
    name: 失败通知
    needs: [detect, prepare, build, release, gitee-push, tap-bump]
    # 只用 failure()，不叠加 should_build 守卫：无需构建又无失败时 failure() 本就
    # 不成立，那个守卫唯一的实际效果是吞掉 detect 自身崩溃时的通知 —— 而每日 cron
    # 悄无声息地停摆，恰恰是最该被告知的故障。
    #
    # 但要避开 prepare 里两条自带专属通知的路径（已开审查 PR、冲突待人工处理）：
    # 本 job 是「没有专属通知的故障」的兜底，重复响一次只会制造噪音，
    # 前者更会违反「开了 PR 就不再开 issue」。
    if: failure() && needs.prepare.outputs.notified == ''
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with: { ref: ci }
      - env:
          GH_TOKEN: ${{ github.token }}
          BARK_URL: ${{ secrets.BARK_URL }}
          # detect 崩溃时 target 为空，给个兜底文案，issue 标题才不会是半截
          TARGET:   ${{ needs.detect.outputs.target || '目标 tag 未能确定' }}
          RUN_URL:  ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
        run: |
          set -euo pipefail
          . scripts/notify.sh
          body=$(mktemp)
          printf '发布 `%s` 失败。\n\nActions run: %s\n' "$TARGET" "$RUN_URL" > "$body"
          open_or_comment_issue "$TARGET" "$body"
          bark "发布失败：${TARGET}" "见 Actions run" "$RUN_URL"
```

- [ ] **Step 5: 校验并提交**

```bash
bash tests/run.sh
```

Expected: actionlint 无输出。

```bash
git add .github/workflows/release.yml
git commit -m "Publish the release and drive both consumers

Drop the gitee_force_push input the old workflow carried: that job pulls
its tarball from the Release rather than from build artifacts, so GitHub's
own re-run-failed-jobs already covers the case it existed for."
```

---

### Task 11: 建立集成分支

**Files:**
- Create: `moonfruit` 分支（远端 `moonfruit/sing-box`）

**Interfaces:**
- Consumes: `fix-mdns-timeout` 分支的提交 `f1c8472d9`
- Produces: 远端分支 `moonfruit` = `v1.14.0-beta.5-reF1nd` + 一个 patch 提交

- [ ] **Step 1: 在临时 clone 中建立分支**

不要在 `ci` 工作目录里做，避免把源码带回工作树：

```bash
tmp=$(mktemp -d)
git clone -q https://github.com/moonfruit/sing-box.git "$tmp/sb"
cd "$tmp/sb"
git remote add ref1nd https://github.com/reF1nd/sing-box.git
git fetch --tags ref1nd
git checkout -b moonfruit v1.14.0-beta.5-reF1nd
git cherry-pick f1c8472d9
```

Expected: 报冲突，`dns/transport/mdns/mdns.go` 处于 `UU` 状态。

- [ ] **Step 2: 解决冲突**

```bash
git diff --diff-filter=U --name-only
git log -p 8a42af329..v1.14.0-beta.5-reF1nd -- dns/transport/mdns/mdns.go
```

按 patch 的提交说明（限制采集窗口、首答后 250ms 返回、`context.AfterFunc`
取消、无人应答时返回 NODATA + 合成 SOA、跳过点对点接口、汇总所有失败接口）
把两侧改动合并，删除全部冲突标记。

- [ ] **Step 3: 验证编译与测试**

```bash
git add dns/transport/mdns/mdns.go
git -c core.editor=true cherry-pick --continue
go build -tags "$(cat release/DEFAULT_BUILD_TAGS)" ./cmd/sing-box
go test ./dns/...
git grep -n '^<<<<<<< ' || echo "无冲突标记"
```

Expected: 编译通过，`dns` 包测试通过，无冲突标记。

- [ ] **Step 4: 推送**

```bash
git push -u origin moonfruit
cd - && rm -rf "$tmp"
```

- [ ] **Step 5: 交叉验证脚本能识别该分支**

```bash
tmp2=$(mktemp -d)
git clone -q --branch moonfruit https://github.com/moonfruit/sing-box.git "$tmp2/sb"
git -C "$tmp2/sb" remote add ref1nd https://github.com/reF1nd/sing-box.git
git -C "$tmp2/sb" fetch -q --tags ref1nd
( cd "$tmp2/sb" && . "$OLDPWD/scripts/rebase.sh" && current_base moonfruit )
rm -rf "$tmp2"
```

Expected: 输出 `v1.14.0-beta.5-reF1nd`。

---

### Task 12: 仓库设置与凭据

**Files:**
- 无（全部是 GitHub 网页操作与推送）

**Interfaces:**
- Consumes: Task 11 建立的 `moonfruit` 分支
- Produces: 可运行 workflow 的 fork

> **formula 的改造挪到 Task 13。** `brew bump-formula-pr` 是把新版本串替换进
> formula **现有**的 url，而现有 url 指向 reF1nd 仓库，首次 bump 会拼出
> `reF1nd/sing-box/archive/.../v…-moonfruit.tar.gz` —— 仓库错了。手改 formula 又
>需要首次发布产物的 sha256。因此顺序定为：先发一次，拿到真实 url 与 sha256 后
> 手改 formula 并自己发一次 PR，之后的版本才交给 CI 自动 bump。
>
> 代价：首次发布时 `tap-bump` job 会失败（url 404），并触发一次失败通知。这是
> 预期内的一次性现象，不必修。

- [ ] **Step 1: 配置 fork 的仓库设置**

在 https://github.com/moonfruit/sing-box 上：

1. Settings → Actions → General → 启用 Actions
2. Settings → General → Default branch → 改为 `ci`
3. Settings → General → Features → **勾选 Issues**（fork 默认关闭；`open_or_comment_issue`
   是冲突与构建失败的主要落地渠道，关着的话那条通知路径会直接失败）
4. Issues → Labels → 新建 `release-conflict`
4. Settings → Secrets and variables → Actions，添加：
   - `GH_PAT`：唯一的 GitHub PAT，classic 类型，勾选 `repo` + `workflow` 两个 scope。
     `workflow` 是必须的：集成分支带着上游的 `.github/workflows/`，没有该 scope 就推不上去
   - `GITEE_USER` / `GITEE_TOKEN`：从 `moonfruit/sing-box-release` 的 secrets 复制
   - `BARK_URL`：形如 `https://api.day.app/<key>`
   - `CLAUDE_CODE_OAUTH_TOKEN`：本地 `claude setup-token` 生成

- [ ] **Step 2: 验证版本序不倒退**

```bash
brew ruby -e '
require "version"
puts(Version.new("1.14.0-beta.5-reF1nd") <=> Version.new("1.14.0-beta.5-reF1nd-moonfruit"))
'
```

Expected: `-1`（已安装的版本更旧，`brew upgrade` 会正常升级）。

- [x] **Step 3: 推送两条分支**（已完成）

注意本地 checkout 的远端命名：`origin` 指向上游 SagerNet，fork 是 `moonfruit`。

```bash
cd /Users/moon/Workspace.localized/go/mod/sing-box
git push -u moonfruit refs/heads/ci:refs/heads/ci
git push -u moonfruit refs/heads/moonfruit:refs/heads/moonfruit
```

---

### Task 13: 端到端验证与退役

**Files:**
- Modify: `/opt/homebrew/Library/Taps/moonfruit/homebrew-tap/Formula/sing-box-ref1nd.rb`（填入真实 sha256）

**Interfaces:**
- Consumes: 前 12 个任务的全部产出
- Produces: 首个 `v1.14.0-beta.5-reF1nd-moonfruit` 发布，`sing-box-release` 归档

- [ ] **Step 1: 手动触发首次发布**

```bash
gh workflow run release.yml --repo moonfruit/sing-box -f force=true
gh run watch --repo moonfruit/sing-box
```

Expected: detect → prepare（跳过 rebase，因基点已匹配）→ build ×3 → release →
gitee-push + tap-bump 全绿。

- [ ] **Step 2: 核对发布产物**

```bash
gh release view v1.14.0-beta.5-reF1nd-moonfruit --repo moonfruit/sing-box
```

Expected: 三个 tarball（purego / glibc / musl），notes 中列出基点链接与 patch 清单。

- [ ] **Step 3: 核对 Bark 通知**

Expected: 收到两条 —— 「已打 tag」与「发布完成」。

- [ ] **Step 4: 手改 formula 并自己发一次 PR**

首次发布时 `tap-bump` job 预期失败（现有 url 指向 reF1nd 仓库），忽略它。
拿真实产物改 formula：

```bash
TARGET=v1.14.0-beta.5-reF1nd-moonfruit
URL="https://github.com/moonfruit/sing-box/archive/refs/tags/${TARGET}.tar.gz"
curl -fsSL "$URL" | shasum -a 256
```

把下列字段改到位（formula 名与 class 名**不改**，改名会破坏已安装环境；
`install` / `test` / `service` / `bottle root_url` 全部不动）：

```ruby
  homepage "https://github.com/moonfruit/sing-box"
  url "https://github.com/moonfruit/sing-box/archive/refs/tags/v1.14.0-beta.5-reF1nd-moonfruit.tar.gz"
  version "1.14.0-beta.5-reF1nd-moonfruit"
  sha256 "<上一步算出的值>"
  license "GPL-3.0-or-later"
  head "https://github.com/moonfruit/sing-box.git", branch: "moonfruit"

  livecheck do
    url :stable
    regex(/^v(\d(?:\.\d+)+(-\w+(?:\.\d+)?)?-reF1nd(?:\.\d+)?-moonfruit(?:\.\d+)?)$/i)
  end
```

清空 `bottle do` 块，`brew style` 通过后按 tap 的常规流程发 PR 并打 `pr-pull`
（即现有的 `/publish` skill）。此后的版本由 CI 的 `tap-bump` 自动接管。

- [ ] **Step 5: 验证升级路径**

```bash
brew update && brew upgrade sing-box-ref1nd
sing-box version
```

Expected: 版本号为 `1.14.0-beta.5-reF1nd-moonfruit`，无需 `reinstall`。

- [ ] **Step 6: 验证 Gitee 分支格式未变**

```bash
git ls-remote https://gitee.com/moonfruit/private.git binary
```

Expected: `binary` 分支存在且刚被更新；其内容仍为一个 musl tarball 加
`version.txt`，与迁移前一致。

- [ ] **Step 7: 归档 sing-box-release**

确认上述全部通过后：

```bash
gh repo archive moonfruit/sing-box-release --yes
```

历史 Release 原样保留，不做迁移。

- [ ] **Step 8: 记录落地结果**

```bash
cd /Users/moon/Workspace.localized/go/mod/sing-box
git commit --allow-empty -m "Cut the first moonfruit release

v1.14.0-beta.5-reF1nd-moonfruit is published, the tap upgrades cleanly from
the plain -reF1nd version, and Gitee's binary branch keeps its old shape.
sing-box-release is archived."
git push
```

---

## Self-Review

**Spec 覆盖检查**

| spec 章节 | 对应任务 |
| --- | --- |
| §3 版本命名 | Task 1（`version.sh` 与其测试）、Task 12 Step 4（版本序验证） |
| §4 仓库与分支布局 | Task 11（`moonfruit`）、Task 12 Step 3（默认分支）、Task 6（`auto/*`、`base/*`） |
| §5.1 detect | Task 2 |
| §5.2 rebase | Task 3、Task 8 Step 4 |
| §5.3 build | Task 9 |
| §5.4 release | Task 10 Step 1 |
| §5.5 gitee-push | Task 10 Step 2 |
| §5.6 tap-bump | Task 7、Task 10 Step 3 |
| §6.1 claude 运行方式 | Task 5（`build_prompt`） |
| §6.2 三道闸门 | Task 5（`gate_*`、`newly_touched`） |
| §6.3 审查与放行 | Task 6、Task 8 Step 1（`issue_comment` 短路条件） |
| §6.4 人工解决路径 | Task 6（PR 正文）、Task 8 Step 4（失败 issue 正文） |
| §7 通知 | Task 4、Task 8 Step 4、Task 10 Step 3/4 |
| §8 凭据与仓库设置 | Task 12 Step 3 |
| §9 落地步骤 | Task 11–13 |
| §10 已知取舍 | 无需实现 |

无遗漏。

**已知的类型/命名一致性**

- `detect.sh` emit 的 key（`should_build`/`base`/`cur_base`/`target`/`prev_target`）与 `release.yml` 的 `detect.outputs.*` 一一对应。
- `rebase.sh` 的退出码约定（0/2）被 `release.yml` 的 `continue-on-error` + `steps.rebase.outcome` 消费。
- `resolve.sh` 的 `newly_touched` 被 `review-pr.sh` 的 `pr_body` 调用，参数顺序 `<new_base> <prev_target> <cur_base>` 两处一致。
- `tap-bump.sh` emit 的 `tap_pr` 被 `release.yml` 的 `steps.bump.outputs.tap_pr` 消费。
