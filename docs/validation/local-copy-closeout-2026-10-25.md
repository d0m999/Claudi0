# 本地副本清理结项 2026-10-25

本轮按用户授权，将仍适用的遗漏覆盖合入本地 `main`，直接删除重复、过时及可重建的本地残留，不制作备份。
审阅基线为 `8d081fc33e4d220795789e510822225797104e86`；测试补充提交为
`c20e5fc48eb1208e0614ba892de04564b58dff4b`。本轮没有 push、发布或修改远端分支。

## 审阅结论

| 来源 | 核对结果与处理 |
| --- | --- |
| 10 月 17 日 A1–A5、validation、combined | `565906a`、`02fb184`、`a4ed562` 均在基线 main 历史。由原 full-index patch 重建后，A1–A5 合并树与已交付树一致；validation 保留主线新增的 WindowServer 有界等待后也一致。删除旧源码、构建和恢复归档。 |
| 10 月 12 日 preview 副本 | 基础提交已合并。40 个文件版本在 main 历史；其余 15 个版本经差异审阅属于旧更新、签名、架构及交付实现，保留主线新版。 |
| 10 月 13 日 sound-event detached 分支 | `10aebad` 的 12 个代码文件版本已在 main 历史；验证文档已有包含后续修复的新版。无需合回旧 snapshot 提交。 |
| 10 月 4 日旧分支 bundle | `e77f1b9` 的 659 个 tip 文件版本均在 main 历史。`41420a1` 的 24 个不同版本逐项比对；恢复当前仍适用的三处回归覆盖，舍弃旧八页 UI/驱动、格式差异及已被新版覆盖的内容。 |
| 10 月 13 日 unique extras 与其他混合副本 | 审阅 82 个不同源码版本及混合归档中的源码；旧凭据、Provider、发布实现弱于或早于现行版本，暂停的性能实验和一次性复现探针不进入产品主线。 |
| 10 月 11 日同步备份 | 35 个 patch 新文件版本中，34 个可在 main 或暂停实验的 Git 历史中找到；剩余下载页的 arm64 限制已由当前更完整版本覆盖。 |
| 暂停的 hook 实验 | 17 份副本源码与 `a11bab32b40b45c1c95dd17d8030eece41e35c75` 字节一致。保留 `origin/archive/paused-hook-experiments-20261013T024318Z`；删除本地 files、patch 和 bundle。 |
| 编译体积临时探针 | `f7380ec`、`066fdc5`、`edcde96` 为旧测量实验，不是待合入产品功能；当前交付已有后续工具链与体积结论。 |

三处测试分别覆盖：最新设置请求优先且只交付一次、窗口 owner 向 core 传递真实状态、关闭后展示与归还焦点分支互斥。
core 行为使用可执行测试；private executable owner 的跨 target 接线使用已有源码扫描接缝。
没有改动产品行为，没有复活已退役的八页设置合同或暂停实验。

## 验证

- 全部 GUI harness 源码编译通过：
  `swift build --package-path gui --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --product claudio-gui-tests`。
- 隔离 worktree 内临时添加 `--residue-closeout` 编排，运行完整
  `runPanelSettingsChoreographySuites()`、`runSoundPacksRefreshSuites()`，
  以及 `PanelSettingsHandbackSuite` 的生产 owner 接线用例；不创建原生窗口。
  结果为 **319 checks, 0 failures**。
- 将隔离源码的 `panelIsShown` 和 `primaryMouseButtonDown` 实参分别故意改成 `false`，
  使用已编译程序读取变异源码，准确得到以下两项失败：

```text
管理入口必须把 typed route、精确焦点、宿主和真实菜单状态交给同一编排 owner
普通切换应用和其他状态项不能进入保护路径，三项当前事实必须传给可测的编排层
Residue closeout (no native windows): 319 checks, 2 failures
```

- 恢复生产源码后：`Residue closeout (no native windows): 319 checks, 0 failures`。
  临时测试入口随后恢复，最终原样编排的全部 harness 再次编译通过。
- 三个改动文件的 `swift format lint`、本地化 JSON 校验及 `git diff --check` 通过。
- 另一项任务持续使用原生设置预览，因此本轮未运行完整 GUI 或原生窗口/焦点门禁；
  上述定向结果不代表原生、VoiceOver、真实宿主/音频、签名或发布验收。
- 46 个真实已安装工具在测试前和全部临时清理后，SHA-256 与 POSIX mode 均一致。

## 删除范围与收尾

以下 24 个精确目录共 **1,760 个文件、7,189,417,183 字节**，已直接删除。
数字为归档文件及目录内普通文件的逻辑大小；不会再把压缩包内部条目重复计数。

`~/.codex/evidence/` 下的 21 个目录：

- `claudio-cache-cleanup-20261015T173956+0800`
- `claudio-cleanup-20261012T074634Z`
- `claudio-cleanup-a3-20261017T055125Z-7d1ahszw`
- `claudio-cleanup-a4-20261017T072236Z-ljdd1y08`
- `claudio-cleanup-a5-20261017T085135Z-jova3y3g`
- `claudio-cleanup-approved-31-20261012T141555Z`
- `claudio-cleanup-commit-20261017T104028Z-3ioki_lt`
- `claudio-cleanup-integration-20261017T162711Z-82p6qmwy`
- `claudio-cleanup-validation-20261017T091956Z-fe622mom`
- `claudio-copy-cleanup-20261013T151914Z`
- `claudio-focus-a2-20261017T053011Z-n_zv7son`
- `claudio-gui-size-20261013-220142`
- `claudio-latest-package-20261013-212320`
- `claudio-package-cleanup-20261015T173316+0800`
- `claudio-remaining-residual-review-20261012T084014Z`
- `claudio-residual-cleanup-20261012T075215Z`
- `claudio-sound-event-selection-20261013`
- `claudio-source-cleanup-20261016T161710Z-7uf8lx40`
- `claudio-temp-copy-removal-20261012T082445Z`
- `claudio-uniqueness-audit-20261012T075958Z`
- `claudio-worktree-closeout-20261017T144154Z-4c4eucbo`

另外三个目录：

- `~/.codex/archives/claudio-branch-cleanup-20261004T153043Z`
- `~/.codex/backups/claudio-sync-20261011T083231Z`
- `~/Documents/Codex/archives/Claudio/paused-hook-experiments-20261013T024318Z`

删除前逐项复核 inode/device、类型、大小、mode、mtime 和 hard-link 数；24 个目标均无 symlink、多重 hard link 或特殊文件，且没有打开的文件句柄。
本次临时 worktree 中的 symlink 仅用 `lstat` 与 `readlink` 记录，未沿链接归档或修改目标。

本次临时验证 worktree 已通过精确路径 `git worktree remove --force` 删除；
其 ignored 内容只有可重建的 `gui/.build/`。临时比较仓库、抽取文件、探针和日志也已删除。
最终 `git worktree list` 只保留主 checkout，`git worktree prune --dry-run --verbose` 无输出，24 个旧目标均不存在。
未删除分支 refs、主 checkout、用户运行数据或并行任务使用的目录。

合入时，主 checkout 原有 7 个未提交/未跟踪文件的字节与权限保持不变；清理仅作用于上述外部目录。
收尾期间其他任务继续更新自己的测试入口与验证文档，本轮未覆盖或提交这些工作。
磁盘可用空间从 36,870,756 KiB 观察到 43,799,116 KiB，净增约 7.09 GB；
APFS 分配及并行任务使该观察值不能全部归因于本次删除。
