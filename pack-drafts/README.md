# Claudio 声音包草稿区（pack-drafts）

尚在制作或试听的包、生成脚本和草稿音频。**本目录不进 Git**（见 [.gitignore](.gitignore)）：只保留说明文件，音频与脚本留在本机。

定稿并完成来源/许可核对后，再整理到 [`../packs/<pack-id>/`](../packs/README.md)。

## 目录内容

| 路径 | 存放内容 |
|---|---|
| `<pack-id>/` | 结构已是标准包形状、但尚未定稿的草稿包，例如 `pixel-quest/`。 |
| `<pack-id>/`（多变体） | 事件映射未完成的素材集合，例如 `station-chimes/` 的 64 条试听变体。 |
| `generate-*.py` | 生成或处理音频的脚本，随其草稿包一起保留。 |
| `audition-drafts.html` | 离线试听页（音频内联，无外部引用）。 |

## 晋升到 `../packs/` 的条件

1. **目录名 == `manifest.json` 的 `id`**，且为 kebab-case（`^[a-z0-9][a-z0-9-]*$`）。
2. **五个事件齐备并显式映射**：`task_start` / `stop` / `stop_failure` / `notification` / `subagent_stop`，
   `events` 的值必须是**字符串文件名**，不是对象；扩展名限 `.wav` / `.mp3` / `.aiff` / `.m4a`。
3. **音质达标**：见 [声音包客观标准](../docs/pack-standard.md)（时长 ≤ 2.0s、峰值 -1.0 dBFS、真峰值 ≤ -1.0 dBTP、头尾裁剪等）。
4. **来源与许可登记**：在 [`../packs/LICENSES.md`](../packs/LICENSES.md) 记录音频与生成脚本的 sha256，
   来源证据放 [`../packs/license-snapshots/`](../packs/license-snapshots/)；许可须为 `CC0-1.0` 才可能随应用分发。
5. **加入选择器目录**：在 `sound-pack-selector.html` 的 `const packs = [...]` 中登记该 id，
   否则 `scripts/test-sound-pack-selector-state.js` 会失败。
6. **显式批准分发**：id 写入 [`../packs/bundled-pack-selection.json`](../packs/bundled-pack-selection.json)；
   未列入白名单的包不会进入应用。

版权受限或仅本机使用的素材，去 [`../local-packs/`](../local-packs/)（整目录已被 Git 忽略），不要进 `packs/`。
