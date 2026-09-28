# Claudio 声音素材目录

本文说明仓库内声音素材目录的用途，以及声音包目录和事件音频的命名方式。仓库中的 `packs/` 是策展工作区；只有 `bundled-pack-selection.json` 明确列出的包会随应用分发。

## 目录用途

| 路径 | 存放内容 | 用途与边界 |
|---|---|---|
| `packs/<pack-id>/` | 一套声音包的 `manifest.json` 和事件音频 | 策展声音包。目录名就是包 ID；是否随应用分发由 `bundled-pack-selection.json` 决定。 |
| `packs/license-snapshots/` | 来源网页、许可证文本和页面截图 | 为 `packs/LICENSES.md` 中的授权记录保存来源证据。新增或替换分发音频时，同步补齐来源和许可记录。 |
| `../pack-drafts/` | 尚在制作或试听的包、生成脚本和草稿音频 | 工作草稿；定稿并完成来源/许可核对后，再整理到 `packs/<pack-id>/`。 |
| `../local-packs/` | 本机个人使用的角色音包及 raw、processed、archive 候选素材 | 个人/IP 素材目录，已由 Git 忽略；不要提交或随应用分发。候选音频不是已安装用户声音包。 |
| `../local-packs/<pack-id>/candidates/archive/` | 已选定保留、但未整理成事件音包的候选素材及其 `SOURCES.md` | 候选归档。例如 `railway-chimes/candidates/archive/` 存放 3 条铁路铃音。含 CC BY-NC 素材的包必须留在本目录，不要提交仓库或随应用分发。 |
| `../yamanote-audio/` | 山手线各站发车旋律的 `.opus` 试听素材 | 配合仓库根目录的 `yamanote-player.html` 使用，不属于 Claudio 的五类事件音包。用于分发前须另行核实授权。 |
| `~/.claudio/packs/<pack-id>/` | 应用运行时安装的用户声音包 | 用户导入或安装后的本机数据目录，位于仓库之外。 |
| `dist/claudi0.app/Contents/Resources/packs/` | 构建应用中的内置包副本 | 构建产物，不是素材源目录；应从仓库的 `packs/` 重新生成。 |

当前 `packs/` 下的包目录包括 `minimal-chime/`、`night-console/`、`pizzicato-cadence/`、`resonant-bowl/`、`soft-mallet/` 和 `station-chimes/`；每个子目录是一套独立的声音包。`station-chimes` 的 64 条试听变体和未完成五事件映射的 `magic-chime` 留在 `pack-drafts/`。`license-snapshots/` 不是声音包，不要把音频放进其中。

## 命名规则

### 声音包目录

- 使用小写英文和连字符组成的 kebab-case 名称，例如 `minimal-chime`、`night-console`。
- 目录名必须与 `manifest.json` 内的 `id` 完全一致；包 ID 在 `packs/` 下应保持唯一。
- kebab-case 是仓库约定。运行时还会拒绝空 ID、`.`、`..`、路径分隔符和 NUL 字符，但这项安全校验不会替代命名约定。

### 事件音频文件

- 文件名使用稳定事件 ID，加上实际音频扩展名：`<event-id>.<ext>`。
- 事件 ID 固定为以下 snake_case 拼写，并与 `manifest.json` 的 `events` 键一致：

  | 文件名主体 | 事件含义 |
  |---|---|
  | `task_start` | 用户发起 |
  | `stop` | 响应结束 |
  | `stop_failure` | 执行中断 |
  | `notification` | 等待介入 |
  | `subagent_stop` | 子任务结束 |

- 音频扩展名使用 `.wav`、`.mp3`、`.aiff` 或 `.m4a`，且文件内容必须与扩展名相符。示例：`stop_failure.mp3`。
- 新策展包按五个事件整理音频；历史包缺少 `task_start` 仍可兼容。不要用 `stopFailure`、`subagentStop` 等 camelCase 名称替代事件 ID。
- 在 `manifest.json` 中显式映射事件声音。包内文件使用字符串；系统音使用 schema 2 的名称引用，详见下节。文件改名时同步更新 manifest 和相关来源/许可记录。

### 事件映射格式

旧文件包继续兼容。首次保存系统音映射时写入 `schema: 2`，文件映射仍为字符串：

```json
{
  "schema": 2,
  "id": "my-cues",
  "events": {
    "stop": "stop.aiff",
    "notification": { "system_sound": "Basso" }
  }
}
```

每个事件只有一个声音来源；缺少的事件为未配置。纯系统音包可以只有 manifest，不需要复制音频。
系统音按名称在本机解析，不存系统路径、不打包 macOS 文件。名称不可用时该事件停止播放，其他可用事件继续。
同包内一个系统音名称或规范化文件引用只能新绑定一次；既有重复可继续播放并逐项修正。
包内文件清单、许可材料和复制音频只涉及实际包内素材；系统音引用不代表获得音频分发许可。

映射由「声音」编辑，选用包、音量和事件开关由「默认组／工作区」管理；详见 [ADR 0021](../docs/adr/0021-own-all-event-sounds-in-packs.md)。

### 候选素材与来源记录

- 草稿或尚未选定的音频留在草稿/候选目录，不要提前命名成正式事件文件并混入已整理的声音包。
- `raw/`、`processed/`、`archive/` 用于区分候选处理状态。保留有辨识度的来源或候选名；若索引、脚本或试听页引用了文件，改名时一并更新引用。
- 新增来源快照建议使用 `<source>-<artifact>-<YYYY-MM-DD>.<ext>`，例如 `kenney-impact-sounds-package-License-2026-09-02.txt`。来源与许可的详细信息记录在对应的 `SOURCES.md` 或 `packs/LICENSES.md` 中。

音质与格式要求见 [声音包客观标准](../docs/pack-standard.md)；内置包许可记录见 [LICENSES.md](LICENSES.md)。
