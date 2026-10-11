# Hook：Intel 条件核对、Release 补测与隔离操作步骤

> 后续支持范围决定（2026-10-10）：[ADR 0032](../adr/0032-support-apple-silicon-only.md) 已改为 arm64-only。
> 本文 Intel/universal 阻断及工具链/VM 准备步骤属于历史调查，不再是本轮继续优化或新候选发布的要求。
> 真实 Release 批量测量仍须保护现有用户状态；当前只做临时根的 Core 隔离验证，不要求现在创建账户或 VM。


2026-10-10，承接[签名诊断及体积修复](hook-signature-diagnosis-and-helper-size-2026-10-10.md)。
本轮只核对环境、执行安全的 Release 检查及准备移交材料。生产冷预算不冻结；生产缓存启用、
宿主策略和第三阶段继续暂停。未执行接收资格成立的生产 hook，未修改现有回执、历史或活动计数。
未创建账户、安装工具链/VM、启动候选、commit、push 或 dispatch 发行 workflow。

## 本轮补齐的证据

冻结当前脏工作区中的 1,023 个版本管理/未忽略文件，构建使用该独立源码副本，未复用旧 GUI 或
LoginItem 可执行文件。来源 HEAD 为 `52a5a5f9975edb93cc93d0a817e025f6b725f03c`；
**HEAD 不能单独标识这些未提交改动**，移交必须同时保留源码归档和逐文件摘要。
源码构建前后逐文件一致，原 `dist/claudi0.app` 的正规文件及 symlink 清单前后完全一致。

| 检查 | 本轮结果 | 证据边界 |
| --- | --- | --- |
| 完整 arm64 Release 本地 bundle | 通过 | Swift 6.4、native 后端、SDK 26.5；GUI/helper full LTO + `-Osize`，LoginItem 原 Release 参数 |
| 原体积、布局及 GUI exports 门禁 | 签名前后均通过 | 原脚本，无预算覆盖；全部为 arm64，Sparkle 保留上游 universal framework |
| 完整 app ad-hoc 签名及 Sparkle 校验 | 通过 | 实际新 app；未启动，不等同 Developer ID、公证或 Gatekeeper 验收 |
| GUI/helper/LoginItem deployment floor | 三者均为 `minos 12.0` | 实际 Mach-O `LC_BUILD_VERSION`，不证明 macOS 12 运行 |
| 正式 helper 测试根边界 | 通过 | `CLAUDIO_TEST_ROOT` / `CLAUDIO_TEST_HOME` 均未编入该候选 |
| 候选 CLI 解析及授权前拒绝 | 10 组通过 | help/version、未知命令、未知宿主/无效 UUID；无接收资格成立的生产事件 |
| Debug CLI hook 契约 | 通过 | 临时根及存活身份 fixture，实际子进程、零输出、结果核对；不是生产完整路径 |
| 普通 Release adapter 迁移 | 140 checks / 0 | 临时包及临时配置，不读写真实宿主设置 |
| acceptance adapter 迁移 | 132 checks / 0 | 显式编译策略的隔离 harness，未启用任何生产 binding |
| Release 重放 driver 安全回归 | 14 unittest 通过 | 替身 helper、临时状态及受控身份；未执行真实批量重放 |
| Intel 最小链接预检 | 阻断 | 同一 Foundation/UUID 源码：arm64 成功，x86_64 因兼容库缺架构失败 |

本轮完整新候选的**签名后**大小如下；不得改写上轮不同后端/SDK 或借用 GUI 的历史结果。

| 项目 | 实测 B | 原上限 B |
| --- | ---: | ---: |
| GUI | 6,925,184 | 7,000,000 |
| helper | 2,746,768 | 3,250,000 |
| LoginItem | 54,208 | 500,000 |
| Sparkle | 2,705,105 | 3,500,000 |
| 其他资源 | 2,501,676 | 3,100,000 |
| app 正规文件合计 | 14,932,941 | 16,555,105 |

日志、源码清单、编译参数、二进制摘要、CLI 结果和移交归档位于
`dist/hook-release-readiness-2026-10-10/`。检查没有测量接收后的生产 helper 总耗时、真实宿主阻塞、
听音或首帧出声。上轮 16 项 GUI 全量断言失败不由打包成功替代；本轮没有重跑 GUI 全量。

## 可用工具链与阻断条件

本机为 arm64、macOS 27.0.1、Swift 6.4，当前 developer directory 为 Command Line Tools。
核对 `/Applications`、用户 Applications、Developer toolchain 目录及 Spotlight，未找到完整
Xcode 或替代 Swift toolchain。macOS 下六份 `libswiftCompatibility*.a` 均只有 `arm64 arm64e`。
最小 x86_64 编译明确报告忽略 compatibility56/Packs archive 后出现
`__swift_FORCE_LOAD_$_swiftCompatibility56` 未解析；不是 Claudio 业务代码或 LTO 的特有失败。

`arch -x86_64 /usr/bin/true` 返回 `Bad CPU type in executable`，目前没有可用的 x86_64 执行路径。
这项失败不能单独区分 Rosetta 缺失与系统程序切片条件；运行有效 x86_64 测试产物才能最终确认。
Apple 仍提供 macOS 27 的 Rosetta 安装方式，但翻译执行不提供编译缺失的 Swift archive，
也不能当作 Intel 原生耗时证据。[Apple Rosetta 文档](https://support.apple.com/en-us/102527)

只有一个普通本地账户，未发现第二个普通账户或已安装 VM 工具。本机 16 GiB RAM、8 个逻辑 CPU，
核对时数据卷可用约 35.8 GiB；没有自动清理任何文件。双 Xcode 的 VM 应另准备足够空间，
可先按至少 100 GiB 的工作空间规划，这是容量准备建议，**不是 Claudio 性能预算或厂商最低要求**。

旧 Xcode 不是直接装到当前系统就可认定满足条件：Apple 的当前兼容表将 Xcode 16.4 限定在
macOS 15.3–26.1.x；Xcode 26.3 为 macOS 15.6–26.x。本机 27.0.1 不在二者列出的区间。
两者的共同准备环境可选 macOS 15.6–15.x 或 26.1.x，实际恢复镜像/硬件兼容仍须验证。
[Apple Xcode 兼容表](https://developer.apple.com/xcode/system-requirements)，
[Xcode 16.4 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-16_4-release-notes)

还有一个仓库配置待核对项：`ci.yml` 的 helper lane 使用 Xcode 16.4，GUI/bundle lane 使用 26.3；
`release.yml` 整个 build job 仍继承 16.4，GUI 步骤没有切换。当前未取得 16.4 的 GUI 编译证据，
不能说 Release workflow 已通过，也不能把 CI 的 GUI 工具链声明直接套给 Release。
本轮不修改这一发行配置；后续需在兼容环境复现并决定统一/分步骤选用的工具链，再走独立发行授权。

## 操作步骤：先用实验账户补 arm64 生产基线

这条路径不要求先准备 VM，可保持本机 OS/硬件条件；**它不解决 Intel 工具链缺失**。
以下是移交步骤，本轮未执行新账户内的安装、连接、GUI 启动或重放。

1. 在“系统设置 → 用户与群组 → 添加用户”创建独立的**标准**账户，如 `claudio-hook-lab`；
   管理员密码由用户自己输入。切换到该账户实际登录桌面，不使用 Guest，也不只在当前账户改
   `HOME` 或设置 `CLAUDIO_TEST_ROOT` 来冒充隔离。[Apple 添加账户说明](https://support.apple.com/guide/mac-help/add-a-user-or-group-mchl3e281fc9/mac)
2. 将本轮归档和 metadata 复制到实验账户拥有的独立目录。源码及候选通过专用移交目录传递；
   不复制当前用户 `.claudio`、宿主设置、运行记录或凭据。先在新账户终端核对 `id -u` 和
   `python3 -c 'from pathlib import Path; print(Path.home())'`，确认得到实验账户身份和实际 home。
3. 校验归档 SHA-256，分别展开源码与候选。候选版本为 `0.0.0-dev`，只有 arm64，缓存仍默认关闭。
   `source.zip` 是本轮包含未提交修改的快照；仅 clone 当前 HEAD 会遗漏本轮改动。
4. 先运行原 `check-release-size.sh`、`verify-dev-bundle-signature.sh` 及 Sparkle verify。
   安装原生宿主 CLI 并只核对版本。后续另行确认实验运行范围后，才在**实验账户**启动候选、
   使用正常接入流程准备来源和安装身份；不要手写当前激活或绕过 Codex 信任。
5. 先做 n=1 的 driver smoke，核对发起数、当前 installation、真实 GUI 可执行身份及新增结果；
   通过后才考虑默认 10 次预热/100 次/三轮。锁忙也会写回执、剪枝和增加活动，并可发送提示，
   必须限定在实验账户。driver replay 不算真实宿主回调；真人听音须提前提醒、单独记录。
6. 每批保留实验状态的可恢复快照和脱敏结果，标注 warmup 和测量事件分母。任何版本、配置、
   installation、GUI 身份或并发事件变化使样本无效；不修改历史去“修好”结果。
   真实交互/短会话再单独进行，API 登录由用户在实验账户配置。

移交文件：

- `source.zip`、`source.zip.sha256`、`source-manifest.json`：源码及归属。
- `claudi0-arm64-local-check.zip` 及其 `.sha256`：未启动的完整 ad-hoc 候选。
- `candidate-metadata.json`、`release-helper-build.json`：候选身份和 Release driver 所需构建字段。
- 原有脚本从该冻结源码运行，输出使用新的实验目录。严禁在原账户运行下面的 opt-in 重放命令。

**仅在实验账户准备完成并确认实验范围后**，从展开的源码根目录执行，路径按实际移交位置调整：

```bash
# CANDIDATE_APP 是在实验账户内展开的候选，不是原账户的已安装 app。
CANDIDATE_APP="$PWD/lab-artifacts/claudi0.app"
bash scripts/check-release-size.sh "$CANDIDATE_APP"
bash scripts/verify-dev-bundle-signature.sh "$CANDIDATE_APP"
python3 scripts/sparkle-bundle.py verify "$CANDIDATE_APP" --archs arm64

# GUI/正常接入准备完成后；只提交 1 次锁忙和 1 次旧 installation 的 driver 事件。
python3 scripts/measure-release-hooks.py \
  --helper "$CANDIDATE_APP/Contents/Resources/bin/claudi0" \
  --host claude-code --build-metadata lab-artifacts/release-helper-build.json \
  --output lab-artifacts/replay-smoke --samples 1 --warmup 0 --rounds 1 \
  --allow-live-state-replay
```

这份 driver 当前只测锁忙/旧 installation，不覆盖完整播放、静音等全部生产场景；smoke 成功后
仍需先明确缺失场景的测量方案，不能据此宣称完整路径验收。当前生产工厂未注入缓存目录，
因此上述候选也不会验证生产缓存冷填充；真实签名的缓存 cold 仍属于已有 Core 隔离边界。

## 操作步骤：准备 Intel 编译环境

优先使用已有的、运行兼容 macOS 的独立 Mac/专用 runner。若只有本机，先准备外置 APFS 空间，
可使用 [VirtualBuddy 的官方项目及下载入口](https://github.com/insidegui/VirtualBuddy) 创建 VM；
它支持选择 macOS 版本或提供 IPSW，并可复制关机的 VM 保留干净基线。
Apple Silicon 上的 macOS 虚拟化是 ARM guest，不会因此得到 Intel 原生机器。
[Apple macOS 虚拟化说明](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon)

1. 选择能在本机启动的 macOS 15.6–15.x 或 26.1.x 恢复镜像，确认 guest 实际版本与架构；
   如果镜像不兼容本机硬件，改用兼容实体 Mac/runner，不降级或覆盖现有系统。
   可先给 guest 4 vCPU/8 GiB RAM，记录配置；这是准备建议，不作为性能可比性保证。
2. 在测试 guest 的 [Apple Developer Downloads](https://developer.apple.com/download/all/) 中取得完整
   Xcode 16.4 和 26.3。下载页面需要用户登录；本轮未下载，也未验证当前可下载的包/签名。
   展开后分别命名 `Xcode_16.4.app` / `Xcode_26.3.app`，打开完成许可与初始组件设置。
3. 每个命令显式设置 `DEVELOPER_DIR`，不更改原机器全局 `xcode-select`。先核对版本、SDK、
   compatibility archive 的 x86_64 切片，再执行同一最小预检和完整 helper 构建。
4. 使用本轮源码快照及原 Release 参数构建双架构。保留 strip/sign 前后摘要、Mach-O floor、
   逐架构体积；任何超限或链接失败均保留日志并停止，不替换系统库、移除 FORCE_LOAD 或改门禁。
5. 交叉编译成功只填补 Intel 构建证据。要补运行，需 Intel Mac/明确为 Intel 的 runner，或另标为
   Rosetta 翻译 smoke。要补 universal 门禁，还需 GUI/LoginItem 的双架构构建、资源一致性和完整装包；
   不只把 helper lipo 成 universal 后宣称整个 app 通过。

以下命令只在兼容测试环境的源码根执行：

```bash
DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer xcrun swift --version
DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer xcrun --sdk macosx --show-sdk-path
lipo -archs /Applications/Xcode_16.4.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx/libswiftCompatibility56.a
lipo -archs /Applications/Xcode_16.4.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx/libswiftCompatibilityPacks.a

DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer xcrun swift build \
  --package-path helper --scratch-path helper/.build/intel-release-check \
  -c release --arch x86_64 --product claudio --experimental-lto-mode full -Xswiftc -Osize

# GUI 使用其 CI lane 对应工具链；这不是当前 release.yml 已实现的切换。
DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcrun swift build \
  --package-path gui --scratch-path gui/.build/intel-release-check \
  -c release --arch x86_64 --product ClaudioGUI --experimental-lto-mode full -Xswiftc -Osize
```

只需翻译运行 smoke 时，Apple 的操作为 `softwareupdate --install-rosetta` 后跟随界面提示，
不要自动同意许可；本轮未执行。后续使用实际 x86_64 helper 的 `--version` 和授权前拒绝测试，
记录为 Rosetta 证据，不纳入 Intel 原生性能预算。

## 未通过或仍缺失的条件

Intel/固定 Xcode/universal：缺兼容环境和工具链；生产完整路径：缺独立账户或 VM，且缺全部场景的
真实测量；真实宿主/听音：缺新实验会话与人工确认；macOS 12 运行、完整 GUI 全量、Developer ID、
公证/Gatekeeper、远端 CI 和正式验收：未验证。准备环境和本地 ad-hoc 通过不解除这些闸门。

当前无需冻结生产冷预算。下一次只有在隔离条件就绪后才补对应证据，生产缓存、宿主策略与回执热路径
不随环境准备自动启用或实现；原账户的回执、历史、活动和宿主配置继续保持本轮不操作的边界。
