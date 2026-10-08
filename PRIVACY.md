# claudi0 Privacy Statement / 隐私说明

## English

claudi0's local helper and host-hook runtime have no telemetry, analytics, or cloud-upload path.
Sound packs, configuration, activation receipts, and the small rolling diagnostic log stay on this
Mac. Receipts contain a generated installation identifier, host/event identifiers, a timestamp, and
a redacted playback result. They do not contain prompts, responses, project paths, session content,
or absolute audio paths.

AI sound generation is an optional, explicit action in the claudi0 GUI. When you choose Generate,
your sound description and generation instructions are sent directly from this Mac to the selected
allowlisted provider profile. The current registry is:

- Profile `elevenlabs-global`: provider `ElevenLabs`; region `global`.
- Profile `minimax-global`: provider `MiniMax`; region `global`.
- Profile `senseaudio-cn`: provider `SenseAudio`; region `china`.

Bailian Beijing is available only in a non-distribution acceptance build while full real generation
and native acceptance remain incomplete. Next assets are fetched only from
`https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com:443` with `audio/x-wav`,
anonymous GET and no redirects. HTTP URLs for this exact bucket are upgraded before requesting,
preserving the path and signed query; no HTTP download is sent. Its API key and business workspace ID share one atomic Keychain
record. Saving checks both model inference permissions, not real generation. Legacy Qwen active and
pending credentials are removed during upgrade, without deleting audio or bindings.

The fixed SenseAudio `.cn` route does not promise data residency. The default remains ElevenLabs.
SenseAudio provides Chinese speech and sound effects, with no mixed
audio or automatic fallback. Sound-effect assets are downloaded immediately by anonymous GET only
from `https://dynamic.senseaudio.cn:443`, with `audio/mpeg`, no redirects, and no persisted asset URLs.

A provider may charge your account. Credential storage, retention, and model-improvement use follow
the per-profile disclosure shown before saving the credential and that provider account's settings
and terms; one provider's terms are not applied to another. Credentials are stored in the macOS
Keychain and are not included in copied diagnostics. The SenseAudio profile is the exception:
its key is stored in an unencrypted, user-private local file outside projects, with a 0700 directory
and a 0600 file, both without extended ACL entries. Other processes with the same user's file access may read it. Claudio does not
display or export saved keys, and it does not migrate or delete existing SenseAudio Keychain items.

Valid generated audio is automatically saved in private local generation history, including results
you do not use. Each batch keeps your original sound description, generation time and actual
provider profile and actual model ID (absent in older records); each audio item keeps its name, duration and file-integrity metadata. Internal
sound plans, request bodies, provider request IDs, remote URLs, credentials and workspace identities
are not saved in this history. Records stay until you move them to the macOS Trash. Deleting a record
does not remove an independent copy already used in a sound pack. Named, unpublished sound-pack
drafts also remain on this Mac. Closing Settings does not cancel an active generation; unsaved
results are not guaranteed to survive quitting or a crash. Descriptions and history are excluded
from diagnostics and logs. See [local storage and recovery](docs/sound-assets-storage.md).

The About page's safe diagnostic summary contains only app version/build, architecture, macOS
versions, published Surface semantic states, and whether fixed app resources exist. It excludes path
values, receipt contents, credentials, sound descriptions, provider responses, calendar or Focus
data, personal sound-pack names, configuration contents, and log text.

## 简体中文

claudi0 的本地 helper 与宿主 hook runtime 没有遥测、分析或云端上传路径。声音包、配置、激活回执
和小型滚动诊断日志都保留在这台 Mac 上。回执只包含随机生成的安装标识、宿主/事件标识、时间戳和
脱敏后的播放结果，不包含提示词、回复、项目路径、会话内容或音频绝对路径。

AI 声音生成是 claudi0 GUI 中可选且必须由用户明确触发的动作。选择“生成”时，声音描述和生成指令
会由这台 Mac 直接发送给所选 allowlisted Provider profile。当前 registry 为：

- 配置 `elevenlabs-global`：Provider `ElevenLabs`；region `global`。
- 配置 `minimax-global`：Provider `MiniMax`；region `global`。
- 配置 `senseaudio-cn`：Provider `SenseAudio`；region `china`。

百炼北京仅在非分发验收构建中开放，完整真实生成与原生验收尚未完成。Next 资源只从
`https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com:443` 匿名 GET 下载，固定
`audio/x-wav`，禁止跳转。仅将该精确域名的 HTTP 输入地址转换为 HTTPS 后请求，路径和
签名参数保持原样，不发出明文 HTTP 下载。API Key、百炼业务空间 ID
和真实生成验证事实保存在同一原子 Keychain 记录中。保存只检查两个模型的推理权限，不代表
真实生成通过。升级删除旧 Qwen 的 active 与 pending 凭据，保留音频和绑定。

固定 SenseAudio `.cn` 路线不承诺数据驻留。默认 Provider 仍为 ElevenLabs。
SenseAudio 提供中文语音与音效，不支持 mixed，不自动 fallback。
音效资源只从 `https://dynamic.senseaudio.cn:443` 立即匿名 GET 下载，仅接受 `audio/mpeg`，
禁止 redirect，不持久化资源 URL。

供应商可能向你的账户收费。凭据存储、数据留存及是否用于模型改进，以保存凭据前显示的逐 profile
披露、对应供应商账户设置和条款为准，不会把一个供应商的条款套用于另一个供应商。凭据保存在
macOS 钥匙串中，不会进入可复制的诊断摘要。SenseAudio profile 是例外：Key 保存在项目
之外、未经加密的用户私有本地文件中，目录权限为 0700、文件权限为 0600，均不允许扩展 ACL 条目。同用户且具备相应文件
访问权限的程序仍可能读取它。claudi0 不显示或导出已保存的 Key，也不迁移或删除既有 SenseAudio
Keychain 项。

所有有效生成音频自动保存到私有的本地生成记录，包括未选用项。每组保存原始声音描述、生成时间
及实际服务和模型 ID（旧记录可缺失）；每条音频保存名称、时长和文件完整性元数据。记录不保存内部声音方案、请求正文、
供应商请求 ID、远端 URL、凭据或工作区身份。记录一直保留，直到你将它们移到 macOS 废纸篓；
删除记录不影响已用于声音包的独立副本。已命名但未发布的声音包草稿也保留在本机。关闭设置
不会取消正在进行的生成；未保存结果不保证在退出或崩溃后恢复。描述与记录不进入诊断或日志。
详见[本地存储与恢复](docs/sound-assets-storage.md)。

“关于”页的安全诊断只包含应用版本/构建、架构、macOS 版本、已发布 Surface 的语义状态，以及
固定应用资源是否存在。它排除路径值、回执内容、凭据、声音描述、供应商响应、日历或专注模式数据、
个人声音包名、配置内容和日志原文。
