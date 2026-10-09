import ClaudioGUICore
import ClaudioLocalization
import ClaudioSettingsPresentation
import Darwin
import Foundation

private actor BailianLocalKeychainUnavailableVault: AICueCredentialVault {
    private var item: SensitiveCredentialInput?
    private(set) var retiredAccesses = 0

    private func requireBailian(_ slotID: AICueCredentialSlotID) throws {
        guard slotID == .bailianBeijing else {
            retiredAccesses += 1
            throw AICueKeychainError.unexpectedStatus(operation: "delete", status: -34018)
        }
    }

    func containsCredential(in slotID: AICueCredentialSlotID) throws -> Bool {
        try requireBailian(slotID)
        return item != nil
    }

    func credential(in slotID: AICueCredentialSlotID) throws -> SensitiveCredentialInput? {
        try requireBailian(slotID)
        return item
    }

    func replaceCredential(_ credential: SensitiveCredentialInput, in slotID: AICueCredentialSlotID)
        throws
    {
        try requireBailian(slotID)
        item = credential
    }

    func deleteCredential(in slotID: AICueCredentialSlotID) throws {
        try requireBailian(slotID)
        item = nil
    }
}

private actor BailianLocalProbe: AICueCredentialValidating {
    private var rejected = false
    func reject() { rejected = true }
    func validateCredential(_ credential: SensitiveCredentialInput) throws {
        if rejected { throw AICueProviderError.requiredModelsUnavailable }
    }
}

private actor BailianLocalMetadata: AICueCredentialMetadataStoring {
    func verification(for profileID: AICueProviderProfileID) -> AICueCredentialVerification? { nil }
    func setVerification(
        _ verification: AICueCredentialVerification?, for profileID: AICueProviderProfileID
    ) {}
}

private struct BailianLocalStagingFailure: AICueLocalCredentialACLReading {
    func hasEntries(on descriptor: Int32) throws -> Bool {
        if fcntl(descriptor, F_GETFL) & O_ACCMODE == O_WRONLY {
            throw AICueLocalCredentialError.unavailable
        }
        return try AICueLocalCredentialSystemACLReader().hasEntries(on: descriptor)
    }
}

@MainActor
func runBailianLocalCredentialSuites() async {
    await suite("百炼本地配置：旧 Keychain 不可用不阻止显式保存新配置") {
        let vault = BailianLocalKeychainUnavailableVault()
        let manager = AICueCredentialManager(
            vault: vault, validators: [.bailianBeijing: BailianLocalProbe()],
            metadata: BailianLocalMetadata())
        do {
            let saved = try await manager.save(
                SensitiveCredentialInput(
                    apiKey: "fixture-only-bailian-local",
                    bailianWorkspaceID: BailianWorkspaceID("fixture-workspace")),
                for: .bailianBeijing)
            expect(
                saved == .stored(verification: .deferred, hasPendingReplacement: false),
                "权限检查后保存完整新配置，不把真实生成标为已验证")
            try await manager.delete(for: .bailianBeijing)
            expect(await manager.status(for: .bailianBeijing) == .missing, "删除只影响百炼新配置")
        } catch {
            expect(false, "本地百炼配置不能被旧 Keychain entitlement 阻断")
        }
        expect(await vault.retiredAccesses == 0, "本地百炼操作不读取、迁移或删除旧 Keychain 槽")
    }

    await suite("百炼本地配置：完整保存、重新装配、验证状态和权限失败保留旧配置") {
        await withTempDirectory { temporary in
            let root = temporary.resolvingSymlinksInPath().appendingPathComponent("Credentials")
            let file = root.appendingPathComponent("bailian-beijing.json")
            let keychain = BailianLocalKeychainUnavailableVault()
            let probe = BailianLocalProbe()
            func newManager() -> AICueCredentialManager {
                AICueCredentialManager(
                    vault: AICueAppCredentialVault(
                        keychain: keychain,
                        senseAudio: SenseAudioFileCredentialVault(directory: root),
                        bailian: AICueFileCredentialVault(kind: .bailianBeijing, directory: root)),
                    validators: [.bailianBeijing: probe], metadata: BailianLocalMetadata())
            }
            let manager = newManager()
            expect(await manager.status(for: .bailianBeijing) == .missing, "初始未配置")
            try! await manager.delete(for: .bailianBeijing)
            expect(!FileManager.default.fileExists(atPath: root.path), "状态和缺失删除不创建文件")
            do {
                let saved = try await manager.save(
                    SensitiveCredentialInput(
                        apiKey: "fixture-only-complete-local",
                        bailianWorkspaceID: BailianWorkspaceID("fixture-original")),
                    for: .bailianBeijing)
                expect(
                    saved == .stored(verification: .deferred, hasPendingReplacement: false),
                    "权限成功不冒充真实生成验证")
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                let directoryAttrs = try FileManager.default.attributesOfItem(atPath: root.path)
                expect(attrs[.posixPermissions] as? Int == 0o600, "配置文件仅当前用户可读写")
                expect(directoryAttrs[.posixPermissions] as? Int == 0o700, "目录仅当前用户可访问")
                let restarted = newManager()
                expect(await restarted.status(for: .bailianBeijing) == saved, "新 manager 从文件恢复状态")
                let lease = try await restarted.credentialForGeneration(for: .bailianBeijing)
                expect(
                    lease.credential.bailianWorkspaceID?.rawValue == "fixture-original",
                    "重启后完整业务空间与 Key 同一配置租约")
                try await restarted.generationDidValidate(lease)
                expect(
                    await newManager().status(for: .bailianBeijing)
                        == .stored(verification: .verified, hasPendingReplacement: false),
                    "模拟生成验证状态与完整配置一起持久化")
                let previous = try Data(contentsOf: file)
                await probe.reject()
                do {
                    _ = try await restarted.save(
                        SensitiveCredentialInput(
                            apiKey: "fixture-only-rejected-new",
                            bailianWorkspaceID: BailianWorkspaceID("fixture-rejected")),
                        for: .bailianBeijing)
                    expect(false, "权限拒绝不能替换配置")
                } catch {
                    expect(
                        error as? AICueProviderError == .requiredModelsUnavailable,
                        "保留权限失败原因")
                }
                expect(try Data(contentsOf: file) == previous, "失败保留旧 Key、业务空间和验证状态")
                let restoredLease = try await newManager().credentialForGeneration(
                    for: .bailianBeijing)
                expect(
                    restoredLease.credential.bailianWorkspaceID?.rawValue == "fixture-original",
                    "拒绝后仍取用原业务空间")
                try await restarted.delete(for: .bailianBeijing)
                expect(await newManager().status(for: .bailianBeijing) == .missing, "删除后新进程投影未配置")
                expect(await keychain.retiredAccesses == 0, "整条配置链不触碰任何旧 Keychain 槽")
            } catch { expect(false, "本地完整配置生命周期应成功") }
        }
    }

    await suite("百炼本地配置：不安全文件、损坏记录、staging 故障不覆盖旧值") {
        await withTempDirectory { temporary in
            let root = temporary.resolvingSymlinksInPath().appendingPathComponent("Credentials")
            let file = root.appendingPathComponent("bailian-beijing.json")
            let vault = AICueFileCredentialVault(kind: .bailianBeijing, directory: root)
            let old = try! SensitiveCredentialInput(
                apiKey: "fixture-only-preserved",
                bailianWorkspaceID: BailianWorkspaceID("fixture-original"))
            try! await vault.replaceCredential(old, in: .bailianBeijing)
            let previous = try! Data(contentsOf: file)
            let faulting = AICueFileCredentialVault(
                kind: .bailianBeijing, directory: root, aclReader: BailianLocalStagingFailure())
            do {
                try await faulting.replaceCredential(
                    SensitiveCredentialInput(
                        apiKey: "fixture-only-staging-new",
                        bailianWorkspaceID: BailianWorkspaceID("fixture-new")),
                    in: .bailianBeijing)
                expect(false, "staging 检查故障必须拒绝")
            } catch { expect(error as? AICueLocalCredentialError == .unavailable, "错误不含 Key 或路径") }
            expect(try! Data(contentsOf: file) == previous, "staging 故障保留完整旧配置")
            expect(
                try! FileManager.default.contentsOfDirectory(atPath: root.path) == [
                    "bailian-beijing.json"
                ],
                "失败后不留下临时凭据")
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: file.path)
            do {
                _ = try await vault.credential(in: .bailianBeijing)
                expect(false, "权限过宽不得读取")
            } catch { expect(error as? AICueLocalCredentialError == .unavailable, "不安全文件不可用") }
            do {
                try await vault.replaceCredential(old, in: .bailianBeijing)
                expect(false, "不得自动修复并替换权限过宽的旧文件")
            } catch { expect(true, "保留不安全对象供用户处理") }
            expect(try! Data(contentsOf: file) == previous, "不安全文件未被写入")
            try! FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
            for malformed in [
                Data(), Data("{}".utf8), Data([0xff]), Data(repeating: 65, count: 2049),
            ] {
                try! malformed.write(to: file)
                do {
                    _ = try await vault.credential(in: .bailianBeijing)
                    expect(false, "损坏或超限配置必须关闭")
                } catch { expect(error as? AICueLocalCredentialError == .unavailable, "错误不包含记录内容") }
            }
        }
    }

    suite("百炼本地配置：双语披露真实文件政策和恢复操作") {
        let profile = try! AICueProviderRegistry().profile(for: .bailianBeijing)
        expect(
            profile.credentialStorageDisclosureKey == .aiCueCredentialLocalConfiguration,
            "表单披露完整本地配置，不能冒充 Keychain")
        for language in ClaudioAppLanguage.allCases {
            let l10n = ClaudioL10n(language: language)
            expect(!l10n.text(.aiCueCredentialLocalConfiguration).isEmpty, "两种语言均有明文和权限说明")
            expect(
                aiCueCredentialFailureText(
                    .storageUnavailable, providerProfileID: .bailianBeijing,
                    credentialStatus: .missing, l10n: l10n)
                    == l10n.text(.aiCueErrorLocalCredentialUnavailable),
                "本地配置故障提供文件权限恢复，不提示解锁 Keychain")
        }
    }
}
