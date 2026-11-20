# moonfruit/sing-box — patch 与发布自动化

这条 `ci` 分支是本 fork 的默认分支，**不含 sing-box 源码**，只放发布自动化。

sing-box 源码在别的 ref 上：

| ref | 内容 |
| --- | --- |
| `moonfruit` | 最新 reF1nd tag + 个人 patch 提交栈（patch 的唯一真源） |
| `v*-reF1nd*-moonfruit[.N]` | 发布快照 |

## 这里有什么

- `.github/workflows/` — 检测 reF1nd 新 tag、自动 rebase、构建、发布、更新 Homebrew tap
- `scripts/` — 上述流程的辅助脚本
- `docs/specs/` — 设计文档

## 常用操作

下列命令假定本 fork 是 `origin`。若你的 checkout 里 `origin` 指向上游
（sing-box 的开发副本常常如此），把命令里的 `origin` 换成 fork 对应的远端名。

```bash
# 同步集成分支（会被 CI force-push）
git fetch origin && git reset --hard origin/moonfruit

# 增删改 patch
git rebase -i $(git describe --tags --match '*-reF1nd*' --exclude '*-moonfruit*' --abbrev=0 moonfruit)
git push -f origin moonfruit

# 冲突时人工 rebase
git rebase --onto <新 reF1nd tag> <旧 reF1nd tag> moonfruit
```

## 配置自动解冲突

在领取 API 额度的 OpenAI 组织中创建项目密钥，保存为仓库的 Actions Secret。
下面的命令会交互式读取密钥。

```bash
gh secret set OPENAI_API_KEY --repo moonfruit/sing-box
```

rebase 冲突时，Pi 使用 `openai/gpt-6.2-sol` 处理当前 patch。全部 patch 通过构建和测试后，
CI 开审查 PR，由仓库所有者评论 `/ship` 放行。

设计与流程细节见 [docs/specs/2026-08-05-patch-release-design.md](docs/specs/2026-08-05-patch-release-design.md)。
