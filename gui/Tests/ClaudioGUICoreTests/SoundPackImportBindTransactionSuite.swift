import ClaudioCore
import Foundation

@testable import ClaudioGUICore

// Covers the one import/bind envelope of ``SoundPackImportBindTransaction`` directly through
// scripted hooks: success, cancel-before-start, cancel-mid-flight, empty result, bind failure
// with cleanup, stale target / freshness loss, orphan stage cleanup, and draft vs non-draft
// semantic equivalence. The owner-side pipelines are covered end-to-end by
// `SoundPacksEditorAsyncOperationSuite` and `AICuePackScopedSuite`; this suite pins the
// transaction's canonical terminal semantics so no pipeline can drift its own copy again.
@MainActor
func runSoundPackImportBindTransactionSuites() async {
    await suite("Import/bind transaction：三个 variant 的成功终态各只 settle 一次") {
        let manifest = AICueManifestBindingOutcome(
            event: .stop, fileName: "cue.mp3", finalDisplayName: "完成")
        let preview = SoundPackEditorAction(id: 901, kind: .preview)

        let adoption = StubImportBindHooks()
        adoption.bindResult = .bound(SoundPackImportBindBinding(boundEvent: nil, manifest: manifest))
        adoption.previewAction = preview
        let adopted = await SoundPackImportBindTransaction(
            variant: .adoptCue, hooks: adoption)
        .run()
        guard case .succeeded(let adoptionSuccess) = adopted else {
            expect(false, "adoptCue 成功必须返回 succeeded，实得 \(adopted)")
            return
        }
        expect(
            adoptionSuccess.imported == stubImportedFile
                && adoptionSuccess.binding == manifest
                && adoptionSuccess.previewAction == preview
                && adoptionSuccess.importOutcome == nil,
            "adoptCue 成功必须携带 bound 文件、manifest receipt 与 owner 签名 preview")
        expect(
            adoption.settlements.map(\.phase) == [.succeeded]
                && adoption.settlements.allSatisfy { $0.importOutcome == nil },
            "adoptCue 成功必须以 succeeded phase settle 一次且不保留 import outcome")
        expect(
            adoption.finishChangedDespiteFailure == [false]
                && adoption.finishWithoutChangeCount == 0
                && adoption.discardCount == 0
                && adoption.beginScopeCount == 1
                && adoption.recheckCount == 1
                && adoption.postWriteCurrencyCount == 1
                && adoption.bindInputs.count == 1
                && adoption.finalizeInputs.count == 1,
            "adoptCue 成功必须恰好经过 begin→validate→recheck→scope→execute→bind→finalize")

        let importing = StubImportBindHooks(
            batch: stubBatch(
                accepted: [stubImportedFile],
                rejected: [stubRejectedFile("bad.mp3")]))
        importing.bindResult = .bound(
            SoundPackImportBindBinding(boundEvent: .stop, manifest: nil))
        importing.previewAction = preview
        let imported = await SoundPackImportBindTransaction(
            variant: .importAudio(bindsEvent: true), hooks: importing)
        .run()
        guard case .succeeded(let importSuccess) = imported,
            let importOutcome = importSuccess.importOutcome
        else {
            expect(false, "importAudio 成功必须携带 retained import outcome，实得 \(imported)")
            return
        }
        expect(
            importOutcome.boundEvent == .stop
                && importOutcome.completion == .partial(accepted: 1, rejected: 1)
                && importOutcome.accepted == [stubImportedFile]
                && importOutcome.rejected == [stubRejectedFile("bad.mp3")]
                && importOutcome.previewAction == preview
                && !importOutcome.completedInBackground,
            "importAudio 部分成功必须保留逐项 receipt、boundEvent 与 preview capability")
        expect(
            importing.settlements.map(\.phase) == [.partial(accepted: 1, rejected: 1)]
                && importing.settlements.first?.importOutcome != nil,
            "importAudio 部分成功必须以 matching partial phase settle 并保留同一 receipt")

        let publishing = StubImportBindHooks()
        let publishedFile = stubFile("cue.mp3")
            .renamed(to: "/tmp/packs/ai-cue-draft/cue.mp3")
        publishing.bindResult = .bound(SoundPackImportBindBinding(boundEvent: nil, manifest: manifest))
        publishing.finalizeResult = .finalized(imported: publishedFile)
        let published = await SoundPackImportBindTransaction(
            variant: .adoptCueDraftPublish, hooks: publishing)
        .run()
        guard case .succeeded(let publishSuccess) = published else {
            expect(false, "draft publish 成功必须返回 succeeded，实得 \(published)")
            return
        }
        expect(
            publishSuccess.imported == publishedFile
                && publishSuccess.previewAction == nil,
            "draft publish 成功必须返回发布后的最终文件身份且不签发 foreground preview")
        expect(
            publishing.discardCount == 0
                && publishing.settlements.map(\.phase) == [.succeeded],
            "draft publish 成功不得 discard 已搬空的 stage，且只 settle succeeded")
    }

    await suite("Import/bind transaction：cancel-before-start 不写盘、不 finish scope") {
        for variant in allTransactionVariants {
            let hooks = StubImportBindHooks()
            hooks.targetCheck = .cancelled
            let outcome = await SoundPackImportBindTransaction(
                variant: variant, hooks: hooks)
            .run()
            expect(
                outcome == .cancelled(
                    SoundPackImportBindCancelled(changedOnDisk: false, importOutcome: nil)),
                "\(variant) validate-cancelled 必须返回 changedOnDisk=false 的 cancelled")
            expect(
                hooks.settlements.map(\.phase) == [.cancelled(changedOnDisk: false)]
                    && hooks.executeCount == 0
                    && hooks.beginScopeCount == 0
                    && hooks.discardCount == 1,
                "\(variant) validate-cancelled 必须 discard 一次、零 execute、零 write scope")

            let midHooks = StubImportBindHooks()
            midHooks.execution = .cancelledBeforeWrite
            let midOutcome = await SoundPackImportBindTransaction(
                variant: variant, hooks: midHooks)
            .run()
            expect(
                midOutcome == .cancelled(
                    SoundPackImportBindCancelled(changedOnDisk: false, importOutcome: nil)),
                "\(variant) cancelledBeforeWrite 必须返回 changedOnDisk=false 的 cancelled")
            expect(
                midHooks.settlements.map(\.phase) == [.cancelled(changedOnDisk: false)]
                    && midHooks.discardCount == 1
                    && midHooks.bindInputs.isEmpty,
                "\(variant) cancelledBeforeWrite 必须 discard、零 bind、以 cancelled settle")
        }
        let realPack = StubImportBindHooks()
        realPack.execution = .cancelledBeforeWrite
        _ = await SoundPackImportBindTransaction(variant: .adoptCue, hooks: realPack).run()
        expect(
            realPack.finishWithoutChangeCount == 1,
            "真实包 cancelledBeforeWrite 必须关闭 compound mutation 且不请求 scan")
    }

    await suite("Import/bind transaction：cancel-mid-flight 按 variant 处理已落盘字节") {
        let adoption = StubImportBindHooks(executionCancellationRequested: true)
        let adoptedOutcome = await SoundPackImportBindTransaction(
            variant: .adoptCue, hooks: adoption)
        .run()
        expect(
            adoptedOutcome
                == .orphan(
                    SoundPackImportBindOrphan(
                        imported: stubImportedFile, failure: .cancelled, importOutcome: nil)),
            "真实包 adoption 中途取消必须把已落盘文件报告为 cancelled orphan")
        expect(
            adoption.settlements.map(\.phase)
                == [.orphan(fileName: stubImportedFile.fileName, failure: .cancelled)]
                && adoption.finishChangedDespiteFailure == [true]
                && adoption.discardCount == 0,
            "真实包 adoption 取消必须 changedDespiteFailure 落盘一次且不 discard")

        let sampled = StubImportBindHooks()
        sampled.cancellationRequestedOnSample = true
        let sampledOutcome = await SoundPackImportBindTransaction(
            variant: .adoptCue, hooks: sampled)
        .run()
        expect(
            sampledOutcome
                == .orphan(
                    SoundPackImportBindOrphan(
                        imported: stubImportedFile, failure: .cancelled, importOutcome: nil)),
            "executor 未报告的取消必须由 transaction 采样 cancellation token 补齐")

        let boundImport = StubImportBindHooks(executionCancellationRequested: true)
        let boundOutcome = await SoundPackImportBindTransaction(
            variant: .importAudio(bindsEvent: true), hooks: boundImport)
        .run()
        guard case .orphan(let boundOrphan) = boundOutcome else {
            expect(false, "带 bind 的 import 取消必须返回 orphan，实得 \(boundOutcome)")
            return
        }
        expect(
            boundOrphan.imported == stubImportedFile && boundOrphan.failure == .cancelled
                && boundOrphan.importOutcome?.completion == .orphan(.cancelled),
            "带 bind 的 import 取消必须把最后 accepted 留作 orphan 并保留 receipt")

        let unboundImport = StubImportBindHooks(executionCancellationRequested: true)
        let unboundOutcome = await SoundPackImportBindTransaction(
            variant: .importAudio(bindsEvent: false), hooks: unboundImport)
        .run()
        guard case .cancelled(let unboundCancelled) = unboundOutcome else {
            expect(false, "不带 bind 的 import 取消必须返回 cancelled，实得 \(unboundOutcome)")
            return
        }
        expect(
            unboundCancelled.changedOnDisk
                && unboundCancelled.importOutcome?.completion
                    == .cancelled(changedOnDisk: true)
                && unboundCancelled.importOutcome?.orphan == nil,
            "不带 bind 的 import 取消必须保留 accepted 文件并报告 changedOnDisk=true")
        expect(
            unboundImport.settlements.map(\.phase) == [.cancelled(changedOnDisk: true)],
            "不带 bind 的 import 取消必须以 changedOnDisk=true 的 cancelled phase settle")

        let draft = StubImportBindHooks(executionCancellationRequested: true)
        let draftOutcome = await SoundPackImportBindTransaction(
            variant: .adoptCueDraftPublish, hooks: draft)
        .run()
        expect(
            draftOutcome == .cancelled(
                SoundPackImportBindCancelled(changedOnDisk: false, importOutcome: nil)),
            "草稿中途取消必须 discard stage 并报告零磁盘变化，不得伪造 orphan")
        expect(
            draft.discardCount == 1
                && draft.settlements.map(\.phase) == [.cancelled(changedOnDisk: false)]
                && draft.finishChangedDespiteFailure.isEmpty,
            "草稿取消必须只 discard 一次，不得触碰 compound mutation")
    }

    await suite("Import/bind transaction：empty 结果按 variant 映射且保留逐项拒绝原因") {
        for variant in allTransactionVariants {
            let hooks = StubImportBindHooks(
                batch: stubBatch(
                    accepted: [],
                    rejected: [stubRejectedFile("evil.mp3")]))
            let outcome = await SoundPackImportBindTransaction(
                variant: variant, hooks: hooks)
            .run()
            guard case .empty(let empty) = outcome else {
                expect(false, "\(variant) 全部拒绝必须返回 empty，实得 \(outcome)")
                continue
            }
            if case .importAudio = variant {
                expect(
                    empty.importOutcome?.rejected == [stubRejectedFile("evil.mp3")]
                        && empty.importOutcome?.completion == .failed(.importRejected),
                    "\(variant) empty 必须保留逐项 rejected receipt")
            } else {
                expect(
                    empty.importOutcome == nil,
                    "\(variant) empty 不得伪造 import outcome")
            }
            expect(
                hooks.settlements.map(\.phase) == [.failed(.importRejected)]
                    && hooks.bindInputs.isEmpty,
                "\(variant) empty 必须以 importRejected settle 且永不 bind")
        }

        let cancelled = StubImportBindHooks(
            batch: stubBatch(accepted: [], rejected: [stubRejectedFile("evil.mp3")]),
            executionCancellationRequested: true)
        let cancelledOutcome = await SoundPackImportBindTransaction(
            variant: .importAudio(bindsEvent: true), hooks: cancelled)
        .run()
        guard case .cancelled(let cancelledEmpty) = cancelledOutcome else {
            expect(false, "empty+cancelled 必须返回 cancelled，实得 \(cancelledOutcome)")
            return
        }
        expect(
            !cancelledEmpty.changedOnDisk
                && cancelledEmpty.importOutcome?.completion
                    == .cancelled(changedOnDisk: false),
            "empty+cancelled 必须保留 receipt 且报告零磁盘变化")
        expect(
            cancelled.settlements.map(\.phase) == [.cancelled(changedOnDisk: false)],
            "empty+cancelled 必须以 changedOnDisk=false 的 cancelled phase settle")
    }

    await suite("Import/bind transaction：bind 失败的 typed 归因与 cleanup") {
        let targetGone = StubImportBindHooks()
        targetGone.bindResult = .failed(.targetChanged)
        let targetGoneOutcome = await SoundPackImportBindTransaction(
            variant: .adoptCue, hooks: targetGone)
        .run()
        expect(
            targetGoneOutcome
                == .orphan(
                    SoundPackImportBindOrphan(
                        imported: stubImportedFile, failure: .targetChanged, importOutcome: nil)),
            "真实包 bind 的 targetChanged 必须保留 typed 归因的 orphan")
        expect(
            targetGone.finishChangedDespiteFailure == [true],
            "真实包 bind 失败必须以 changedDespiteFailure 关闭 scope")

        let bindError = StubImportBindHooks()
        bindError.bindResult = .failed(.mutationFailed)
        let bindErrorOutcome = await SoundPackImportBindTransaction(
            variant: .adoptCue, hooks: bindError)
        .run()
        expect(
            bindErrorOutcome
                == .orphan(
                    SoundPackImportBindOrphan(
                        imported: stubImportedFile, failure: .mutationFailed,
                        importOutcome: nil)),
            "真实包 bind 的其他失败必须映射为 mutationFailed orphan")

        let draft = StubImportBindHooks()
        draft.bindResult = .failed(.mutationFailed)
        let draftOutcome = await SoundPackImportBindTransaction(
            variant: .adoptCueDraftPublish, hooks: draft)
        .run()
        expect(
            draftOutcome == .failed(.mutationFailed),
            "草稿 bind 失败必须 discard stage 并返回 typed failure，不得留下空包")
        expect(
            draft.discardCount == 1
                && draft.settlements.map(\.phase) == [.failed(.mutationFailed)]
                && draft.finalizeInputs.isEmpty,
            "草稿 bind 失败必须只 discard，不得进入 finalize/publish")

        let importing = StubImportBindHooks()
        importing.bindResult = .failed(.mutationFailed)
        let importOutcome = await SoundPackImportBindTransaction(
            variant: .importAudio(bindsEvent: true), hooks: importing)
        .run()
        guard case .orphan(let importOrphan) = importOutcome else {
            expect(false, "import bind 失败必须返回 orphan，实得 \(importOutcome)")
            return
        }
        expect(
            importOrphan.failure == .mutationFailed
                && importOrphan.importOutcome?.completedInBackground == false,
            "foreground 的 import bind mutationFailed 不得误标 background 完成")
    }

    await suite("Import/bind transaction：stale target 与 freshness 丢失 fail closed") {
        for variant in allTransactionVariants {
            let staleWrites = StubImportBindHooks()
            staleWrites.currencyBeforeWrite = .stale(writesAllowed: true)
            let staleOutcome = await SoundPackImportBindTransaction(
                variant: variant, hooks: staleWrites)
            .run()
            expect(
                staleOutcome == .failed(.stalePermit)
                    && staleWrites.executeCount == 0
                    && staleWrites.settlements.map(\.phase) == [.failed(.stalePermit)],
                "\(variant) pre-write stale（仍可写）必须归因 stalePermit 且零 execute")

            let scopeLost = StubImportBindHooks()
            scopeLost.currencyBeforeWrite = .stale(writesAllowed: false)
            let scopeOutcome = await SoundPackImportBindTransaction(
                variant: variant, hooks: scopeLost)
            .run()
            expect(
                scopeOutcome == .failed(.scopeUnavailable),
                "\(variant) pre-write stale（写入已停）必须归因 scopeUnavailable")

            let unavailable = StubImportBindHooks()
            unavailable.targetCheck = .unavailable
            unavailable.reobservedWritesAllowed = true
            let unavailableOutcome = await SoundPackImportBindTransaction(
                variant: variant, hooks: unavailable)
            .run()
            expect(
                unavailableOutcome == .failed(.packUnavailable)
                    && unavailable.discardCount == 1,
                "\(variant) target unavailable（仍可写）必须归因 packUnavailable 并 discard")

            let unavailableScope = StubImportBindHooks()
            unavailableScope.targetCheck = .unavailable
            unavailableScope.reobservedWritesAllowed = false
            let unavailableScopeOutcome = await SoundPackImportBindTransaction(
                variant: variant, hooks: unavailableScope)
            .run()
            expect(
                unavailableScopeOutcome == .failed(.scopeUnavailable),
                "\(variant) target unavailable（写入已停）必须归因 scopeUnavailable")
        }

        let staleAdoption = StubImportBindHooks()
        staleAdoption.currencyAfterWrite = false
        let staleAdoptionOutcome = await SoundPackImportBindTransaction(
            variant: .adoptCue, hooks: staleAdoption)
        .run()
        expect(
            staleAdoptionOutcome
                == .orphan(
                    SoundPackImportBindOrphan(
                        imported: stubImportedFile, failure: .targetChanged,
                        importOutcome: nil)),
            "真实包 post-write 目标漂移必须保留 typed orphan 且不得 bind")
        expect(
            staleAdoption.bindInputs.isEmpty,
            "post-write 目标漂移后不得尝试 bind")

        let staleDraft = StubImportBindHooks()
        staleDraft.currencyAfterWrite = false
        let staleDraftOutcome = await SoundPackImportBindTransaction(
            variant: .adoptCueDraftPublish, hooks: staleDraft)
        .run()
        expect(
            staleDraftOutcome == .failed(.targetChanged)
                && staleDraft.discardCount == 1
                && staleDraft.bindInputs.isEmpty,
            "草稿 post-write 目标漂移必须 discard stage 并归因 targetChanged")

        let staleImport = StubImportBindHooks()
        staleImport.currencyAfterWrite = false
        let staleImportOutcome = await SoundPackImportBindTransaction(
            variant: .importAudio(bindsEvent: true), hooks: staleImport)
        .run()
        guard case .orphan(let staleImportOrphan) = staleImportOutcome else {
            expect(false, "带 bind 的 import post-write 漂移必须 orphan，实得 \(staleImportOutcome)")
            return
        }
        expect(
            staleImportOrphan.failure == .targetChanged
                && staleImportOrphan.importOutcome?.completedInBackground == true,
            "带 bind 的 import post-write 漂移必须 orphan 且标记 background 完成")

        let driftingUnbound = StubImportBindHooks()
        driftingUnbound.currencyAfterWrite = false
        let driftingOutcome = await SoundPackImportBindTransaction(
            variant: .importAudio(bindsEvent: false), hooks: driftingUnbound)
        .run()
        guard case .succeeded(let driftingSuccess) = driftingOutcome else {
            expect(false, "不带 bind 的 import 漂移仍必须成功，实得 \(driftingOutcome)")
            return
        }
        expect(
            driftingSuccess.importOutcome?.completedInBackground == true
                && driftingSuccess.previewAction == nil,
            "不带 bind 的 import 漂移只丢失 foreground 后续动作，不丢弃已落盘文件")
    }

    await suite("Import/bind transaction：草稿 finalize 的 orphan stage 统一清理") {
        let manifest = AICueManifestBindingOutcome(
            event: .stop, fileName: "cue.mp3", finalDisplayName: "完成")

        let stale = StubImportBindHooks()
        stale.finalizeResult = .stale
        let staleOutcome = await SoundPackImportBindTransaction(
            variant: .adoptCueDraftPublish, hooks: stale)
        .run()
        expect(
            staleOutcome == .failed(.targetChanged)
                && stale.discardCount == 1
                && stale.settlements.map(\.phase) == [.failed(.targetChanged)],
            "草稿 bind 后目标漂移必须 discard stage 并归因 targetChanged，不得发布")

        let cancelled = StubImportBindHooks()
        cancelled.finalizeResult = .cancelled
        let cancelledOutcome = await SoundPackImportBindTransaction(
            variant: .adoptCueDraftPublish, hooks: cancelled)
        .run()
        expect(
            cancelledOutcome == .cancelled(
                SoundPackImportBindCancelled(changedOnDisk: false, importOutcome: nil))
                && cancelled.discardCount == 1
                && cancelled.settlements.map(\.phase) == [.cancelled(changedOnDisk: false)],
            "草稿 bind 后取消必须归因 cancelled（统一前误报 targetChanged），并 discard stage")

        let failed = StubImportBindHooks()
        failed.finalizeResult = .failed(.mutationFailed)
        let failedOutcome = await SoundPackImportBindTransaction(
            variant: .adoptCueDraftPublish, hooks: failed)
        .run()
        expect(
            failedOutcome == .failed(.mutationFailed)
                && failed.discardCount == 1,
            "草稿 publish 失败必须 discard stage 并返回 typed failure，不得声称发布")
        expect(
            manifest.finalDisplayName == "完成",
            "fixture manifest receipt 必须保持可比较（占位 sanity check）")
    }

    await suite("Import/bind transaction：draft 与非 draft 的失败归因完全等价") {
        // The unified canonical mapping: identical envelope inputs must produce identical
        // failure attribution for the staged-draft and real-pack variants; only the remnant
        // policy (discard vs orphan) may differ.
        for variant in [SoundPackImportBindVariant.adoptCue, .adoptCueDraftPublish] {
            let cancelled = StubImportBindHooks(
                batch: stubBatch(accepted: []),
                executionCancellationRequested: true)
            let cancelledOutcome = await SoundPackImportBindTransaction(
                variant: variant, hooks: cancelled)
            .run()
            expect(
                cancelledOutcome == .cancelled(
                    SoundPackImportBindCancelled(changedOnDisk: false, importOutcome: nil)),
                "\(variant) 空批次+取消必须一致返回 changedOnDisk=false 的 cancelled")

            let staleEmpty = StubImportBindHooks(batch: stubBatch(accepted: []))
            staleEmpty.currencyAfterWrite = false
            let staleEmptyOutcome = await SoundPackImportBindTransaction(
                variant: variant, hooks: staleEmpty)
            .run()
            expect(
                staleEmptyOutcome == .failed(.targetChanged),
                "\(variant) 空批次+目标漂移必须一致归因 targetChanged（revalidation 优先于 empty）")
        }
        expect(
            SoundPackImportBindVariant.importAudio(bindsEvent: true)
                != .importAudio(bindsEvent: false),
            "import variant 必须区分是否携带 Event bind 请求")
    }
}

private let allTransactionVariants: [SoundPackImportBindVariant] = [
    .adoptCue,
    .adoptCueDraftPublish,
    .importAudio(bindsEvent: true),
    .importAudio(bindsEvent: false),
]

private let stubImportedFile = stubFile("cue.mp3")

private func stubFile(_ name: String, packID: String = "pack-a") -> ImportedAudioFile {
    ImportedAudioFile(
        packID: packID,
        destinationURL: URL(fileURLWithPath: "/tmp/packs/\(packID)/\(name)"),
        fileName: name,
        format: .mp3,
        fileSizeBytes: 128,
        duration: 1)
}

private func stubBatch(
    accepted: [ImportedAudioFile],
    rejected: [RejectedAudioFile] = []
) -> AudioImportBatchResult {
    AudioImportBatchResult(accepted: accepted, rejected: rejected)
}

private func stubRejectedFile(_ name: String) -> RejectedAudioFile {
    RejectedAudioFile(sourceFileName: name, reason: .nonWhitelistFormat)
}

extension ImportedAudioFile {
    fileprivate func renamed(to path: String) -> ImportedAudioFile {
        ImportedAudioFile(
            packID: packID,
            destinationURL: URL(fileURLWithPath: path),
            fileName: fileName,
            format: format,
            fileSizeBytes: fileSizeBytes,
            duration: duration)
    }
}

/// Scripted ``SoundPackImportBindTransactionHooks`` double. Every method records its call so a
/// suite can pin the exact envelope order and the settled terminal facts without any disk I/O.
@MainActor
private final class StubImportBindHooks: SoundPackImportBindTransactionHooks {
    var targetCheck: SoundPackImportBindTargetCheck = .available
    var reobservedWritesAllowed = true
    var currencyBeforeWrite: SoundPackImportBindCurrencyCheck = .current
    var batch: AudioImportBatchResult
    var execution: SoundPackImportBindExecution
    var cancellationRequestedOnSample = false
    var currencyAfterWrite = true
    var bindResult: SoundPackImportBindResult = .bound(
        SoundPackImportBindBinding(boundEvent: .stop, manifest: nil))
    var finalizeResult: SoundPackImportBindFinalize?
    var previewAction: SoundPackEditorAction?

    private(set) var beginOperationCount = 0
    private(set) var reobserveCount = 0
    private(set) var recheckCount = 0
    private(set) var beginScopeCount = 0
    private(set) var executeCount = 0
    private(set) var postWriteCurrencyCount = 0
    private(set) var bindInputs: [SoundPackImportBindInput] = []
    private(set) var finalizeInputs: [SoundPackImportBindInput] = []
    private(set) var finishWithoutChangeCount = 0
    private(set) var finishChangedDespiteFailure: [Bool] = []
    private(set) var discardCount = 0
    private(set) var signPreviewCount = 0
    private(set) var settlements:
        [(
            phase: SoundPackEditorActivityPhase,
            importOutcome: SoundPackEditorImportOutcome?
        )] = []

    init(
        batch: AudioImportBatchResult = stubBatch(accepted: [stubImportedFile]),
        executionCancellationRequested: Bool = false
    ) {
        self.batch = batch
        self.execution = .completed(
            batch,
            cancellationRequested: executionCancellationRequested)
    }

    func beginOperation() -> SoundPackEditorOperationID {
        beginOperationCount += 1
        return SoundPackEditorOperationID(rawValue: 1)
    }

    func validateTarget() async -> SoundPackImportBindTargetCheck { targetCheck }

    func reobserveUnavailableTarget() async -> Bool {
        reobserveCount += 1
        return reobservedWritesAllowed
    }

    func recheckTargetCurrencyBeforeWrite() -> SoundPackImportBindCurrencyCheck {
        recheckCount += 1
        return currencyBeforeWrite
    }

    func beginWriteScope() { beginScopeCount += 1 }

    func executeImport() async -> SoundPackImportBindExecution {
        executeCount += 1
        return execution
    }

    func cancellationIsRequested() -> Bool { cancellationRequestedOnSample }

    func targetRemainsCurrentAfterWrite() -> Bool {
        postWriteCurrencyCount += 1
        return currencyAfterWrite
    }

    func bindImportedAudio(_ input: SoundPackImportBindInput) -> SoundPackImportBindResult {
        bindInputs.append(input)
        return bindResult
    }

    func finalizeBinding(_ input: SoundPackImportBindInput) -> SoundPackImportBindFinalize {
        finalizeInputs.append(input)
        return finalizeResult ?? .finalized(imported: input.imported)
    }

    func finishWriteScopeWithoutChange() { finishWithoutChangeCount += 1 }

    func finishWriteScope(changedDespiteFailure: Bool) {
        finishChangedDespiteFailure.append(changedDespiteFailure)
    }

    func discardStagedRemnants() { discardCount += 1 }

    func signForegroundPreview(for imported: ImportedAudioFile) -> SoundPackEditorAction? {
        signPreviewCount += 1
        return previewAction
    }

    func settleOperation(
        _ operationID: SoundPackEditorOperationID,
        phase: SoundPackEditorActivityPhase,
        importOutcome: SoundPackEditorImportOutcome?
    ) {
        settlements.append((phase: phase, importOutcome: importOutcome))
    }
}
