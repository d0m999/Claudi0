---
status: accepted
---

# 使用百炼北京业务空间与 Audio 3.1 固定路线

> 百炼的 Keychain 存储与首次使用前强制旧槽清理要求由 [ADR 0029](0029-save-bailian-configuration-in-private-local-file.md) 取代。下文保留原决定的依据；其余模型、资源、生成和验收门禁合同继续有效。

本决定部分取代 ADR 0006 的旧北京／新加坡 Qwen 路线与凭据政策。旧 Qwen 入口与模型调用撤下，旧选择迁移为 `bailian-beijing` 待配置，不静默选择其他服务。历史记录、声音包及绑定保留。

纯语音固定 `qwen-audio-3.1-tts-flash`，中文 `yuxiaoyun_v3.1`、英文 `Emily_v3.1`，SSE PCM 封装 WAV，末包 URL 不跟随。其余声音类型（动物、环境音、音效、短旋律、混合）固定 `qwen-audio-3.1-tts-next`，发送 `text_prompt`，JSON URL 立即下载 WAV / 24 kHz / mono。两模型均在业务空间专属北京 HTTPS 地址调用；业务空间不是 Claudio 本机工作区，不接受任意 endpoint。

一次显式生成顺序发送清晰、轻快、克制三种真实风格；Flash 总预算 60 秒，Next 180 秒，子请求、下载、校验共享。全部三项必须有效，每项最多 3 秒、5 MiB。任一失败立即终止并清理整批，不保存残缺生成记录、不裁剪、不自动补生成或切换模型；生成 POST 零自动重试。现行单在途任务、关闭界面后继续生成及显式采用合同保留。没有音色选择、复刻、参考上传或完整音乐生成。

现有凭据 owner 原子保存同一 Keychain 记录中的 API Key 与类型化业务空间 ID。保存前精确查询两个模型的 `AUTHORIZED` / `INFERENCE` 权限；失败保留旧配置。权限检查与真实生成验证分别呈现。一批生成读取同一配置租约，配置版本变化时迟到结果不得发布。首次使用执行旧 Claudio service 下北京／新加坡 active、pending 四槽删除及验证元数据清理；缺失视为成功、删除失败可重试、不标记完成，其他服务隔离。

Next 下载合同须由最多两次真实资源发现确定精确 HTTPS origin、443、MIME、匿名 GET、零跳转；拒绝 IP、userinfo、fragment、最终 URL 漂移。2026-10-08 用户明确调整返回地址规则：仅对实测的 `dashscope-result-bj.oss-cn-beijing.aliyuncs.com` 接受 HTTP 默认端口或 80 的输入地址，下载前转换为该域名的 HTTPS / 443。路径与签名 query 字节原样保留；不发出 HTTP 请求、不接受其他域名或端口转换。最终 URL 必须与转换后的请求地址完全一致。政策由代码持有，不从响应学习。第二次资源发现已验证转换后的 HTTPS / 443 匿名 GET 返回 200，MIME 为 `audio/x-wav`，无跳转、最终 URL 无漂移，代码固定该 origin 与 MIME。缺失下载政策仍在 Next POST 前关闭。通过资源合同及真实采用验收前，新入口仅 `CLAUDIO_BAILIAN_ACCEPTANCE` 非分发构建可选。旧选择仍投影为待配置百炼，不取得生成资格。

新生成记录增加可选实际模型 ID，旧记录缺字段继续读取。长期保存字段授权由本决定与 ADR 0026 共同限定；下载 URL 与凭据不保存。

接口依据：[Flash](https://help.aliyun.com/zh/model-studio/qwen-audio-tts-http-api)、[Next](https://help.aliyun.com/zh/model-studio/audio-generation-api)、[模型权限](https://help.aliyun.com/zh/model-studio/list-model-permissions)。官方响应示例不是下载 origin 实测证据。协议转换依据 [OSS HTTPS 访问](https://help.aliyun.com/zh/oss/user-guide/access-oss-by-https-protocol)，真实合同见实施记录。

最多 20 次真实生成请求：2 次资源发现，加六组三候选（中文语音、英文语音、自然动物声、车站短旋律、特效、混合）。失败不追加调用。自动 harness、真实调用、原生听感/保存重启/试听/采用/失败保留绑定、最终 Bundle 身份分别记录；本地 ad-hoc app 不构成发布、公证或正式验收。
