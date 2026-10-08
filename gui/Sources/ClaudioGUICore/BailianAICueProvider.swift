import CoreFoundation
import Dispatch
import Foundation

/// Beijing-only Audio 3.1 adapter. The credential snapshot supplies a typed workspace, never a URL.
public struct BailianAICueProvider: AICueProvider, Sendable {
    public let profile = AICueProviderRegistry.bailianBeijing
    private let unaryTransport: any AICueUnaryTransport
    private let sseTransport: any AICueSSETransport
    private let assetFetcher: any AICueAssetFetching
    private let assetPolicy: AICueAssetPolicy?

    public init() {
        self.init(
            unaryTransport: AICueURLSessionUnaryTransport(),
            sseTransport: AICueURLSessionSSETransport(),
            assetFetcher: AICueURLSessionAssetFetcher(),
            assetPolicy: BailianAssetContract.downloadPolicy)
    }

    package init(
        unaryTransport: any AICueUnaryTransport,
        sseTransport: any AICueSSETransport,
        assetFetcher: any AICueAssetFetching,
        assetPolicy: AICueAssetPolicy?
    ) {
        self.unaryTransport = unaryTransport
        self.sseTransport = sseTransport
        self.assetFetcher = assetFetcher
        self.assetPolicy = assetPolicy
    }

    public func validateCredential(_ credential: SensitiveCredentialInput) async throws {
        guard let workspace = credential.bailianWorkspaceID else {
            throw AICueProviderError.invalidRequest
        }
        let deadline = AICueGenerationDeadline.startingNow()
        for model in ["qwen-audio-3.1-tts-flash", "qwen-audio-3.1-tts-next"] {
            var components = URLComponents(
                url: workspace.endpoint(path: "/api/v1/models/permissions"),
                resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "model", value: model),
                URLQueryItem(name: "authorization_scope", value: "AUTHORIZED"),
                URLQueryItem(name: "action", value: "INFERENCE"),
                URLQueryItem(name: "page_no", value: "1"),
                URLQueryItem(name: "page_size", value: "200"),
            ]
            let request = try transportRequest(
                url: components.url!, method: .get, body: nil,
                sse: false, deadline: deadline)
            let root = try await jsonResponse(request, credential: credential)
            guard Self.isTrueBoolean(root["success"]),
                root["code"] == nil || root["code"] is NSNull,
                let output = root["output"] as? [String: Any],
                let entries = output["permissions"] as? [[String: Any]],
                entries.contains(where: {
                    $0["model"] as? String == model
                        && Self.isTrueBoolean(($0["permissions"] as? [String: Any])?["inference"])
                })
            else { throw AICueProviderError.requiredModelsUnavailable }
        }
    }

    public func generateCandidate(
        request: AICueProviderRequest,
        credential: SensitiveCredentialInput,
        deadline: AICueGenerationDeadline
    ) async throws -> AICueProviderAudioResponse {
        guard request.profileID == profile.id,
            let route = profile.routes[request.modality],
            route.endpointScope == .bailianWorkspace,
            let workspace = credential.bailianWorkspaceID,
            !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (1...3_000).contains(request.targetDurationMilliseconds)
        else { throw AICueProviderError.invalidRequest }
        try Task.checkCancellation()
        let speech = request.modality == .speech
        var input: [String: Any] = [
            "format": speech ? "pcm" : "wav",
            "sample_rate": 24_000,
        ]
        if speech {
            guard let text = request.spokenContent, !text.isEmpty,
                let tag = request.languageTag,
                let family = AICueLanguageTagMatcher.family(for: tag),
                AICueLanguageTagMatcher.matches(tag, allowlist: route.supportedLanguageTags)
            else { throw AICueProviderError.invalidRequest }
            input["text"] = text
            input["voice"] = family == .chinese ? "yuxiaoyun_v3.1" : "Emily_v3.1"
            input["instruction"] = request.prompt + " Total duration at most 3 seconds."
        } else {
            // No generation is sent until an observed, code-owned asset contract exists.
            guard assetPolicy != nil else { throw AICueProviderError.assetContractUnavailable }
            input["text_prompt"] = request.prompt
            input["channels"] = 1
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "model": route.modelID, "input": input,
        ])
        let transport = try transportRequest(
            url: workspace.endpoint(path: route.endpoint.path),
            method: .post, body: body, sse: speech, deadline: deadline,
            responseStartPolicy: speech ? .connectionBudget : .generationDeadline)
        if speech {
            return try await stream(transport, credential: credential, modelID: route.modelID)
        }
        let root = try await jsonResponse(transport, credential: credential)
        guard let output = root["output"] as? [String: Any],
            output["finish_reason"] as? String == "stop",
            let audio = output["audio"] as? [String: Any],
            (audio["data"] == nil || audio["data"] as? String == ""),
            let literal = audio["url"] as? String,
            let assetPolicy
        else { throw AICueProviderError.invalidAudioResponse }
        do {
            let url = try BailianAssetContract.downloadURL(from: literal)
            let asset = try await assetFetcher.fetch(url, policy: assetPolicy, deadline: deadline)
            guard asset.data.count <= 5 * 1_024 * 1_024,
                assetPolicy.acceptedMediaTypes.contains(asset.mediaType),
                sniffAudioFormat(asset.data) == .wav
            else { throw AICueProviderError.invalidAudioResponse }
            return AICueProviderAudioResponse(
                data: asset.data, mediaType: asset.mediaType,
                modelID: route.modelID,
                requestID: sanitizedAICueProviderRequestID(root["request_id"] as? String))
        } catch let error as AICueProviderError { throw error } catch let error
            as AICueAssetFetchError
        {
            switch error {
            case .deadlineExceeded: throw AICueProviderError.deadlineExceeded
            case .cancelled: throw AICueProviderError.cancelled
            case .responseTooLarge: throw AICueProviderError.responseTooLarge
            default: throw AICueProviderError.invalidAudioResponse
            }
        }
    }

    private static func isTrueBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return false
        }
        return number.boolValue
    }

    private func transportRequest(
        url: URL, method: AICueHTTPMethod, body: Data?, sse: Bool,
        deadline: AICueGenerationDeadline,
        responseStartPolicy: AICueResponseStartPolicy = .connectionBudget
    ) throws -> AICueTransportRequest {
        var headers = [
            "accept": sse ? "text/event-stream" : "application/json",
            "content-type": "application/json",
        ]
        if sse { headers["X-DashScope-SSE"] = "enable" }
        return AICueTransportRequest(
            method: method, url: url, expectedOrigin: try AICueOrigin(url: url),
            expectedPath: url.path, headers: headers, body: body,
            acceptedMediaTypes: [sse ? "text/event-stream" : "application/json"],
            maximumWireBytes: sse ? AICueTransportCeilings.qwenSSEWireBytes : 512 * 1_024,
            deadline: deadline, responseStartPolicy: responseStartPolicy)
    }

    private func jsonResponse(
        _ request: AICueTransportRequest,
        credential: SensitiveCredentialInput
    ) async throws -> [String: Any] {
        do {
            let response = try await unaryTransport.send(
                request, authentication: .bearerAPIKey, credential: credential)
            guard (200..<300).contains(response.statusCode) else {
                throw AICueTransportError.httpStatus(
                    code: response.statusCode, retryAfterSeconds: nil)
            }
            guard response.finalURL == request.url, response.body.count <= request.maximumWireBytes,
                AICueTransportRequestBuilder.normalizedMediaType(response.headers["content-type"])
                    == "application/json",
                let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            else { throw AICueProviderError.invalidAudioResponse }
            if let code = root["code"], !(code is NSNull) {
                throw AICueProviderError.invalidAudioResponse
            }
            return root
        } catch {
            throw AICueProviderTransportErrorMapper.map(
                error, unexpectedMediaType: .invalidAudioResponse)
        }
    }

    private func stream(
        _ request: AICueTransportRequest, credential: SensitiveCredentialInput,
        modelID: String
    ) async throws -> AICueProviderAudioResponse {
        var sequence = AICueSSETerminalValidator()
        var pcm = Data()
        var requestID: String?
        do {
            for try await event in sseTransport.events(
                for: request, authentication: .bearerAPIKey, credential: credential)
            {
                try Task.checkCancellation()
                guard let data = event.data.data(using: .utf8),
                    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    root["code"] == nil || root["code"] is NSNull,
                    let output = root["output"] as? [String: Any],
                    let audio = output["audio"] as? [String: Any],
                    let encoded = audio["data"] as? String
                else { throw AICueProviderError.invalidAudioResponse }
                for (field, expected) in [
                    ("sample_rate", 24_000), ("channels", 1), ("bits_per_sample", 16),
                ] {
                    if let declaration = audio[field] {
                        guard let number = declaration as? NSNumber,
                            CFGetTypeID(number) != CFBooleanGetTypeID(),
                            number.doubleValue == Double(expected)
                        else { throw AICueProviderError.invalidAudioResponse }
                    }
                }
                if let format = audio["format"], format as? String != "pcm" {
                    throw AICueProviderError.invalidAudioResponse
                }
                let terminal = output["finish_reason"] as? String == "stop"
                try sequence.accept(isTerminal: terminal)
                if let id = sanitizedAICueProviderRequestID(root["request_id"] as? String) {
                    guard requestID == nil || requestID == id else {
                        throw AICueProviderError.invalidAudioResponse
                    }
                    requestID = id
                }
                if terminal {
                    guard encoded.isEmpty else { throw AICueProviderError.invalidAudioResponse }
                    // The final download URL is deliberately ignored.
                    continue
                }
                guard
                    output["finish_reason"] == nil || output["finish_reason"] is NSNull
                        || output["finish_reason"] as? String == "null",
                    let type = output["type"] as? String,
                    ["sentence-begin", "sentence-synthesis", "sentence-end"].contains(type)
                else { throw AICueProviderError.invalidAudioResponse }
                if type == "sentence-synthesis" {
                    guard !encoded.isEmpty else { throw AICueProviderError.invalidAudioResponse }
                    var decoder = AICueBoundedBase64Decoder(
                        maximumDecodedBytes: AICueTransportCeilings.qwenDecodedPCMBytes - pcm.count)
                    try decoder.append(encoded)
                    pcm.append(try decoder.finish())
                } else if !encoded.isEmpty {
                    throw AICueProviderError.invalidAudioResponse
                }
            }
            try sequence.finish()
            guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else {
                throw AICueProviderError.invalidAudioResponse
            }
        } catch AICueDecodedPayloadError.decodedPayloadTooLarge {
            throw AICueProviderError.responseTooLarge
        } catch is AICueDecodedPayloadError, is AICueSSESequenceError {
            throw AICueProviderError.invalidAudioResponse
        } catch {
            throw AICueProviderTransportErrorMapper.map(
                error, unexpectedMediaType: .invalidAudioResponse)
        }
        var wav = Data("RIFF".utf8)
        wav.bailianAppend(UInt32(36 + pcm.count))
        wav.append(Data("WAVEfmt ".utf8))
        wav.bailianAppend(UInt32(16)); wav.bailianAppend(UInt16(1)); wav.bailianAppend(UInt16(1))
        wav.bailianAppend(UInt32(24_000)); wav.bailianAppend(UInt32(48_000))
        wav.bailianAppend(UInt16(2)); wav.bailianAppend(UInt16(16))
        wav.append(Data("data".utf8)); wav.bailianAppend(UInt32(pcm.count)); wav.append(pcm)
        return AICueProviderAudioResponse(
            data: wav, mediaType: "audio/wav", modelID: modelID, requestID: requestID)
    }
}

extension Data {
    fileprivate mutating func bailianAppend<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
