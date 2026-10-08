import ClaudioGUICore
import Foundation

private enum CredentialFixtureError: Error, Sendable, Equatable {
    case rejected
    case writeFailed
    case deleteFailed
}

private actor CredentialVaultFixture: AICueCredentialVault {
    private var items: [AICueCredentialSlotID: SensitiveCredentialInput]
    private let failingReplacements: Set<AICueCredentialSlotID>
    private let failingDeletions: Set<AICueCredentialSlotID>
    private(set) var reads: [AICueCredentialSlotID] = []
    private(set) var replacements: [AICueCredentialSlotID] = []
    private(set) var deletions: [AICueCredentialSlotID] = []

    init(
        items: [AICueCredentialSlotID: SensitiveCredentialInput] = [:],
        failingReplacements: Set<AICueCredentialSlotID> = [],
        failingDeletions: Set<AICueCredentialSlotID> = []
    ) {
        self.items = items
        self.failingReplacements = failingReplacements
        self.failingDeletions = failingDeletions
    }

    func containsCredential(in slotID: AICueCredentialSlotID) async throws -> Bool {
        reads.append(slotID)
        return items[slotID] != nil
    }

    func credential(in slotID: AICueCredentialSlotID) async throws -> SensitiveCredentialInput? {
        reads.append(slotID)
        return items[slotID]
    }

    func replaceCredential(
        _ credential: SensitiveCredentialInput,
        in slotID: AICueCredentialSlotID
    ) async throws {
        replacements.append(slotID)
        if failingReplacements.contains(slotID) { throw CredentialFixtureError.writeFailed }
        items[slotID] = credential
    }

    func deleteCredential(in slotID: AICueCredentialSlotID) async throws {
        deletions.append(slotID)
        if failingDeletions.contains(slotID) { throw CredentialFixtureError.deleteFailed }
        items.removeValue(forKey: slotID)
    }

    func item(in slotID: AICueCredentialSlotID) -> SensitiveCredentialInput? {
        items[slotID]
    }

    func facts() -> (
        reads: [AICueCredentialSlotID],
        replacements: [AICueCredentialSlotID],
        deletions: [AICueCredentialSlotID]
    ) {
        (reads, replacements, deletions)
    }
}

private actor CredentialValidatorFixture: AICueCredentialValidating {
    private let result: Result<Void, CredentialFixtureError>
    private(set) var validationCount = 0

    init(result: Result<Void, CredentialFixtureError>) {
        self.result = result
    }

    func validateCredential(_ credential: SensitiveCredentialInput) async throws {
        validationCount += 1
        try result.get()
    }

    func count() -> Int { validationCount }
}

private actor CredentialMetadataFixture: AICueCredentialMetadataStoring {
    private var values: [AICueProviderProfileID: AICueCredentialVerification]

    init(values: [AICueProviderProfileID: AICueCredentialVerification] = [:]) {
        self.values = values
    }

    func verification(
        for profileID: AICueProviderProfileID
    ) -> AICueCredentialVerification? {
        values[profileID]
    }

    func setVerification(
        _ verification: AICueCredentialVerification?,
        for profileID: AICueProviderProfileID
    ) {
        values[profileID] = verification
    }
}

@MainActor
func runAICueCredentialSuites() async {
    await suite("AI 提示音凭据：registry slot 直接复用 legacy account 并隔离地区") {
        let vault = CredentialVaultFixture(items: [
            .legacyElevenLabs: try! SensitiveCredentialInput("legacy-eleven-key"),
            .qwenSingapore: try! SensitiveCredentialInput("singapore-key"),
        ])
        let manager = makeCredentialManager(vault: vault)

        expect(
            await manager.status(for: .elevenLabsGlobal)
                == .stored(verification: .deferred, hasPendingReplacement: false),
            "旧安装必须直接读取 account elevenlabs，不能要求迁移")
        expect(
            await manager.status(for: .qwenSingapore)
                == .unavailable,
            "Singapore 必须只投影自己的 active slot")
        expect(
            await manager.status(for: .qwenBeijing) == .unavailable,
            "Beijing 不得交叉读取 Singapore key")
        let reads = await vault.facts().reads.map(\.rawValue)
        expect(reads.contains("elevenlabs"), "ElevenLabs 必须读取旧 account elevenlabs")
        expect(!reads.contains("elevenlabs-global"), "不得创建或读取新 account elevenlabs-global")
    }

    await suite("AI 提示音凭据：read-only profile probe 成功后才原子替换") {
        let old = try! SensitiveCredentialInput("old-minimax-key")
        let new = try! SensitiveCredentialInput("new-minimax-key")
        let vault = CredentialVaultFixture(items: [.miniMaxGlobal: old])
        let probe = CredentialValidatorFixture(result: .success(()))
        let manager = makeCredentialManager(
            vault: vault,
            validators: [.miniMaxGlobal: probe])

        let status = try! await manager.save(new, for: .miniMaxGlobal)
        expect(await probe.count() == 1, "MiniMax 保存前必须恰好执行一次只读 probe")
        expect(
            await vault.item(in: .miniMaxGlobal) === new,
            "probe 成功后必须原子替换 registry 固定 active slot")
        expect(
            status == .stored(verification: .verified, hasPendingReplacement: false),
            "只读 probe 成功后状态必须明确为 verified")
    }

    await suite("AI 提示音凭据：probe 或 Keychain 失败保留旧 active") {
        let old = try! SensitiveCredentialInput("old-eleven-key")
        let rejectedVault = CredentialVaultFixture(items: [.legacyElevenLabs: old])
        let rejectedProbe = CredentialValidatorFixture(result: .failure(.rejected))
        let rejectedManager = makeCredentialManager(
            vault: rejectedVault,
            validators: [.elevenLabsGlobal: rejectedProbe])
        do {
            _ = try await rejectedManager.save(
                try SensitiveCredentialInput("rejected-key"),
                for: .elevenLabsGlobal)
        } catch {}
        expect(
            await rejectedVault.item(in: .legacyElevenLabs) === old,
            "probe 拒绝不能触发旧 key 删除或覆盖")
        expect(
            await rejectedVault.facts().replacements.isEmpty,
            "probe 失败不得进入 Keychain 写入")

        let failingVault = CredentialVaultFixture(
            items: [.legacyElevenLabs: old],
            failingReplacements: [.legacyElevenLabs])
        let passingProbe = CredentialValidatorFixture(result: .success(()))
        let failingManager = makeCredentialManager(
            vault: failingVault,
            validators: [.elevenLabsGlobal: passingProbe])
        do {
            _ = try await failingManager.save(
                try SensitiveCredentialInput("valid-but-unwritable"),
                for: .elevenLabsGlobal)
        } catch {}
        expect(
            await failingVault.item(in: .legacyElevenLabs) === old,
            "Keychain 原子替换失败必须保留旧 active")
    }

    await suite("AI 提示音凭据：gated SenseAudio 只读 probe 使用独立 slot 并保留旧 key") {
        let registry = senseAudioCredentialFixtureRegistry()
        let old = try! SensitiveCredentialInput("old-senseaudio-key")
        let replacement = try! SensitiveCredentialInput("new-senseaudio-key")
        let vault = CredentialVaultFixture(items: [.senseAudioChina: old])
        let passingProbe = CredentialValidatorFixture(result: .success(()))
        let manager = makeCredentialManager(
            vault: vault,
            registry: registry,
            validators: [.senseAudioChina: passingProbe])

        let status = try! await manager.save(replacement, for: .senseAudioChina)
        expect(await passingProbe.count() == 1, "SenseAudio 保存前必须恰好执行一次只读 voice probe")
        expect(
            await vault.item(in: .senseAudioChina) === replacement,
            "通过 probe 后只能原子替换 senseaudio-cn active slot")
        expect(
            status == .stored(verification: .verified, hasPendingReplacement: false),
            "SenseAudio 成功保存后必须投影 verified 且没有 pending slot")

        let rejected = CredentialValidatorFixture(result: .failure(.rejected))
        let rejectedManager = makeCredentialManager(
            vault: vault,
            registry: registry,
            validators: [.senseAudioChina: rejected])
        do {
            _ = try await rejectedManager.save(
                try SensitiveCredentialInput("rejected-senseaudio-key"),
                for: .senseAudioChina)
        } catch {}
        expect(
            await vault.item(in: .senseAudioChina) === replacement,
            "SenseAudio probe 失败不得覆盖已经验证的 active key")
        expect(
            await vault.facts().replacements == [.senseAudioChina],
            "失败的 SenseAudio probe 不得触发第二次 Keychain 写入")
    }

    suite("AI 提示音凭据：一次性输入和 generation lease 的描述不泄漏") {
        let secret = "fixture-secret-must-not-appear"
        let credential = try! SensitiveCredentialInput("  \(secret)  ")
        let lease = AICueGenerationCredential(
            profileID: .qwenSingapore,
            credential: credential,
            source: .pending,
            revision: 0)
        expect(
            !String(describing: credential).contains(secret)
                && !String(reflecting: credential).contains(secret)
                && !String(describing: lease).contains(secret)
                && !String(reflecting: lease).contains(secret),
            "默认描述和反射不得包含明文 key")
        expect(
            throwsCredentialInput { _ = try SensitiveCredentialInput("   ") },
            "空 key 必须在 provider 前拒绝")
        expect(
            throwsCredentialInput { _ = try SensitiveCredentialInput("line1\nline2") },
            "带换行/控制字符的 key 必须拒绝")
    }
}

private func makeCredentialManager(
    vault: CredentialVaultFixture,
    registry: AICueProviderRegistry = AICueProviderRegistry(),
    validators: [AICueProviderProfileID: any AICueCredentialValidating] = [:]
) -> AICueCredentialManager {
    AICueCredentialManager(
        vault: vault,
        registry: registry,
        validators: validators,
        metadata: CredentialMetadataFixture())
}

private func senseAudioCredentialFixtureRegistry() -> AICueProviderRegistry {
    let policy = try! AICueAssetPolicy(
        allowedOrigins: [try! AICueAssetOrigin("https://assets.fixture.invalid")],
        acceptedMediaTypes: ["audio/mpeg"])
    return AICueProviderRegistry(evidenceGatedSenseAudioAssetPolicy: policy)
}

private func throwsCredentialInput(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch is AICueCredentialInputError {
        return true
    } catch {
        return false
    }
}
