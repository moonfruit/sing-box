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

设计与流程细节见 [docs/specs/2026-08-05-patch-release-design.md](docs/specs/2026-08-05-patch-release-design.md)。
