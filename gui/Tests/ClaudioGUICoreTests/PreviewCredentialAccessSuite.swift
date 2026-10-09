import ClaudioGUICore
import Foundation

private actor PreviewCredentialVault: AICueCredentialVault {
    var touches: [AICueCredentialSlotID] = []
    func containsCredential(in slotID: AICueCredentialSlotID) -> Bool {
        touches.append(slotID); return false
    }
    func credential(in slotID: AICueCredentialSlotID) -> SensitiveCredentialInput? {
        touches.append(slotID); return nil
    }
    func replaceCredential(_ credential: SensitiveCredentialInput, in slotID: AICueCredentialSlotID)
    { touches.append(slotID) }
    func deleteCredential(in slotID: AICueCredentialSlotID) { touches.append(slotID) }
    func snapshot() -> [AICueCredentialSlotID] { touches }
}

@MainActor
func runPreviewCredentialAccessSuites() async {
    suite("构建存储能力：预览标记由编译合同决定") {
        #if CLAUDIO_PUBLIC_PREVIEW
        expect(
            !AICueCredentialAccessPolicy.currentBuild.permitsDataProtectionKeychain,
            "预览编译必须关闭 Data Protection Keychain")
        #else
        expect(
            AICueCredentialAccessPolicy.currentBuild.permitsDataProtectionKeychain,
            "普通构建保留原能力")
        #endif
    }
    await suite("公开预览：Keychain Provider 全操作关闭、旧槽保留、本地存储隔离") {
        let vault = PreviewCredentialVault()
        let policy = AICueCredentialAccessPolicy(permitsDataProtectionKeychain: false)
        let manager = AICueCredentialManager(
            vault: vault, validators: [:],
            metadata: AICueUserDefaultsCredentialMetadataStore(), accessPolicy: policy)
        for profile in [
            AICueProviderProfileID.elevenLabsGlobal, .miniMaxGlobal, .qwenBeijing, .qwenSingapore,
        ] {
            let status = await manager.status(for: profile)
            expect(status == .unavailable, "预览状态查询不触达 Keychain")
            do {
                _ = try await manager.save(
                    SensitiveCredentialInput("preview-fixture"), for: profile);
                expect(false, "应拒绝保存")
            } catch {}
            do { try await manager.delete(for: profile); expect(false, "应拒绝删除") } catch {}
            do {
                try await manager.cancelPendingReplacement(for: profile); expect(false, "应拒绝清理")
            } catch {}
            do {
                _ = try await manager.credentialForGeneration(for: profile);
                expect(false, "应拒绝生成凭据")
            } catch {}
        }
        try? await manager.migrateLegacyQwenCredentials()
        let beforeLocal = await vault.snapshot()
        expect(beforeLocal.isEmpty, "所有受限操作及显式旧槽迁移都不得触达 vault")
        let localStatus = await manager.status(for: .senseAudioChina)
        expect(localStatus == .missing, "已获准本地存储服务保持原合同")
        let touched = await vault.snapshot()
        expect(touched.allSatisfy { $0 == .senseAudioChina }, "本地服务查询不清理旧 Keychain")
        let keychain = PreviewCredentialVault()
        let local = PreviewCredentialVault()
        let appVault = AICueAppCredentialVault(
            keychain: keychain, senseAudio: local,
            bailian: local, accessPolicy: policy)
        do {
            _ = try await appVault.containsCredential(in: .legacyElevenLabs);
            expect(false, "vault 防线应关闭")
        } catch {}
        let keychainTouches = await keychain.snapshot()
        expect(keychainTouches.isEmpty, "绕过 manager 仍不能触达 Keychain")
    }
}
