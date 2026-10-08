import ClaudioGUICore
import Dispatch
import Foundation

private func bailianKey(_ workspace: String = "fixture-space") -> SensitiveCredentialInput {
    try! SensitiveCredentialInput(
        apiKey: "fixture-only-key", bailianWorkspaceID: BailianWorkspaceID(workspace))
}

private func bailianEvent(_ type: String? = nil, pcm: Data = Data(), stop: Bool = false)
    -> AICueSSEEvent
{
    var output: [String: Any] = [
        "audio": ["data": pcm.base64EncodedString()],
        "finish_reason": stop ? "stop" : "null",
    ]
    if let type { output["type"] = type }
    if stop { output["audio"] = ["data": "", "url": "https://untrusted.invalid/ignored.wav"] }
    let data = try! JSONSerialization.data(withJSONObject: [
        "output": output, "request_id": "fixture-request",
    ])
    return AICueSSEEvent(dataLines: [String(decoding: data, as: UTF8.self)])
}

private final class BailianSSEFixture: AICueSSETransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AICueTransportRequest] = []
    let events: [AICueSSEEvent]
    let error: AICueTransportError?
    init(
        events: [AICueSSEEvent] = [
            bailianEvent("sentence-begin"),
            bailianEvent("sentence-synthesis", pcm: Data(repeating: 0, count: 48_000)),
            bailianEvent("sentence-end"), bailianEvent(stop: true),
        ],
        error: AICueTransportError? = nil
    ) {
        self.events = events; self.error = error
    }
    func events(
        for request: AICueTransportRequest, authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) -> AsyncThrowingStream<AICueSSEEvent, Error> {
        lock.lock(); requests.append(request); lock.unlock()
        return AsyncThrowingStream { continuation in
            if let error { continuation.finish(throwing: error); return }
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
    func captured() -> [AICueTransportRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
}

private actor BailianUnaryFixture: AICueUnaryTransport {
    var requests: [AICueTransportRequest] = []
    let allowed: Bool
    let nextURL: String
    init(
        allowed: Bool = true,
        nextURL: String = "https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/result.wav"
    ) {
        self.allowed = allowed; self.nextURL = nextURL
    }
    func send(
        _ request: AICueTransportRequest, authentication: AICueProviderAuthentication,
        credential: SensitiveCredentialInput
    ) async throws -> AICueHTTPResponse {
        requests.append(request)
        let model =
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "model" })?.value ?? ""
        let root: [String: Any] =
            request.method == .get
            ? [
                "success": true,
                "output": [
                    "permissions": [
                        ["model": model, "permissions": ["inference": allowed]]
                    ]
                ],
            ]
            : ["output": ["finish_reason": "stop", "audio": ["data": "", "url": nextURL]]]
        return AICueHTTPResponse(
            statusCode: 200, headers: ["content-type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: root), finalURL: request.url)
    }
    func captured() -> [AICueTransportRequest] { requests }
}

private final class BailianDelayedNextURLProtocol: URLProtocol, @unchecked Sendable {
    private var delivery: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let delivery = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(
                url: self.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/json"])!
            let body = Data(
                #"{"output":{"finish_reason":"stop","audio":{"data":"","url":"https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/result.wav"}}}"#
                    .utf8)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.delivery = delivery
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.08, execute: delivery)
    }
    override func stopLoading() { delivery?.cancel(); delivery = nil }
}

private actor BailianAssetFixture: AICueAssetFetching {
    var calls = 0
    var urls: [URL] = []
    let wav: Data
    let mediaType: String
    init(wav: Data, mediaType: String = "audio/wav") { self.wav = wav; self.mediaType = mediaType }
    func fetch(_ url: URL, policy: AICueAssetPolicy, deadline: AICueGenerationDeadline) async throws
        -> AICueFetchedAsset
    {
        calls += 1
        urls.append(url)
        _ = try AICueURLSessionAssetFetcher.request(url: url, policy: policy, deadline: deadline)
        return AICueFetchedAsset(data: wav, mediaType: mediaType)
    }
    func count() -> Int { calls }
    func capturedURLs() -> [URL] { urls }
}

private actor BailianVaultFixture: AICueCredentialVault {
    var items: [AICueCredentialSlotID: SensitiveCredentialInput] = [:]
    var deletes: [AICueCredentialSlotID] = []
    var failDelete: AICueCredentialSlotID?
    var failWrite = false
    func containsCredential(in slotID: AICueCredentialSlotID) -> Bool { items[slotID] != nil }
    func credential(in slotID: AICueCredentialSlotID) -> SensitiveCredentialInput? { items[slotID] }
    func replaceCredential(_ credential: SensitiveCredentialInput, in slotID: AICueCredentialSlotID)
        throws
    {
        if failWrite { throw AICueProviderError.transportFailure }
        items[slotID] = credential
    }
    func deleteCredential(in slotID: AICueCredentialSlotID) throws {
        deletes.append(slotID)
        if failDelete == slotID { throw AICueProviderError.transportFailure }
        items.removeValue(forKey: slotID)
    }
    func setFailure(delete: AICueCredentialSlotID? = nil, write: Bool = false) {
        failDelete = delete; failWrite = write
    }
    func facts() -> ([AICueCredentialSlotID: SensitiveCredentialInput], [AICueCredentialSlotID]) {
        (items, deletes)
    }
}

private actor BailianMetadataFixture: AICueCredentialMetadataStoring {
    var values: [AICueProviderProfileID: AICueCredentialVerification] = [:]
    func verification(for profileID: AICueProviderProfileID) -> AICueCredentialVerification? {
        values[profileID]
    }
    func setVerification(
        _ verification: AICueCredentialVerification?, for profileID: AICueProviderProfileID
    ) { values[profileID] = verification }
}

private func bailianRequest(
    _ description: String = "清晰地说“完成”", locale: String = "zh-Hans",
    variant: AICueVariant = .clear
) -> AICueProviderRequest {
    let request = try! AICueGenerationRequest(
        description: description, locale: locale, providerProfileID: .bailianBeijing)
    return try! AICueProviderRequestCompiler().compile(
        plan: AICueSoundPlanner().makePlan(for: request),
        profileID: .bailianBeijing, variant: variant)
}

@MainActor
func runBailianAICueProviderSuites() async {
    suite("百炼：WorkspaceId 边界、声音类型与预算、旧选择迁移") {
        for invalid in [
            "", "https://bad", "a.b", "a/b", "a@b", "-a", "a-", "A", "中文", " a",
            String(repeating: "a", count: 64),
        ] {
            expect((try? BailianWorkspaceID(invalid)) == nil, "业务空间拒绝 URL 注入和非 DNS 标签")
        }
        let workspace = try! BailianWorkspaceID("space-123")
        expect(
            workspace.endpoint(path: "/api/v1/models/permissions").host
                == "space-123.cn-beijing.maas.aliyuncs.com", "固定北京域名")
        let profile = try! AICueProviderRegistry().profile(for: .bailianBeijing)
        for (description, locale, speech) in [
            ("说“完成”", "zh-Hans", true), ("Say \"done\"", "en", true),
            ("自然猫叫", "zh-Hans", false), ("车站短旋律", "zh-Hans", false),
            ("雨声环境音", "zh-Hans", false), ("激光音效", "zh-Hans", false),
            ("先响铃，再说“完成”", "zh-Hans", false),
            ("雨声里说“完成”", "zh-Hans", false),
            ("短旋律后说“完成”", "zh-Hans", false),
        ] {
            let request = bailianRequest(description, locale: locale)
            let route = profile.routes[request.modality]!
            expect(
                route.modelID == (speech ? "qwen-audio-3.1-tts-flash" : "qwen-audio-3.1-tts-next"),
                "类型固定路由")
            expect(
                route.generationBudget == (speech ? .standard : .longRunningSFX), "共享 60/180 秒预算")
            expect(
                !route.allowsGenerationRetry && route.candidateSetPolicy.minimumAcceptedCount == 3,
                "零生成重试、必须三项")
        }
        let name = "BailianPreferences-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for old in ["qwen-singapore", "qwen-beijing"] {
            defaults.set(old, forKey: AICueProviderPreferences.defaultsKey)
            expect(
                AICueProviderPreferences(defaults: defaults).selectedProfileID() == .bailianBeijing,
                "旧选择不切换其他服务")
        }
        expect((try? AICueProviderRegistry().profile(for: .qwenBeijing)) == nil, "旧生成路径关闭")
        #if !CLAUDIO_BAILIAN_ACCEPTANCE
        expect(
            !AICueProviderRegistry().profiles().contains(where: { $0.id == .bailianBeijing }),
            "普通构建不开放验收入口")
        #endif
    }
    suite("百炼：限定 OSS 的 HTTPS 转换保留签名且拒绝边界绕过") {
        let host = BailianAssetContract.hostname
        let suffix = "/pre/audio%2Fname.wav?Signature=a%2Fb%2B%3D&Expires=123&empty="
        expect(
            BailianAssetContract.downloadPolicy.allowedOrigins == [
                try! AICueAssetOrigin("https://" + host + ":443")
            ]
                && BailianAssetContract.downloadPolicy.acceptedMediaTypes == ["audio/x-wav"],
            "实测 origin 和 MIME 固定在代码中")
        #if CLAUDIO_BAILIAN_ACCEPTANCE
        expect(
            AICueProviderRegistry().assetPolicy(for: .bailianBeijing)
                == BailianAssetContract.downloadPolicy, "验收 runtime 使用 registry 同一下载政策")
        #else
        expect(AICueProviderRegistry().assetPolicy(for: .bailianBeijing) == nil, "资源发现通过仍未取得普通构建资格")
        #endif
        for authority in [host, host + ":80"] {
            let url = try? BailianAssetContract.downloadURL(from: "http://" + authority + suffix)
            expect(url?.absoluteString == "https://" + host + suffix, "只改变协议和默认端口；签名字节原样保留")
            let request = try? AICueURLSessionAssetFetcher.request(
                url: url!,
                policy: try! AICueAssetPolicy(
                    allowedOrigins: [AICueAssetOrigin("https://" + host)],
                    acceptedMediaTypes: ["audio/wav"]),
                deadline: .startingNow())
            expect(
                request?.httpMethod == "GET" && request?.url?.scheme == "https", "实际只构造 HTTPS GET")
            expect(request?.value(forHTTPHeaderField: "Authorization") == nil, "下载不发送 API Key")
        }
        let secure = "https://" + host + ":443" + suffix
        expect(
            (try? BailianAssetContract.downloadURL(from: secure))?.absoluteString == secure,
            "已是 HTTPS 的签名地址不重写")
        for invalid in [
            "http://other.invalid/a.wav", "http://" + host + ".other.invalid/a.wav",
            "http://" + host + ":81/a.wav", "https://" + host + ":80/a.wav",
            "https://" + host + ":444/a.wav", "ftp://" + host + "/a.wav",
            "http://user@" + host + "/a.wav", "http://user:secret@" + host + "/a.wav",
            "http://" + host + "/a.wav#", "http://" + host + "/a.wav#fragment",
            "http://127.0.0.1/a.wav", "http://[::1]/a.wav", "http://" + host + "/",
            "http://" + host + "/%2e%2e/a.wav", "http://" + host + "/a//b.wav",
            "http://" + host + "/bad path.wav", "http://" + host + "/a\\b.wav",
            "http://" + host + "/" + String(repeating: "a", count: 4_096),
        ] {
            expect((try? BailianAssetContract.downloadURL(from: invalid)) == nil, "转换不能扩大下载边界")
        }
    }
    suite("百炼：同一 Keychain 记录编码与安全解码") {
        let key = bailianKey("codec-space")
        let data = try! key.keychainData(in: .bailianBeijing)
        let restored = try! SensitiveCredentialInput.stored(data, slotID: .bailianBeijing)
        expect(restored.bailianWorkspaceID?.rawValue == "codec-space", "配置原子记录保留 WorkspaceId")
        let url = URL(
            string: "https://codec-space.cn-beijing.maas.aliyuncs.com/api/v1/models/permissions")!
        let request = AICueTransportRequest(
            method: .get, url: url,
            expectedOrigin: try! AICueOrigin(url: url), expectedPath: url.path,
            headers: [:], body: nil, acceptedMediaTypes: ["application/json"],
            maximumWireBytes: 512,
            deadline: .startingNow())
        let authenticated = try! AICueTransportRequestBuilder.authenticatedURLRequest(
            from: request,
            authentication: .bearerAPIKey, credential: restored)
        expect(
            authenticated.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only-key",
            "解码后认证只使用 Key，不发送 JSON 记录")
        expect(
            (try? SensitiveCredentialInput.stored(Data("not-json".utf8), slotID: .bailianBeijing))
                == nil,
            "损坏记录不能当作原始 API Key")
        expect((try? key.keychainData(in: .miniMaxGlobal)) == nil, "配置不能跨服务写入")
        expect(
            !String(reflecting: key).contains("fixture-only-key")
                && !String(reflecting: key).contains("codec-space"),
            "快照描述不泄漏 Key 或空间")
    }
    await suite("百炼：两模型推理权限只读检查") {
        let unary = BailianUnaryFixture()
        let sse = BailianSSEFixture()
        let provider = BailianAICueProvider(
            unaryTransport: unary, sseTransport: sse,
            assetFetcher: BailianAssetFixture(wav: Data()), assetPolicy: nil)
        do { try await provider.validateCredential(bailianKey()) } catch {
            expect(false, "两模型权限正控")
        }
        let requests = await unary.captured()
        expect(
            requests.count == 2
                && requests.allSatisfy {
                    $0.method == .get && $0.url.host == "fixture-space.cn-beijing.maas.aliyuncs.com"
                }, "只发两个同业务空间 GET")
        expect(sse.captured().isEmpty, "保存不生成音频")
        expect(requests.allSatisfy { $0.responseStartPolicy == .connectionBudget }, "权限 GET 保留连接预算")
        let denied = BailianAICueProvider(
            unaryTransport: BailianUnaryFixture(allowed: false), sseTransport: sse,
            assetFetcher: BailianAssetFixture(wav: Data()), assetPolicy: nil)
        do {
            try await denied.validateCredential(bailianKey()); expect(false, "拒绝无推理权限")
        } catch AICueProviderError.requiredModelsUnavailable { expect(true, "无权限关闭") } catch {
            expect(false, "错误分类")
        }
    }
    await suite("百炼：Flash 新 SSE、中文与英文音色、风格实际发送、末包 URL 不下载") {
        let unary = BailianUnaryFixture(); let sse = BailianSSEFixture();
        let assets = BailianAssetFixture(wav: Data())
        let provider = BailianAICueProvider(
            unaryTransport: unary, sseTransport: sse, assetFetcher: assets, assetPolicy: nil)
        for (description, locale, voice) in [
            ("说“完成”", "zh-Hans", "yuxiaoyun_v3.1"), ("Say \"done\"", "en-US", "Emily_v3.1"),
        ] {
            do {
                let response = try await provider.generateCandidate(
                    request: bailianRequest(description, locale: locale), credential: bailianKey(),
                    deadline: .startingNow())
                expect(
                    response.data.count == 48_044 && sniffAudioFormat(response.data) == .wav,
                    "完整 PCM 封装 WAV")
                let body =
                    try! JSONSerialization.jsonObject(with: sse.captured().last!.body!)
                    as! [String: Any]
                let input = body["input"] as! [String: Any]
                expect(
                    input["voice"] as? String == voice && input["format"] as? String == "pcm",
                    "中英固定音色")
                expect((input["instruction"] as? String)?.contains("[clear]") == true, "风格发送模型")
                expect(
                    sse.captured().last?.responseStartPolicy == .connectionBudget,
                    "Flash SSE 保留连接预算")
            } catch { expect(false, "Flash 正控") }
        }
        let unaryRequests = await unary.captured()
        expect(await assets.count() == 0 && unaryRequests.isEmpty, "末包 URL 不跟随")
    }
    await suite("百炼：Next 同步计算超过连接预算仍受原始生成 deadline 约束") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BailianDelayedNextURLProtocol.self]
        let transport = AICueURLSessionUnaryTransport(
            configuration: configuration,
            timeouts: AICueTransportTimeouts(connectionSeconds: 0.02, inactivitySeconds: 0.2))
        let flash = BailianAICueProvider(
            unaryTransport: BailianUnaryFixture(), sseTransport: BailianSSEFixture(),
            assetFetcher: BailianAssetFixture(wav: Data()), assetPolicy: nil)
        let wav = try! await flash.generateCandidate(
            request: bailianRequest(), credential: bailianKey(), deadline: .startingNow()
        ).data
        let provider = BailianAICueProvider(
            unaryTransport: transport, sseTransport: BailianSSEFixture(),
            assetFetcher: BailianAssetFixture(wav: wav, mediaType: "audio/x-wav"),
            assetPolicy: BailianAssetContract.downloadPolicy)
        do {
            let response = try await provider.generateCandidate(
                request: bailianRequest("猫叫"), credential: bailianKey(),
                deadline: AICueGenerationDeadline(
                    startedAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                    durationNanoseconds: 500_000_000))
            expect(response.data == wav, "真实 URLSession 接缝允许 Next 延迟响应头后立即下载")
        } catch { expect(false, "Next 不得把同步计算误判为连接超时：\(error)") }
    }
    await suite("百炼：坏 SSE、空 PCM、超长、超限与终包违规均失败") {
        let valid = bailianEvent("sentence-synthesis", pcm: Data(repeating: 0, count: 48_000))
        for events in [
            [valid], [bailianEvent(stop: true)],
            [bailianEvent("unknown"), bailianEvent(stop: true)],
            [valid, bailianEvent(stop: true), valid],
            [
                bailianEvent("sentence-synthesis", pcm: Data(repeating: 0, count: 144_002)),
                bailianEvent(stop: true),
            ],
        ] {
            let provider = BailianAICueProvider(
                unaryTransport: BailianUnaryFixture(),
                sseTransport: BailianSSEFixture(events: events),
                assetFetcher: BailianAssetFixture(wav: Data()), assetPolicy: nil)
            do {
                _ = try await provider.generateCandidate(
                    request: bailianRequest(), credential: bailianKey(), deadline: .startingNow());
                expect(false, "坏流不得发布")
            } catch { expect(true, "坏流关闭") }
        }
    }
    await suite("百炼：Next JSON、WAV 与下载违约；缺政策时零 POST") {
        let sse = BailianSSEFixture()
        let flash = BailianAICueProvider(
            unaryTransport: BailianUnaryFixture(), sseTransport: sse,
            assetFetcher: BailianAssetFixture(wav: Data()), assetPolicy: nil)
        let wav = try! await flash.generateCandidate(
            request: bailianRequest(), credential: bailianKey(), deadline: .startingNow()
        ).data
        let policy = try! AICueAssetPolicy(
            allowedOrigins: [
                AICueAssetOrigin("https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com")
            ],
            acceptedMediaTypes: ["audio/wav"])
        let unary = BailianUnaryFixture(); let assets = BailianAssetFixture(wav: wav)
        let provider = BailianAICueProvider(
            unaryTransport: unary, sseTransport: sse, assetFetcher: assets, assetPolicy: policy)
        let deadline = AICueGenerationDeadline.startingNow(
            description: "车站短旋律", locale: "zh-Hans", profileID: .bailianBeijing,
            registry: AICueProviderRegistry())
        do {
            let response = try await provider.generateCandidate(
                request: bailianRequest("车站短旋律"), credential: bailianKey(), deadline: deadline
            )
            expect(response.modelID == "qwen-audio-3.1-tts-next", "实际 Next 模型")
            let request = await unary.captured().last!
            expect(
                request.responseStartPolicy == .generationDeadline,
                "Next 同步生成等待响应头必须使用共享生成 deadline，不能被 10 秒连接预算截断")
            expect(request.deadline == deadline, "Next 不得重置共享绝对 deadline")
            let body = try! JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
            let input = body["input"] as! [String: Any]
            expect(
                input["channels"] as? Int == 1 && input["sample_rate"] as? Int == 24_000
                    && input["text_prompt"] != nil, "Next 输出合同")
        } catch { expect(false, "Next fixture 正控") }
        for url in [
            "http://other.invalid/a.wav", "https://127.0.0.1/a.wav",
            "https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com:444/a.wav",
            "https://user@dashscope-result-bj.oss-cn-beijing.aliyuncs.com/a.wav",
            "https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/a.wav#fragment",
            "https://other.invalid/a.wav",
        ] {
            let bad = BailianAICueProvider(
                unaryTransport: BailianUnaryFixture(nextURL: url), sseTransport: sse,
                assetFetcher: assets, assetPolicy: policy)
            do {
                _ = try await bad.generateCandidate(
                    request: bailianRequest("猫叫"), credential: bailianKey(),
                    deadline: .startingNow());
                expect(false, "下载违约拒绝")
            } catch { expect(true, "下载关闭") }
        }
        let signedPath = "/pre/result%2Fpart.wav?Signature=fixture%2Fonly%2B%3D&Expires=123"
        let upgraded = BailianAICueProvider(
            unaryTransport: BailianUnaryFixture(
                nextURL: "http://" + BailianAssetContract.hostname + signedPath),
            sseTransport: sse, assetFetcher: assets, assetPolicy: policy)
        do {
            _ = try await upgraded.generateCandidate(
                request: bailianRequest("猫叫"), credential: bailianKey(), deadline: .startingNow())
            expect(
                await assets.capturedURLs().last?.absoluteString == "https://"
                    + BailianAssetContract.hostname + signedPath,
                "Next JSON 经限定转换后立即下载，签名 query 原样保留")
        } catch { expect(false, "限定升级的 Next 正控") }
        let observedAssets = BailianAssetFixture(wav: wav, mediaType: "audio/x-wav")
        let observed = BailianAICueProvider(
            unaryTransport: BailianUnaryFixture(
                nextURL: "http://" + BailianAssetContract.hostname + signedPath),
            sseTransport: sse, assetFetcher: observedAssets,
            assetPolicy: BailianAssetContract.downloadPolicy)
        do {
            let response = try await observed.generateCandidate(
                request: bailianRequest("猫叫"), credential: bailianKey(), deadline: .startingNow())
            expect(response.mediaType == "audio/x-wav", "生产政策接受实测 MIME 的 WAV")
        } catch { expect(false, "实测 MIME 的正控") }
        for mime in ["audio/wav", "application/octet-stream", "text/html"] {
            let drift = BailianAICueProvider(
                unaryTransport: BailianUnaryFixture(), sseTransport: sse,
                assetFetcher: BailianAssetFixture(wav: wav, mediaType: mime),
                assetPolicy: BailianAssetContract.downloadPolicy)
            do {
                _ = try await drift.generateCandidate(
                    request: bailianRequest("猫叫"), credential: bailianKey(),
                    deadline: .startingNow())
                expect(false, "运行时响应不能扩展实测 MIME")
            } catch { expect(true, "MIME 漂移关闭") }
        }
        let gatedUnary = BailianUnaryFixture()
        let gated = BailianAICueProvider(
            unaryTransport: gatedUnary, sseTransport: sse, assetFetcher: assets, assetPolicy: nil)
        do {
            _ = try await gated.generateCandidate(
                request: bailianRequest("猫叫"), credential: bailianKey(), deadline: .startingNow());
            expect(false, "缺政策关闭")
        } catch { expect(true, "缺政策关闭") }
        expect(await gatedUnary.captured().isEmpty, "缺政策不消耗生成请求")
    }
    await suite("百炼：四槽迁移、缺失、删除失败重试、重复启动、其他服务隔离") {
        let vault = BailianVaultFixture(); let metadata = BailianMetadataFixture()
        let oldSlots: [AICueCredentialSlotID] = [
            .qwenBeijing, .qwenSingapore, .qwenBeijingPending, .qwenSingaporePending,
        ]
        for slot in oldSlots + [.miniMaxGlobal] {
            try! await vault.replaceCredential(SensitiveCredentialInput("fixture-old"), in: slot)
        }
        await metadata.setVerification(.verified, for: .qwenBeijing)
        let manager = AICueCredentialManager(vault: vault, validators: [:], metadata: metadata)
        await vault.setFailure(delete: .qwenSingapore)
        do { try await manager.migrateLegacyQwenCredentials(); expect(false, "删除失败不能成功") } catch {
            expect(true, "迁移失败可重试")
        }
        await vault.setFailure()
        try! await manager.migrateLegacyQwenCredentials()
        let facts = await vault.facts()
        expect(
            oldSlots.allSatisfy { facts.0[$0] == nil } && facts.0[.miniMaxGlobal] != nil, "只清除四旧槽")
        expect(await metadata.verification(for: .qwenBeijing) == nil, "清理验证元数据")
        try! await manager.migrateLegacyQwenCredentials()
        expect(await vault.facts().1 == facts.1, "同一次运行幂等")
        let restarted = AICueCredentialManager(vault: vault, validators: [:], metadata: metadata)
        try! await restarted.migrateLegacyQwenCredentials()
        expect(await restarted.status(for: .bailianBeijing) == .missing, "重复启动、缺失槽正常")
    }
    await suite("百炼：配置原子替换、权限/写入失败保留旧配置、版本竞争拒绝迟到发布") {
        let vault = BailianVaultFixture(); let metadata = BailianMetadataFixture()
        let validator = BailianAICueProvider(
            unaryTransport: BailianUnaryFixture(), sseTransport: BailianSSEFixture(),
            assetFetcher: BailianAssetFixture(wav: Data()), assetPolicy: nil)
        let manager = AICueCredentialManager(
            vault: vault, validators: [.bailianBeijing: validator], metadata: metadata)
        let old = bailianKey("old-space"); let new = bailianKey("new-space")
        let status = try! await manager.save(old, for: .bailianBeijing)
        expect(
            status == .stored(verification: .deferred, hasPendingReplacement: false), "权限与真实生成验证区分")
        let lease = try! await manager.credentialForGeneration(for: .bailianBeijing)
        await vault.setFailure(write: true)
        do { _ = try await manager.save(new, for: .bailianBeijing); expect(false, "写失败") } catch {
            expect(true, "写失败")
        }
        expect(await vault.credential(in: .bailianBeijing) === old, "写失败保留同一配置")
        await vault.setFailure()
        _ = try! await manager.save(new, for: .bailianBeijing)
        expect(
            await vault.credential(in: .bailianBeijing)?.bailianWorkspaceID?.rawValue
                == "new-space", "Key 和业务空间原子更新")
        expect(lease.credential.bailianWorkspaceID?.rawValue == "old-space", "生成捕获原配置")
        do {
            try await manager.generationDidValidate(lease); expect(false, "迟到结果不得发布")
        } catch AICueCredentialManagerError.stateChanged { expect(true, "版本竞争关闭") } catch {
            expect(false, "竞争错误分类")
        }
        await metadata.setVerification(.verified, for: .bailianBeijing)
        expect(
            await manager.status(for: .bailianBeijing)
                == .stored(verification: .deferred, hasPendingReplacement: false),
            "旧 metadata verified 不得跨配置验证新的 Keychain 快照")
        let currentLease = try! await manager.credentialForGeneration(for: .bailianBeijing)
        try! await manager.generationDidValidate(currentLease)
        expect(
            await manager.status(for: .bailianBeijing)
                == .stored(verification: .verified, hasPendingReplacement: false), "真实生成验证原子绑定配置")
        _ = try! await manager.save(new, for: .bailianBeijing)
        let denied = BailianAICueProvider(
            unaryTransport: BailianUnaryFixture(allowed: false), sseTransport: BailianSSEFixture(),
            assetFetcher: BailianAssetFixture(wav: Data()), assetPolicy: nil)
        let failing = AICueCredentialManager(
            vault: vault, validators: [.bailianBeijing: denied], metadata: metadata)
        do {
            _ = try await failing.save(old, for: .bailianBeijing); expect(false, "权限失败不得保存")
        } catch { expect(true, "权限失败关闭") }
        expect(await vault.credential(in: .bailianBeijing) === new, "权限失败保留原配置")
    }
    await suite("百炼：三候选完整成功、共享预算、零 429 重试与失败清理") {
        await withTempDirectory { root in
            let vault = BailianVaultFixture();
            try! await vault.replaceCredential(bailianKey(), in: .bailianBeijing)
            let sse = BailianSSEFixture()
            let provider = BailianAICueProvider(
                unaryTransport: BailianUnaryFixture(), sseTransport: sse,
                assetFetcher: BailianAssetFixture(wav: Data()), assetPolicy: nil)
            let manager = AICueCredentialManager(
                vault: vault, validators: [:], metadata: BailianMetadataFixture())
            let engine = AICueGenerationEngine(
                credentialManager: manager, provider: provider,
                temporaryRoot: root, durationProbe: StubDurationProbe(fixedDuration: 1))
            let deadline = AICueGenerationDeadline.startingNow()
            let generation = try! await engine.generate(
                description: "说“完成”", locale: "zh-Hans", providerProfileID: .bailianBeijing,
                deadline: deadline)
            expect(
                generation.candidates.count == 3
                    && generation.candidates.allSatisfy {
                        $0.provenance.modelID == "qwen-audio-3.1-tts-flash"
                    }, "完整三项")
            expect(
                sse.captured().allSatisfy {
                    $0.deadline.expiresAtUptimeNanoseconds == deadline.expiresAtUptimeNanoseconds
                }, "三请求同一截止时间")
            let instructions = sse.captured().map { String(decoding: $0.body!, as: UTF8.self) }
            expect(
                instructions[0].contains("[clear]") && instructions[1].contains("[cheerful]")
                    && instructions[2].contains("[calm]"), "风格实际发送")
            await engine.discard(generationID: generation.id)
            let rate = BailianSSEFixture(error: .httpStatus(code: 429, retryAfterSeconds: 1))
            let failed = AICueGenerationEngine(
                credentialManager: manager,
                provider: BailianAICueProvider(
                    unaryTransport: BailianUnaryFixture(), sseTransport: rate,
                    assetFetcher: BailianAssetFixture(wav: Data()), assetPolicy: nil),
                temporaryRoot: root, durationProbe: StubDurationProbe(fixedDuration: 1))
            do {
                _ = try await failed.generate(
                    description: "说“完成”", locale: "zh-Hans", providerProfileID: .bailianBeijing,
                    deadline: .startingNow());
                expect(false, "429 失败")
            } catch { expect(true, "429 失败") }
            expect(rate.captured().count == 1, "生成 POST 零重试")
            expect(
                (try! FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil)).isEmpty, "失败和显式丢弃均清理整批")
        }
    }
}
