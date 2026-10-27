// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

private final class NoModelRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class ChatCompletionClient {
    private let credentials: CredentialStore
    private let session: URLSession

    init(credentials: CredentialStore = CredentialStore(), configuration: URLSessionConfiguration = .ephemeral) {
        self.credentials = credentials
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: NoModelRedirects(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func validate(_ connection: ConnectionProfile) throws {
        try DataSharingConsent.require(connection)
        _ = try ModelRequestCodec.resolvedEndpoint(connection: connection)
        try ModelRequestCodec.validateParameters(connection)
        _ = try apiKey(connection, override: nil)
    }

    private func apiKey(_ connection: ConnectionProfile, override: String?) throws -> String {
        guard let key = try override ?? credentials.read(connectionID: connection.id), !key.isEmpty,
              !key.contains("\n"), !key.contains("\r"), !key.contains("•"), !key.contains("*"), key != "已配置" else {
            throw TincallError(message: String(localized: "此模型连接缺少有效 API Key，请在配置中保存"))
        }
        return key
    }

    private func request(connection: ConnectionProfile, url: URL, apiKey: String?, body: Data? = nil, stream: Bool = false) throws -> URLRequest {
        try DataSharingConsent.require(connection)
        let key = try self.apiKey(connection, override: apiKey)
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        switch connection.provider {
        case .openAICompatible: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default: throw TincallError(message: String(localized: "请选择模型协议"))
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    func stream(connection: ConnectionProfile, messages: [ModelMessage], maxOutputTokens: Int? = nil, logContext: RequestLogContext? = nil,
                omittedTurnCount: Int = 0,
                onDelta: (String) -> Void) async throws -> String {
        let messages = try await Self.compressInputAudio(messages, provider: connection.provider)
        try Task.checkCancellation()
        let request = try request(connection: connection, url: ModelRequestCodec.resolvedEndpoint(connection: connection), apiKey: nil,
            body: ModelRequestCodec.requestBody(connection: connection, messages: messages, maxOutputTokens: maxOutputTokens), stream: true)
        let log = RequestLogStore.shared.begin(service: .model(connection.provider), step: .model, context: logContext,
                                              connectionName: connection.name, modelName: connection.model)
        log.protect(request)
        log.requestBody(request.httpBody)
        log.request(messages, omittedTurnCount: omittedTurnCount)
        let hasAudioInput = messages.contains { $0.audio != nil }
        defer { log.finish() }
        var decoder = ChatCompletionStreamDecoder(provider: connection.provider)
        defer { log.reasoning(decoder.reasoning) }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            log.response(response)
            // Audio services may echo rejected payloads. Keep HTTP status without archiving a recording.
            if !hasAudioInput, let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try await log.errorBody(bytes)
            }
            try Self.validateResponse(response, streaming: true)
            var line = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                if byte == 10 {
                    if line.last == 13 { line.removeLast() }
                    guard let value = String(data: line, encoding: .utf8) else { throw TincallError(message: String(localized: "模型流式事件不是有效 UTF-8")) }
                    if let delta = try decoder.consume(line: value) { onDelta(delta) }
                    line.removeAll(keepingCapacity: true)
                    if decoder.isDone { break }
                } else {
                    line.append(byte)
                    guard line.count <= 1_048_576 else { throw TincallError(message: String(localized: "模型流式事件过大")) }
                }
            }
            if !line.isEmpty {
                if line.last == 13 { line.removeLast() }
                guard let value = String(data: line, encoding: .utf8) else { throw TincallError(message: String(localized: "模型流式事件不是有效 UTF-8")) }
                if let delta = try decoder.consume(line: value) { onDelta(delta) }
            }
            // Flush a final event before validating completion so a truncated final delta is retained.
            if let delta = try decoder.consume(line: "") { onDelta(delta) }
            try Task.checkCancellation()
            _ = try decoder.finish()
            log.succeed(decoder.text)
            return decoder.text
        } catch {
            if !hasAudioInput, let body = decoder.errorResponseText { log.serverError(body) }
            if !decoder.text.isEmpty { log.text(decoder.text) }
            log.fail(error)
            throw Self.safeError(error)
        }
    }

    func complete(connection: ConnectionProfile, messages: [ModelMessage], maxOutputTokens: Int? = nil, logContext: RequestLogContext? = nil) async throws -> String {
        try await complete(connection: connection, messages: messages, maxOutputTokens: maxOutputTokens, apiKey: nil, logContext: logContext, step: .summary)
    }

    private func complete(connection: ConnectionProfile, messages: [ModelMessage], maxOutputTokens: Int?, apiKey: String?, logContext: RequestLogContext? = nil, step: RequestLogStep = .connectionTest) async throws -> String {
        let messages = try await Self.compressInputAudio(messages, provider: connection.provider)
        try Task.checkCancellation()
        let request = try request(connection: connection, url: ModelRequestCodec.resolvedEndpoint(connection: connection, stream: false), apiKey: apiKey,
            body: ModelRequestCodec.requestBody(connection: connection, messages: messages, maxOutputTokens: maxOutputTokens, stream: false))
        return try await responseData(request, service: .model(connection.provider), step: step, context: logContext,
                                      connectionName: connection.name, modelName: connection.model,
                                      requestText: ModelMessage.logText(messages),
                                      reasoning: { try ModelResponseCodec.responseReasoning($0, provider: connection.provider) }) {
            try ModelResponseCodec.responseText($0, provider: connection.provider)
        }
    }

    private nonisolated static func compressInputAudio(_ messages: [ModelMessage], provider: ConnectionProvider) async throws -> [ModelMessage] {
        var result = messages
        for index in result.indices {
            guard let wave = result[index].audio else { continue }
            guard provider == .gemini || provider == .openAICompatible else {
                throw TincallError(message: String(localized: "此模型协议尚不支持原声输入"))
            }
            guard result[index].audioFormat != .mp3 else { continue }
            let worker = Task.detached(priority: .userInitiated) { try OriginalAudioEncoder.mp3(wave: wave) }
            result[index].audio = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            result[index].audioFormat = .mp3
        }
        return result
    }

    /// Explicit UI action only. Uses the draft key when provided, without saving it.
    func testConnection(connection: ConnectionProfile, apiKey: String? = nil) async throws -> String {
        try await complete(connection: connection, messages: [ModelMessage(role: "user", content: "Reply with OK only.")],
            maxOutputTokens: ModelRequestCodec.connectionTestOutputLimit(connection), apiKey: apiKey)
    }

    /// Fetch every page, returning native model IDs suitable for the same protocol's generation requests.
    func fetchModels(connection: ConnectionProfile, apiKey: String? = nil) async throws -> [String] {
        let endpoint = try ModelRequestCodec.modelsEndpoint(connection: connection)
        var cursor: String?
        var seen: Set<String> = []
        var models: Set<String> = []
        while true {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            if connection.provider == .anthropic { components.queryItems = [URLQueryItem(name: "limit", value: "1000")] }
            if connection.provider == .gemini { components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")] }
            if let cursor {
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: connection.provider == .gemini ? "pageToken" : "after_id", value: cursor)]
            }
            let request = try request(connection: connection, url: components.url!, apiKey: apiKey)
            let page = try await responseData(request, service: .model(connection.provider), step: .models,
                                              connectionName: connection.name, requestText: String(localized: "拉取模型列表")) {
                try ModelResponseCodec.modelListPage($0, provider: connection.provider)
            }
            models.formUnion(page.models)
            guard models.count <= 20_000 else { throw TincallError(message: String(localized: "模型列表过大，请使用更具体的连接端点")) }
            guard let next = page.nextCursor else { break }
            guard seen.insert(next).inserted, seen.count < 100 else { throw TincallError(message: String(localized: "模型列表分页重复或过多")) }
            cursor = next
        }
        guard !models.isEmpty else { throw TincallError(message: String(localized: "此连接没有返回可用模型")) }
        return models.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func responseData<Result>(_ request: URLRequest, service: RequestLogService, step: RequestLogStep,
                                      context: RequestLogContext? = nil, connectionName: String? = nil,
                                      modelName: String? = nil, requestText: String? = nil,
                                      reasoning: ((Data) throws -> String)? = nil, decode: (Data) throws -> Result) async throws -> Result {
        let log = RequestLogStore.shared.begin(service: service, step: step, context: context,
                                              connectionName: connectionName, modelName: modelName)
        log.protect(request)
        log.requestBody(request.httpBody)
        log.request(requestText ?? step.rawValue)
        defer { log.finish() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            log.response(response)
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                data.append(byte)
                guard data.count <= 8_388_608 else { throw TincallError(message: String(localized: "模型响应过大")) }
            }
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { log.body(data) }
            try Self.validateResponse(response, streaming: false)
            if let reasoning { log.reasoning(try reasoning(data)) }
            let result: Result
            do { result = try decode(data) } catch { log.body(data); throw error }
            if let text = result as? String { log.succeed(text) }
            else if let page = result as? (models: [String], nextCursor: String?) { log.succeed(String(localized: "返回 \(page.models.count) 个模型")) }
            else { log.succeed(String(localized: "请求完成")) }
            return result
        } catch { log.fail(error); throw Self.safeError(error) }
    }

    private nonisolated static func safeError(_ error: Error) -> Error {
        if Task.isCancelled || error is CancellationError { return CancellationError() }
        if error is TincallError { return error }
        return TincallError(message: String(localized: "模型网络请求失败（\((error as NSError).code)）"))
    }

    private nonisolated static func validateResponse(_ response: URLResponse, streaming: Bool) throws {
        guard let http = response as? HTTPURLResponse else { throw TincallError(message: String(localized: "模型未返回 HTTP 响应")) }
        guard (200..<300).contains(http.statusCode) else {
            throw TincallError(message: http.statusCode == 400
                ? String(localized: "模型拒绝请求参数（HTTP 400），请检查模型名称、输出上限、思考模式／强度及温度／Top P 支持情况")
                : String(localized: "模型请求失败（HTTP \(http.statusCode)）"))
        }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard type.contains(streaming ? "text/event-stream" : "application/json") else {
            throw TincallError(message: streaming ? String(localized: "模型未返回约定的流式格式") : String(localized: "模型未返回 JSON 格式"))
        }
    }

}
