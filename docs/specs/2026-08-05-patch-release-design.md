# sing-box 个人 patch 的发布方案

日期：2026-08-05

## 1. 背景与目标

sing-box 上游（SagerNet）不接受 PR，个人修复与小功能没有合并渠道。目前实际消费这些改动的有两处：

- `moonfruit/homebrew-tap` 的 `Formula/sing-box-ref1nd.rb`（macOS / Linux bottle）
- `moonfruit/sing-box-release`（linux-arm64 三个 variant 的二进制 + Gitee 分发）

两者都基于 `reF1nd/sing-box`（上游的一个二次 fork）的 tag 构建。目标是让个人改动以「patch 叠加在 reF1nd tag 之上」的形式参与这两条构建链，并尽量自动跟随 reF1nd 的新版本。

改动规模的前提：patch 都是小功能点或问题修正，不涉及大型功能或大量代码。当前只有一个 patch（`fix-mdns-timeout`），未来会增加，但量级不变。

### 非目标

- 不追求与上游或 reF1nd 的代码合并
- 不覆盖 `Formula/sing-box-beta.rb`（跟踪 SagerNet 上游的那条线）
- 不覆盖 fork 中其它未纳入的分支（`mdns`、`dns-system`、`feature/tailscale-port`）

## 2. 方案选型

**不采用「维护 .patch 文件、构建时 apply」**。理由：「把 patch 打到新基点上」与「把提交 rebase 到新基点上」是同一件事，但 rebase 拥有完整的 merge base 与提交历史，冲突解决能力严格更强。实测：`fix-mdns-timeout`（基点 `8a42af329`）对 `v1.14.0-beta.5-reF1nd`，`git apply` 直接失败，`git apply --3way` 产生冲突，而 `git rebase` 能给出可交互解决的三方冲突现场。

**采用「fork 内维护集成分支 + 自动 rebase + 打 tag」**：在 `moonfruit/sing-box` 维护一条集成分支，CI 每日检测 reF1nd 新 tag 并自动 rebase，成功则打 tag 并驱动两条构建链。

`moonfruit/sing-box-release` 的构建逻辑一并迁入 fork，该仓库在验证通过后归档。

## 3. 版本命名

```
基点（reF1nd）           派生（moonfruit）
v1.14.0-beta.5-reF1nd    v1.14.0-beta.5-reF1nd-moonfruit
                         v1.14.0-beta.5-reF1nd-moonfruit.1
                         v1.14.0-beta.5-reF1nd-moonfruit.2
v1.14.0-beta.5-reF1nd.1  v1.14.0-beta.5-reF1nd.1-moonfruit
```

- 基点 tag 名**原样保留**，其后追加 `-moonfruit[.N]`。
- 由 moonfruit tag 反推基点：去掉尾部 `-moonfruit[.N]`。
- `.N` 是修订计数器，仅在「基点未变但 patch 栈变了」时递增。首个不带数字，第二个起 `.1`（与 reF1nd 自身习惯一致）。
- 生成规则：候选名 `${BASE}-moonfruit`，若 tag 已存在则依次尝试 `.1`、`.2`……

`constant.Version` 取 tag 去掉前导 `v`，故 `sing-box version` 输出中直接可见基点。

### 版本序验证

以 `brew ruby` 实测 `Homebrew::Version` 比较，下列序列全序正确：

```
1.14.0-beta.5-reF1nd
1.14.0-beta.5-reF1nd-moonfruit
1.14.0-beta.5-reF1nd-moonfruit.1
1.14.0-beta.5-reF1nd-moonfruit.2
1.14.0-beta.5-reF1nd.1-moonfruit
1.14.0-beta.5-reF1nd.1-moonfruit.1
1.14.0-beta.6-reF1nd-moonfruit
1.14.0-reF1nd-moonfruit
```

关键点：保留 `-reF1nd` 段是必要的。若命名为 `1.14.0-beta.5-moonfruit`，Homebrew 按字典序比较字符串 token，`moonfruit < ref1nd`，当前已安装的 `1.14.0-beta.5-reF1nd` 会被判定为更新，`brew upgrade` 不会升级。

## 4. 仓库与分支布局

### moonfruit/sing-box

| ref | 内容 | 维护者 |
| --- | --- | --- |
| `ci`（**默认分支**，orphan） | `README.md` + `.github/workflows/` + `scripts/` + `docs/` | 人工 |
| `moonfruit`（集成分支） | 最新 reF1nd tag + patch 提交栈 | CI rebase 后 force-push |
| `v*-moonfruit[.N]`（tag） | `moonfruit` 的发布快照 | CI |
| `auto/resolve-<tag>` | claude 自动解冲突的结果，待审查 | CI，审查通过后删除 |
| `base/<tag>` | 指向 reF1nd tag commit，仅作 PR 的 base（PR base 不能是 tag） | CI，审查通过后删除 |
| `fix-mdns-timeout` 等 | 现有 topic 分支，保留作历史 | 冻结 |

**`moonfruit` 是 patch 的唯一真源。** 增删改 patch 一律在其上 `git rebase -i`，topic 分支不再维护。该分支会被 CI force-push，本地以 `git fetch && git reset --hard moonfruit/moonfruit` 同步。

默认分支使用 orphan 分支的原因：reF1nd 的源码树自带 `stale.yml`（每日 cron）、`lint.yml` / `test.yml`（push 到 `stable`/`testing`/`unstable` 时触发）。orphan 分支上不存在这些文件，本方案的 CI 与继承来的 CI 完全隔离，无需逐个到 Actions 页面禁用。

### 继承 workflow 的触发面

已核对 `v1.14.0-beta.5-reF1nd` 树内 8 个 workflow 的触发条件：**没有任何一个由 `push: tags` 触发**。`docker.yml` / `linux.yml` 由 `release: published` 触发，但用仓库自带 `GITHUB_TOKEN` 创建 Release 不会触发新的 workflow run（GitHub 的防递归设计），故不会被误触发。

## 5. 发布主流程

`.github/workflows/release.yml`（位于 `ci` 分支），触发：`schedule` 每日 + `workflow_dispatch` + `issue_comment`（放行冲突解决方案，见 §6.3）。

`workflow_dispatch` 输入：

| 输入 | 说明 |
| --- | --- |
| `base_tag` | 指定 reF1nd 基点 tag，留空则自动检测 |
| `force` | 目标 tag 已存在时仍重建 |
| `resolve_ref` | 人工放行冲突解决分支，值为 `auto/resolve-<TARGET>`；`issue_comment` 路径则从事件载荷中取 PR 的 head ref |

不设 `gitee_force_push` 输入。Gitee 推送失败的补救由 GitHub 原生的 **Re-run failed jobs** 覆盖：该 job 从 Release 下载 musl 产物，不依赖 build job 的 artifact，可独立重跑。

`issue_comment` 会为仓库内任意评论创建 workflow run，故首个 job 以 `if:` 立即短路（非放行评论则跳过）。fork 内 issue 极少，这点日志噪音可接受。

```
detect ──► rebase ──► build (matrix ×3) ──► release ──┬─► gitee-push
                                                      └─► tap-bump
```

### 5.1 detect

1. 取 reF1nd 最新 tag 为 `BASE`：读 tag 列表，以正则 `-reF1nd(\.\d+)?$` 过滤后 `sort -V -r` 取首个。

   **不读 Release 列表**：reF1nd 只打 tag、从不发布 Release，该路径实测恒为空。留着它反而是隐患 —— 一旦上游哪天开始发 Release，检测依据会毫无征兆地改变。

   用正则而非 `endswith("-reF1nd")`：后者会漏掉 `-reF1nd.1` 形式的修订 tag，这正是迁移前 `sing-box-release` 踩过的坑。

2. 取集成分支当前基点：`CUR_BASE=$(git describe --tags --match '*-reF1nd*' --exclude '*-moonfruit*' --abbrev=0 moonfruit)`。

   `--exclude` 不可省：moonfruit tag 形如 `<基点>-moonfruit[.N]`，本身也匹配 `*-reF1nd*`。
   少了它，第一个 moonfruit tag 出现后基点就会解析成 tag 自己，rebase 区间变成空区间，
   **patch 被静默全部丢弃**，且三道闸门全会放行（无标记、能编译、测试过）。
3. 生成目标 tag `TARGET`（见 §3）。
4. `should_build` 为真的条件（任一）：
   - `CUR_BASE != BASE`（上游出新版）
   - `moonfruit` 的 tip 不等于最新 moonfruit tag 指向的 commit（本地新增/修改了 patch）
   - `workflow_dispatch` 传入 `force=true`

### 5.2 rebase

```bash
CUR_BASE=$(git describe --tags --match '*-reF1nd*' --exclude '*-moonfruit*' --abbrev=0 moonfruit)
if [ "$CUR_BASE" != "$BASE" ]; then
  git rebase --onto "$BASE" "$CUR_BASE" moonfruit || <进入冲突流程，见 §6>
fi
```

基点从 git 历史推导而非从 tag 名推导，使该步骤**幂等且自愈**：若人工已在本地 rebase 并推送，CI 重跑时发现基点已等于 `BASE`，直接跳过。

成功后 force-push `moonfruit`，并打 tag `TARGET`。

打 tag 前的硬性检查：`git grep -n '^<<<<<<< '` 必须无命中。已核对 reF1nd tag 的整个源码树不含此类行，不会误报。

### 5.3 build

原样迁移 `sing-box-release` 的 build job，仅改 checkout 目标为本仓库的 `TARGET` tag：

- matrix：`linux/arm64 × {purego, glibc, musl}`，三者均 `naive: true`
- build tags 取自 `release/DEFAULT_BUILD_TAGS`，purego 追加 `with_purego`，musl 追加 `with_musl`
- cronet-go 工具链下载与缓存、Debian keyring 重生成、`libcronet.so` 提取，逻辑不变
- ldflags 中版本号取 `${TARGET#v}`

### 5.4 release

创建 Release（tag = `TARGET`），上传三个二进制 tarball。**源码包直接使用 GitHub 自动生成的 archive**，不额外打包，也不需要在此计算 sha256（§5.6 的 `brew bump-formula-pr` 自己会下载校验）：

```
https://github.com/moonfruit/sing-box/archive/refs/tags/<TARGET>.tar.gz
```

Release notes 写明：基点 reF1nd tag（含链接）、patch 提交清单（`git log --oneline ${BASE}..${TARGET}`）。

### 5.5 gitee-push

原样迁移，逻辑与凭据不变：下载 `*linux-arm64-musl.tar.gz`，连同 `version.txt` 强推到 `gitee.com/moonfruit/private` 的 `binary` 分支。

### 5.6 tap-bump

在 runner 上使用自带的 Homebrew：

```bash
export HOMEBREW_GITHUB_API_TOKEN=${{ secrets.HOMEBREW_GITHUB_API_TOKEN }}
brew bump-formula-pr --version="${TARGET#v}" --no-audit --no-browse \
  moonfruit/tap/sing-box-ref1nd
GH_TOKEN=$HOMEBREW_GITHUB_API_TOKEN \
  gh pr edit <PR> --repo moonfruit/homebrew-tap --add-label pr-pull
```

只传 `--version` 即可：brew 用新版本串替换 formula 中 url 里的旧版本串，再下载计算 sha256。前提是 url 内含完整版本串 —— 本方案的 url 形如 `.../tags/v${version}.tar.gz`，成立。

`pr-pull` 标签之后由 tap 现有 CI 构建 bottle 并写回、合并（与 `/publish` skill 走同一条路）。

## 6. 冲突处理流程

```
rebase 冲突
  │
  ├─ claude -p 尝试解决（在真实 rebase 冲突现场，三方信息完整）
  │    │
  │    ├─ 三道闸门全过 ─► 推 auto/resolve-<TARGET> + base/<TARGET>
  │    │                 ─► 开 PR ─► Bark（指向 PR，不开 issue）
  │    │                 ─► 人工审查后在 PR 内评论 /ship ─► 发布
  │    │
  │    └─ 任一闸门失败 ─► git rebase --abort，不推任何分支 ─► issue + Bark
  │
  └─ claude 未启用或调用失败 ─► git rebase --abort ─► issue + Bark
```

### 6.1 claude 的运行方式

**不预先把上下文切片喂给它**，而是让它在**真实的 rebase 冲突工作树**中运行，拥有完整仓库访问（Bash / Read / Grep / Edit）。只切一个冲突文件是不够的：冲突可能并非「同一处代码被改动」，而是「上游变更了别处的 API，patch 必须跟着适配另一个文件」，这类成因只能靠探索发现。

prompt 只负责给出线索并划定边界：

- 被 rebase 的 patch 提交的完整 commit message（现有 patch 的 message 详细说明了每处改动的原因，是关键上下文）
- 冲突文件清单，以及 patch 原本触及的全部文件
- 基点变更区间 `${CUR_BASE}..${BASE}`，明确告知可用 `git log -p` 查阅
- 明确要求：先判定冲突成因属于上述两类中的哪一类；若为 API 变更，须检查 patch 触及的所有文件及相关调用点
- 允许并鼓励它自行运行 `go build` / `go test` 自验

凭据：`CLAUDE_CODE_OAUTH_TOKEN`（复用 Claude 订阅额度，不产生 API 费用）。

### 6.2 三道闸门

| # | 检查 | 目的 |
| --- | --- | --- |
| ① | `git grep -n '^<<<<<<< '` 无命中 | 防冲突标记残留 |
| ② | `go build -tags "$(cat release/DEFAULT_BUILD_TAGS)" ./cmd/sing-box` 通过 | 防语法/类型错误，兼查跨文件 API 适配是否完整 |
| ③ | 根模块 `go test ./...` 通过（不含 `test/` 子模块，那是需要 Docker 的集成测试） | 防行为回归 |

任一失败即 `git rebase --abort`，不推分支、不打 tag。

**不设「改动文件不得超出原文件集」这道闸门**：它会误杀「上游 API 变更导致 patch 必须适配新文件」这一类合法解法。改为报告项 —— 计算本次解决相对上一版新触及的文件，在 PR 正文中单列高亮。防「模型顺手优化无关代码」由闸门 ②③ 加上 `range-diff` 人工审查兜住，且没有任何路径能绕过人工放行。

### 6.3 审查与放行

CI 建立两条临时分支：

- `base/<TARGET>` = reF1nd tag commit（光秃秃的一条分支，存在的唯一理由是 PR 的 base 必须是分支而不能是 tag）
- `auto/resolve-<TARGET>` = reF1nd tag commit + 解决后的 patch 栈

以 `auto/resolve-<TARGET>` → `base/<TARGET>` 开 PR。由于 GitHub 的 Files changed 使用三点 diff（merge-base 即 reF1nd tag），**PR 的 diff 恰好等于 patch 栈本身**，Commits 页签即各个 patch。

开了 PR 就不再另开 issue —— PR 本身就是通知与审查的载体，Bark 直接指向它。

PR 正文由 CI 填充：

- 基点变更：`<CUR_BASE>` → `<BASE>`
- 冲突文件清单，以及本次解决相对上一版**新触及的文件**（见 §6.2）
- claude 的解决说明（其自身输出）
- `git range-diff` 输出 —— patch 相对上一版的变化，审查的核心
- 三道闸门结果与 build/test 日志链接
- 人工接管命令（见 §6.4）

**放行方式：在 PR 内评论 `/ship`。**

机制说明：`issue_comment` 属于「只从默认分支读取 workflow 文件」的事件类别，且 PR 上的评论也归入该事件。因此处理逻辑直接写在 `ci` 分支的 `release.yml` 里，无需在 `base/*` 分支上安放触发用的 workflow，也无需跨 workflow 派发（`GITHUB_TOKEN` 触发新 workflow run 会被 GitHub 的防递归机制挡下，那条路必须用 PAT）。

首个 job 的 `if:` 条件：事件为 `issue_comment` 时，要求评论体以 `/ship` 开头、`github.event.issue.pull_request` 非空、`github.event.comment.author_association == 'OWNER'`、且 PR 的 head ref 以 `auto/resolve-` 开头。

随后：force-push `moonfruit` = PR head → 打 tag → 走完常规构建发布 → 关闭 PR、删除 `auto/*` 与 `base/*` 分支。

选择评论而非标签的理由：标签打在 PR 上会触发 `pull_request: types: [labeled]`，该事件使用 **merge ref**（head 合并进 base 的结果）中的 workflow 文件，因而必须在 `base/*` 分支上多打一个提交安放 `ship.yml`，并额外付出一个 PAT 跨跳或一层 reusable workflow。评论路径的机制成本为零。

`base/<TARGET>` 不匹配 reF1nd 的 `lint.yml` / `test.yml` 的 `branches:` 过滤（`stable`/`testing`/`unstable`），故开 PR 不会触发继承来的 CI。

### 6.4 人工解决路径

不打标签即可放弃 CI 的方案，本地自行解决：

```bash
git fetch moonfruit --tags && git fetch ref1nd --tags
git rebase --onto <BASE> <CUR_BASE> moonfruit
# 正常解冲突，git mergetool / IDE 三方合并均可用
git push -f moonfruit moonfruit
```

CI 会把这条命令（含实际的 tag 名）直接写在通知与 PR 正文中。此路径保留了 index 中的 stage 1/2/3 三方信息，冲突复杂时优于在 `auto/resolve-*` 分支上手工删标记。

解决后手动 dispatch `release.yml`，detect 会发现基点已匹配，跳过 rebase 直接进入构建。遗留的 `auto/*`、`base/*` 分支与 PR 在下次成功发布时清理。

## 7. 通知

**Bark** 是主渠道，所有事件都发：POST 到 `BARK_URL`（`https://api.day.app/<key>`），JSON 体含 `title` / `body` / `group` / `url`。

| 事件 | Bark | GitHub issue |
| --- | --- | --- |
| 打 tag 成功 | ✓ 基点、目标 tag、patch 清单；url 指向 Release | — |
| 全流程完成 | ✓ 含 tap PR 链接；url 指向该 PR | — |
| 冲突，claude 解决成功 | ✓ url 指向审查 PR | —（PR 即载体，见 §6.3） |
| 冲突，claude 失败或未启用 | ✓ url 指向 issue | ✓ |
| 闸门失败 | ✓ url 指向 issue | ✓ |
| 构建/发布失败 | ✓ url 指向 Actions run | ✓ |

issue 正文含冲突文件、claude 的尝试结果、人工解决命令（§6.4）。以标签 `release-conflict` 检索既有 open issue，同一目标 tag 只追加评论，不重复开。

「打 tag 成功」与「全流程完成」两条若嫌吵，可只保留后者（它含 tap PR 链接，信息量更大）。

## 8. 凭据与仓库设置

| Secret | 用途 |
| --- | --- |
| `GH_PAT` | 唯一的 GitHub PAT，需 `repo` + `workflow` 两个 scope。两处用途：<br>① `prepare` 的 checkout —— 集成分支与冲突路径的临时分支都带着上游的 `.github/workflows/`，而 `GITHUB_TOKEN` 是 App 令牌、被 GitHub 禁止创建或修改 workflow 文件，且没有任何 `permissions:` 键能授予该能力；<br>② `tap-bump` —— 跨仓库向 moonfruit/homebrew-tap 开 PR 并打标签，`GITHUB_TOKEN` 够不到其它仓库。注入时映射为 `HOMEBREW_GITHUB_API_TOKEN`，那是 `brew` 认得的变量名。<br>其余 fork 内操作一律用 `GITHUB_TOKEN` |
| `GITEE_USER` / `GITEE_TOKEN` | Gitee `binary` 分支推送（自 sing-box-release 迁移） |
| `BARK_URL` | Bark 推送端点 |
| `CLAUDE_CODE_OAUTH_TOKEN` | CI 内 `claude -p` 自动解冲突（`claude setup-token` 生成） |

仓库设置：

- fork 中启用 Actions（fork 默认关闭），确认 `schedule` 生效
- 默认分支设为 `ci`
- 建立标签 `release-conflict`（冲突通知 issue 用）

## 9. 落地步骤

1. fork 内建立 orphan 分支 `ci`，设为默认分支。
2. 本地建立集成分支：
   ```bash
   git checkout -b moonfruit v1.14.0-beta.5-reF1nd
   git cherry-pick f1c8472d9      # fix-mdns-timeout
   ```
   解决 `dns/transport/mdns/mdns.go` 的冲突（基点 `8a42af329` 与 reF1nd tag 之间该文件有 6 行差异），推送。
3. 一次性手改 `Formula/sing-box-ref1nd.rb` 的三处非 bump 字段：
   ```ruby
   homepage "https://github.com/moonfruit/sing-box"
   head     "https://github.com/moonfruit/sing-box.git", branch: "moonfruit"
   livecheck do
     url :stable
     regex(/^v(\d(?:\.\d+)+(-\w+(?:\.\d+)?)?-reF1nd(?:\.\d+)?-moonfruit(?:\.\d+)?)$/i)
   end
   ```
   formula 名与 class 名不变（改名会破坏已安装环境）。`install` / `test` / `service` / `bottle root_url` 不动。
4. 在 `ci` 分支编写 `release.yml` 与辅助脚本，配置全部 secrets。
5. 手动 dispatch 跑通一次，产出 `v1.14.0-beta.5-reF1nd-moonfruit` 及全部资产。
6. 验证 tap PR → bottle 构建 → `brew upgrade sing-box-ref1nd`（`1.14.0-beta.5-reF1nd` → `…-reF1nd-moonfruit` 是正常升级，无需 reinstall）。
7. 验证 Gitee `binary` 分支内容格式与迁移前一致。
8. 归档 `moonfruit/sing-box-release`，历史 Release 原样保留。

## 10. 已知取舍

- **GitHub 自动 archive 的 sha256 稳定性**：GitHub 历史上曾变更 gzip 参数导致全网 archive sha256 失效。选择继续使用自动 archive 而非自建 tarball，接受该风险；若发生，重新 bump 一次 formula 即可。
- **每个上游版本需要一次 rebase**：无论自动还是人工。这是 fork 模型的固有成本，patch 文件模型同样存在，且解决能力更弱。
- **`git rerere`**：可让同一处代码在连续多个 reF1nd 版本上的重复冲突自动重放上次解法，需提交 `rr-cache`。当前不引入（YAGNI），若同一冲突出现第三次再考虑。
- **topic 分支退役**：`fix-mdns-timeout` 等分支冻结为历史，不再作为真源。patch 数量少，单条集成分支上 `rebase -i` 足以管理。
- **claude 自动解冲突不自动发布**：三道闸门全过也仅开 PR 等待人工在 PR 内评论 `/ship`。理由：这是日常使用的代理二进制，且 patch 触及 DNS 内部逻辑。
