# 声音包目录导入格式

本格式对应声音重设计规格 #217。`.claudiopack` 是 macOS 目录包，也接受内容相同的普通文件夹。当前版本不解压 ZIP，不提供整包导出。导入只安装声音包，不为任何组选择它。

```text
Example.claudiopack/
  manifest.json
  completion.mp3
  ATTRIBUTION.txt
```

最小示例：

```json
{
  "id": "example-cues",
  "name": "Example Cues",
  "events": { "stop": "completion.mp3" }
}
```

`manifest.json` 继续由现有 `PackManifest` 解析。事件 ID 为 `task_start`、`stop`、`stop_failure`、`notification`、`subagent_stop`。保留原 ID、显示名称、未知元数据和独立归属材料；已有同名显示名称可导入，ID 与内置包、用户包或草稿冲突则拒绝。导入不会覆盖已安装包，也不会修改源目录。

选择目录后先复制到隐藏私有 staging，展示实际名称、已配置事件数量及素材文件数量（不计 manifest）。只有确认“导入”才在 `packs.lock` 内重新校验并独占发布。选择、预览和取消不会改变组选包。失败的 staging 不进入声音包扫描结果。

安全边界：

- 拒绝目录或文件符号链接、特殊文件、路径逃逸和不完整的音频文件引用。
- 所有引用音频和可识别音频文件须通过现有格式识别及实际时长探测；最多 5 MiB、3 秒。
- 系统提示音保留名称，本机缺失时由共享包事实显示不可用；不生成替代文件。
- manifest 最多 1 MiB；单个附属普通文件最多 16 MiB；整个输入最多 256 MiB、10,000 个文件、16 层目录。这些是导入器的资源边界，不改变运行时 manifest 格式。
- 未知附属文件按原字节保留，不执行其中内容。

复制使用相同的私有快照和独占发布机制，但由用户先确认名称，并分配新 ID。按 ADR 0016，复制移除整包 `license`、`author` 声明，保留独立归属材料及其他未知字段。普通重命名仅修改 manifest 的 `name`，不改变 ID、目录、事件映射或引用。

实现入口：`SoundPackDirectoryTransfer`；核心集成与故障样例：`SoundsRedesignCompositionSuite`。自动检查不等同于真实音频听感或分发包验收。
