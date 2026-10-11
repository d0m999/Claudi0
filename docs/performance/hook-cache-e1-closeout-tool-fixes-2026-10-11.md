# E1 收尾工具修复（2026-10-11）

下文“两项修复”至“保留与复评”记录原修复轮；独立工具提取的后续结果另列于文末。
原修复包内的本文副本、工具、摘要和样本不随本次追加更新。

本轮仅修复只读评审指出的两项工具问题，并补充契约回归。
没有修改 resolver、GUI、adapter、Git 或回执算法，没有构建、运行 hook、追加诊断或性能测量。
E1 仍已结束；E2、生产启用、宿主策略及第三阶段暂停，生产预算和全部门禁保持原状态。

## 两项修复

`scripts/benchmark-native-hook-cache.py` 的后续命中摘要现在使用
`core_reference_p95_ms` 与 `within_core_reference`，不再输出 `approved_p95_ms` 或通用 `passed`。
刷新预算和后续 hook 生产预算均显式标为未冻结。数值和比较算法保持原样；本轮没有重算旧摘要。

原冻结包中的核验脚本保持原字节。修正版另存于
`dist/hook-cache-e1-closeout-tool-fixes-2026-10-11/verify-closeout.py`，
唯一行为改动是模块入口拒绝 `python -O` / `-OO`，在运行或导入时都先退出。
它保留原有断言检查；禁止优化模式后，这些断言不会被静默删除。
本轮只在合成临时目录中测试脚本，没有对真实冻结包执行 `initialize` 或 `finalize`。

## 契约验证

测试先在未修复版本失败，再分别通过：

| 契约入口 | 结果 | 边界 |
| --- | --- | --- |
| `python3 -B scripts/test-native-hook-cache-driver.py` | 10 tests，0 failures | 内存合成样本；明确参考线和预算状态，不调用 benchmark 或宿主 CLI |
| `python3 -B scripts/test-hook-cache-closeout-verifier.py --verifier dist/hook-cache-e1-closeout-tool-fixes-2026-10-11/verify-closeout.py` | 4 tests，0 failures | 优化模式的两个阶段、优化导入、正常模式的重复初始化/证据改变；全部为临时伪造目录 |

优化模式回归验证非零退出、明确拒绝原因和文件摘要不变；正常模式仍拒绝覆盖初始化，
也拒绝将改变的证据标为通过。字段回归分别验证高于和低于 Core 参考线的结果，避免改名时丢失比较含义。
本轮未运行 helper/GUI harness、签名、构建、音频或性能门禁；这些证据仍仅对应原 E1 固定候选。

## 保留与复评

[原 E1 收束报告](hook-cache-e1-closeout-2026-10-11.md)及冻结包、旧摘要、原始样本保持不变。
修复包单独保存限定 diff、修正版脚本、当前驱动器与契约、修复前失败和修复后通过日志、保留摘要及复评结果。
共享工作区其他改动保留；没有读取或写入现有宿主配置、回执历史、活动计数和生产版本缓存。

最终核对期间另有原型 HTML、本地化 Swift/xcstrings 及原型浏览器测试的并发变化。
它们单独记录于修复包，不纳入本次工具差异或契约通过结论；本轮没有重建 GUI 或覆盖这些内容。

修复工具不改变原性能判定：两项 Core bypass 超限仍保留，历史 28.11 ms 长尾来源和生产周期收益仍未知。
本轮的只读复评仅审查上述工具差异及其契约，不扩大为缓存采用或生产验收。

## 独立工具提取与提交边界

统计与样本核验现在由 `scripts/hook-cache-evidence.py` 独立提供，仅依赖 Python 标准库，
不读写文件、不导入 benchmark、不构建或调用 helper。最近秩统计、配对差值、最差轮次 p95、
结果计数及 Core 参考线语义保持原样。`scripts/test-native-hook-cache-driver.py` 改为直接测试该模块。

`scripts/verify-hook-cache-closeout.py` 是新的只读核验入口：显式接收 `--package`，
存在外部 `evidence-index.json` 时还必须传入 `--evidence-root`。
它检查清单列出的 SHA256，并仅在全部核对通过后向 stdout 输出 JSON 计数。
不支持旧工具的 `initialize` / `finalize`，不创建或覆盖冻结包及结论文件；运行和导入仍拒绝 `-O` / `-OO`。
它也拒绝空清单、重复条目、非法路径及 symlink。摘要一致仅证明列出文件的身份，
不证明清单完整、来源可信、性能达标或生产验收；未列出的文件不在核验范围内。

四个工具文件可在仅含 `scripts/` 的临时副本运行契约：

```bash
python3 -B scripts/test-native-hook-cache-driver.py
python3 -B scripts/test-hook-cache-closeout-verifier.py
```

本次结果分别为 12 tests 和 8 tests，均无失败；新增覆盖最近秩统计、带符号差值、
合并 p95 与最差轮次的区别，以及只读 CLI 的成功、改变证据、优化模式、旧写入命令、
外部索引、异常清单和路径边界。测试只使用内存样本及合成临时目录，不产生新增性能证据。

工具提交候选严格限定上述两个实现和两份契约。
`scripts/benchmark-native-hook-cache.py` 本地改为委托独立模块，并把模块摘要纳入源码身份；
这份接线差异单独保留，仍随 benchmark 与版本缓存实验暂缓，不纳入工具提交。
其源码身份格式改变，不适用于复核旧测量的构建身份；旧包中的驱动器和摘要保留原字节。

文档另分为历史调查与 E1 收尾两组；文件清单、候选副本、每文件摘要及只读复评单独保存于
`dist/hook-cache-tools-submit-candidates-2026-10-11/`。
这只是候选边界固定：没有暂存或提交，没有重算旧摘要、追加诊断或性能测量，
不改变 ADR 0033 的 proposed 状态、缓存采用决定、生产状态及任何暂停闸门。
