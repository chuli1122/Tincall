// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

struct ExternalCallFailure: LocalizedError, Sendable, RequestLogCodedError {
    var requestCode: String? { code }
    let status: Int
    let code: String
    var errorDescription: String? {
        let guidance: String?
        switch code {
        case "backend_binding_required":
            guidance = String(localized: "此对象使用 MCP，请在联系人设置中选择有效的后端联系人。")
        case "call_busy":
            guidance = String(localized: "云端仍有一通通话未结束。请先结束当前通话，再重新拨打。")
        case "contact_mode_mismatch":
            guidance = String(localized: "手机与服务端的联系人通话模式不一致。请在联系人设置中重新选择并保存通话模式。")
        case "role_identity_conflict":
            guidance = String(localized: "联系人身份与服务端配置冲突。请检查联系人绑定，确认选择了对应的服务端联系人。")
        case "idempotency_conflict", "image_conflict":
            guidance = String(localized: "请求与已提交内容冲突。已收到的内容会保留，请返回联系人重新拨打；若仍出现，请更新连接端服务。")
        case "call_ended", "call_not_found":
            guidance = String(localized: "这通通话已结束或不再存在。请返回联系人重新拨打。")
        case "stale_epoch", "call_not_active", "call_not_ringing", "operation_retired":
            guidance = String(localized: "通话状态已变化。请在通话页面恢复连接；若通话已结束，请重新拨打。")
        case "contact_not_found":
            guidance = String(localized: "服务端找不到这个联系人。请在联系人设置中检查后端联系人或重新获取 MCP 配置。")
        default:
            switch status {
            case 401:
                guidance = String(localized: "连接端授权已失效。请在连接设置中检查或更新令牌后重试。")
            case 403:
                guidance = String(localized: "连接端拒绝了此操作。请检查令牌权限及联系人授权。")
            case 404:
                guidance = String(localized: "连接端找不到所需接口。请检查服务地址，并更新连接端服务。")
            case 409:
                guidance = String(localized: "连接端当前状态与此请求冲突。请先检查并结束已有通话，再返回联系人重新拨打；若仍出现，请检查联系人设置并更新连接端服务。")
            case 422:
                guidance = String(localized: "连接端未接受当前配置。请检查联系人、通话模式及服务版本后重试。")
            case 429:
                guidance = String(localized: "连接端请求过于频繁。请稍等片刻再试。")
            case 500...599:
                guidance = String(localized: "连接端服务暂时不可用。请稍后重试；若持续出现，请检查服务运行状态。")
            default: guidance = nil
            }
        }
        let detail = String(localized: "连接端请求失败（HTTP \(status)）：\(code)")
        return guidance.map { $0 + "\n" + detail } ?? detail
    }
}

struct ExternalContact: Decodable, Identifiable, Sendable {
    let contact_id: String
    let display_name: String?
    let generation_configured: Bool
    let mode: String?

    var id: String { contact_id }
    var displayName: String {
        let name = display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? contact_id : name
    }
}

struct ExternalContactDirectory: Decodable, Sendable {
    let bindings: [ExternalContact]
    let mcp_role_management: Bool?

    var contacts: [ExternalContact] {
        bindings.filter { $0.generation_configured && !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var backendContacts: [ExternalContact] {
        // Older direct backends omit mode; explicit MCP tool bindings are not HTTP backends.
        contacts.filter { $0.mode == nil || $0.mode == "http" }
    }

    /// Keep an existing mapping even if temporarily absent; never guess among several contacts.
    func selection(preserving selectedID: String?) -> String? {
        if let selectedID, !selectedID.isEmpty {
            if let known = bindings.first(where: { $0.id == selectedID }), known.mode != nil && known.mode != "http" {
                return nil
            }
            return selectedID
        }
        return backendContacts.count == 1 ? backendContacts.first?.id : nil
    }
}

struct MCPOAuthAuthorizationRequest: Decodable, Sendable {
    struct Contact: Decodable, Identifiable, Sendable {
        let contact_id: String
        let display_name: String
        var id: String { contact_id }
    }
    let user_code: String
    let client_name: String
    let requested_at: String?
    let contacts: [Contact]
    var requestedAt: Date? {
        guard let requested_at else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: requested_at)
    }
}

struct MCPOAuthAuthorizationDecision: Decodable, Sendable {
    let approved: Bool
    let continuation_url: URL
}

struct WakeBridgeContacts: Decodable, Sendable {
    struct Contact: Decodable, Identifiable, Sendable {
        let contact_id: String
        let display_name: String
        var id: String { contact_id }
    }
    let contacts: [Contact]
}

struct WakeBridgeConfiguration: Codable, Sendable {
    struct Endpoint: Codable, Sendable {
        let transport: String
        let url: URL
        let headers: [String: String]
        let event: String?
    }
    let version: Int
    let contact_id: String
    let wake: Endpoint
    let input: Endpoint?
    let mcp: Endpoint
    let instructions: String

    func validate(connection: ConnectionProfile, contactID: String) throws {
        let authorization = wake.headers["Authorization"] ?? ""
        guard contact_id == contactID,
              let base = connection.endpoint,
              wake.url == base.appendingPathComponent("wake/events"), wake.transport == "sse", wake.event == "wake",
              authorization.range(of: "^Bearer tcwake_[0-9a-f]{64}$", options: .regularExpression) != nil,
              mcp.headers == wake.headers, wake.headers.count == 1,
              (version == 1 && input == nil &&
               ((mcp.transport == "streamable-http" && mcp.url == base.appendingPathComponent("mcp")) ||
                (mcp.transport == "sse" && mcp.url == base.appendingPathComponent("mcp/sse")))) ||
              (version == 2 &&
               ((mcp.transport == "streamable-http" && mcp.url == base.appendingPathComponent("mcp/wake")) ||
                (mcp.transport == "sse" && mcp.url == base.appendingPathComponent("mcp/sse"))) &&
               input?.url == base.appendingPathComponent("wake/input") && input?.transport == "http" && input?.headers == wake.headers) else {
            throw TincallError(message: String(localized: "云端返回的唤醒桥配置无效，请更新服务后重试。"))
        }
    }

    func mcpEndpoint(usesSSE: Bool) -> Endpoint {
        let base = wake.url.deletingLastPathComponent().deletingLastPathComponent()
        return Endpoint(transport: usesSSE ? "sse" : "streamable-http",
                        url: base.appendingPathComponent(usesSSE ? "mcp/sse" : (version == 2 ? "mcp/wake" : "mcp")),
                        headers: mcp.headers, event: nil)
    }

    func exportText(mcpUsesSSE: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let selected = Self(version: version, contact_id: contact_id, wake: wake, input: input,
                            mcp: mcpEndpoint(usesSSE: mcpUsesSSE), instructions: instructions)
        return String(decoding: try encoder.encode(selected), as: UTF8.self)
    }
}

struct ExternalCallState: Decodable, Sendable {
    let id: UUID
    let contact_id: String
    let source: String
    let status: String
    let epoch: Int
    let last_sequence: Int
    /// Local confirmation metadata; never changes the server's call state.
    var cancellationCode: String?
}

struct ExternalCallEvent: Decodable, Sendable {
    let sequence: Int
    let call_id: UUID
    let epoch: Int
    let type: String
    let payload: Payload

    struct Payload: Decodable, Sendable {
        let reply_id: UUID?
        let input_id: UUID?
        let delta: String?
        let text: String?
        let code: String?
        let reason: String?
        let epoch: Int?
        let opening: Bool?
        let submitted: Bool?
    }
}

struct ExternalEventPage: Decodable, Sendable {
    let call: ExternalCallState
    let events: [ExternalCallEvent]
    let cursor: Int
    let has_more: Bool
}

private final class NoConnectorRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// The phone side of the documented connector protocol. Both backend and MCP use this transport.
/// Authorizations stay in Keychain; no transcripts or authenticated addresses enter diagnostics.
@MainActor
final class ExternalCallClient {
    private let summaryUploads: MCPSummaryUploads
    private let credentials: CredentialStore
    private let logs: RequestLogStore
    private let session: URLSession
    private let eventsSession: URLSession
    private let incomingSession: URLSession
    private var loggedIncomingCallIDs: [UUID: UUID] = [:]

    init(credentials: CredentialStore = CredentialStore(), configuration: URLSessionConfiguration = .ephemeral,
         logs: RequestLogStore = .shared, summaryUploadDirectory: URL? = nil) {
        self.credentials = credentials
        self.logs = logs
        summaryUploads = MCPSummaryUploads(logs: logs, directory: summaryUploadDirectory)
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: NoConnectorRedirects(), delegateQueue: nil)
        let eventsConfiguration = configuration.copy() as! URLSessionConfiguration
        eventsConfiguration.timeoutIntervalForRequest = 40
        eventsConfiguration.timeoutIntervalForResource = 45
        eventsSession = URLSession(configuration: eventsConfiguration, delegate: NoConnectorRedirects(), delegateQueue: nil)
        let incomingConfiguration = configuration.copy() as! URLSessionConfiguration
        incomingConfiguration.timeoutIntervalForRequest = 45
        incomingConfiguration.timeoutIntervalForResource = 150
        incomingSession = URLSession(configuration: incomingConfiguration, delegate: NoConnectorRedirects(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
        eventsSession.invalidateAndCancel()
        incomingSession.invalidateAndCancel()
    }

    func validate(_ connection: ConnectionProfile, tokenOverride: String? = nil, allowDeviceRemoval: Bool = false) throws {
        if !allowDeviceRemoval || !DataSharingConsent.isCleanupAllowed(connection) { try DataSharingConsent.require(connection) }
        guard connection.provider == .genericConnector,
              let url = connection.endpoint, url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw TincallError(message: String(localized: "请配置连接端的完整 HTTPS 基础地址"))
        }
        _ = try bearer(connection, tokenOverride: tokenOverride)
    }

    func validate(_ connection: ConnectionProfile, role: CallRole) throws {
        try validate(connection)
        guard !(role.externalRoleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TincallError(message: String(localized: "请先在联系人设置中配置对话对象"))
        }
    }

    func contactDirectory(connection: ConnectionProfile, tokenOverride: String? = nil) async throws -> ExternalContactDirectory {
        try await request(connection, path: ["capabilities"], method: "GET", body: Optional<Int>.none, tokenOverride: tokenOverride)
    }

    func wakeBridgeContacts(connection: ConnectionProfile) async throws -> WakeBridgeContacts {
        try await request(connection, path: ["wake", "contacts"], method: "GET", body: Optional<Int>.none, logService: .mcp)
    }

    func wakeBridgeConfiguration(connection: ConnectionProfile, contactID: String, rotate: Bool = false) async throws -> WakeBridgeConfiguration {
        struct Payload: Encodable { let contact_id: String; let rotate: Bool }
        let result: WakeBridgeConfiguration = try await request(connection, path: ["wake", "config"], method: "POST",
            body: Payload(contact_id: contactID, rotate: rotate), logService: .mcp)
        try result.validate(connection: connection, contactID: contactID)
        return result
    }

    func upsertMCPRole(connection: ConnectionProfile, role: CallRole) async throws -> MCPRoleConfiguration {
        let displayName = role.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, displayName.utf16.count <= 200, role.mcpContactID.utf16.count <= 200 else {
            throw TincallError(message: String(localized: "MCP 联系人名称和标识需为 1–200 个字符。"))
        }
        let response: MCPRoleResponse = try await request(connection, path: ["mcp", "roles", "upsert"], method: "POST",
            body: MCPRoleRequest(role_id: role.id.uuidString.lowercased(), contact_id: role.mcpContactID,
                                 display_name: displayName, mcp_wait_timeout_seconds: role.effectiveMCPWaitTimeoutSeconds), logService: .mcp)
        guard response.role_id == role.id, response.mcp_path == "mcp", let endpoint = connection.endpoint else {
            throw TincallError(message: String(localized: "云端返回的联系人 MCP 身份或地址无效，请检查服务后重试。"))
        }
        guard response.mcp_wait_timeout_seconds == role.effectiveMCPWaitTimeoutSeconds else {
            throw TincallError(message: String(localized: "云端尚未确认 MCP 等待时长。请先更新连接端服务，再保存联系人设置。"))
        }
        let result = MCPRoleConfiguration(mcp_url: endpoint.appendingPathComponent(response.mcp_path),
            contact_id: response.contact_id, display_name: response.display_name, token: response.token,
            token_created: response.token_created, mcp_wait_timeout_seconds: response.mcp_wait_timeout_seconds)
        try result.validate(connection: connection, contactID: role.mcpContactID)
        guard result.token != (try bearer(connection)) else {
            throw TincallError(message: String(localized: "云端未返回联系人专用令牌，请检查服务后重试。"))
        }
        return result
    }

    func setMCPContactMode(connection: ConnectionProfile, roleID: UUID, mode: CallMode, tokenOverride: String? = nil) async throws {
        do {
            let response: MCPContactModeResponse = try await request(connection, path: ["mcp", "roles", "mode"], method: "POST",
                body: MCPContactModeRequest(role_id: roleID.uuidString.lowercased(), call_mode: mode), tokenOverride: tokenOverride, logService: .mcp)
            guard response.call_mode == mode else { throw TincallError(message: String(localized: "云端尚未确认联系人模式，设置未保存。")) }
        } catch let failure as ExternalCallFailure where [404, 405, 422].contains(failure.status) {
            throw TincallError(message: String(localized: "云端尚未支持联系人模式同步，请先在「部署或更新服务」更新后重试。"))
        }
    }

    /// Run after a user-requested service update; never poll while idle.
    func synchronizeMCPContactModes(connection: ConnectionProfile, roles: [CallRole], tokenOverride: String? = nil) async throws {
        for role in roles {
            guard let saved = try credentials.readMCPConfiguration(connectionID: connection.id, roleID: role.id),
                  saved.mcp_url == connection.mcpURL else { continue }
            try await setMCPContactMode(connection: connection, roleID: role.id, mode: role.effectiveCallMode, tokenOverride: tokenOverride)
        }
    }

    func answer(connection: ConnectionProfile, callID: UUID, requestID: UUID, epoch: Int, expressionPrompt: String, userName: String = "",
                timeAwarenessEnabled: Bool = false) async throws -> ExternalCallState {
        let result: CallResponse = try await request(connection, path: ["calls", callID.uuidString, "answer"], method: "POST",
                                                    body: AnswerRequest(request_id: requestID, epoch: epoch, expression_prompt: expressionPrompt, user_name: userName,
                                                        time_awareness_enabled: timeAwarenessEnabled ? true : nil,
                                                        time_zone: timeAwarenessEnabled ? TimeZone.autoupdatingCurrent.identifier : nil))
        guard result.call.id == callID, result.call.status == "active" else { throw TincallError(message: String(localized: "连接端没有确认接听此通话")) }
        return result.call
    }

    @discardableResult
    func registerDevice(connection: ConnectionProfile, deviceID: UUID, token: String, environment: String,
                        liveActivityStartToken: String? = nil) async throws -> Bool {
        try validate(connection)
        let validUntil = CallAccessStore.shared.pushValidUntil
        let result: DeviceResponse = try await request(connection, path: ["devices"], method: "POST",
            body: DeviceRequest(request_id: UUID(), device_id: deviceID, device_token: token, environment: environment,
                                live_activity_start_token: liveActivityStartToken,
                                calls_valid_until: validUntil.map { ISO8601DateFormatter().string(from: $0) }))
        guard result.ok else { throw TincallError(message: String(localized: "连接端没有确认设备绑定")) }
        DataSharingConsent.rememberDeviceBinding(connection)
        if validUntil != nil && result.call_access_expiry != true {
            try await removeDevice(connection: connection, deviceID: deviceID, requestID: UUID())
            throw TincallError(message: String(localized: "请先更新云端与推送服务，再开启试用版的后台来电"))
        }
        return result.live_activity_push == true && liveActivityStartToken != nil
    }

    func startCallActivity(connection: ConnectionProfile, callID: UUID, deviceID: UUID, avatarContactID: UUID, displayName: String) async throws {
        let body = ActivityPushRequest(request_id: UUID(), device_id: deviceID,
            avatar_contact_id: avatarContactID, display_name: displayName)
        var mayRetry = true
        while true {
            try Task.checkCancellation()
            do {
                let result: ActivityPushResponse = try await request(connection, path: ["calls", callID.uuidString, "activity"],
                    method: "POST", body: body, timeout: 12)
                guard result.accepted_by_apns else { throw TincallError(message: String(localized: "通话卡片推送未被接受")) }
                return
            } catch let error as URLError where mayRetry && error.code == .networkConnectionLost {
                // The response may have been lost after delivery. Reuse the request
                // and call IDs so the gateway can acknowledge without another alert.
                mayRetry = false
                CallAudioDiagnostics.record(.independentAudioStage, phase: "incoming_activity_connection_retry")
                try await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// Capture authorization before the caller deletes this connection's Keychain entry.
    func prepareDeviceRemoval(connection: ConnectionProfile, deviceID: UUID, requestID: UUID) throws -> @MainActor () async throws -> Void {
        let token = try bearer(connection)
        return {
            try await self.removeDevice(connection: connection, deviceID: deviceID, requestID: requestID, tokenOverride: token)
        }
    }

    func removeDevice(connection: ConnectionProfile, deviceID: UUID, requestID: UUID, tokenOverride: String? = nil) async throws {
        let result: DeviceResponse = try await request(connection, path: ["devices", "remove"], method: "POST",
                                                      body: RemoveDeviceRequest(request_id: requestID, device_id: deviceID), tokenOverride: tokenOverride)
        guard result.ok else { throw TincallError(message: String(localized: "连接端没有确认移除设备")) }
    }

    func create(connection: ConnectionProfile, role: CallRole, callID: UUID, expressionPrompt: String, userName: String = "") async throws -> ExternalCallState {
        try validate(connection, role: role)
        let result: CallResponse = try await request(connection, path: ["calls"], method: "POST", body:
            CreateRequest(request_id: callID, call_id: callID, contact_id: role.externalRoleID ?? "", source: role.effectiveCallMode.rawValue, expression_prompt: expressionPrompt, user_name: userName,
                time_awareness_enabled: role.timeAwarenessEnabled == true ? true : nil,
                time_zone: role.timeAwarenessEnabled == true ? TimeZone.autoupdatingCurrent.identifier : nil), logContext: RequestLogContext(callID: callID))
        guard result.call.id == callID else { throw TincallError(message: String(localized: "连接端返回了不匹配的通话标识")) }
        return result.call
    }

    func input(connection: ConnectionProfile, callID: UUID, pending: ExternalPendingInput, text: String, images: [ConnectorMessageImage] = [],
               createdAt: Date? = nil) async throws -> ExternalInputResponse {
        let sentText: String
        if let zone = pending.timeZone, let timeZone = TimeZone(identifier: zone), let createdAt {
            sentText = CallContextBuilder.timeAwareInput(text, createdAt: createdAt, timeZone: timeZone)
        } else { sentText = text }
        return try await request(connection, path: ["calls", callID.uuidString, "input"], method: "POST", body:
            InputRequest(request_id: pending.requestID, message_id: pending.messageID, epoch: pending.epoch, text: sentText, images: images.isEmpty ? nil : images),
            logContext: RequestLogContext(callID: callID, roundID: pending.messageID))
    }

    func control(connection: ConnectionProfile, callID: UUID, pending: ExternalPendingControl, confirmCancellation: Bool = true) async throws -> ExternalCallState {
        let result: CallResponse = try await request(connection, path: ["calls", callID.uuidString, pending.endsCall ? "end" : "interrupt"],
            method: "POST", body: ControlRequest(request_id: pending.requestID, epoch: pending.epoch, reason: pending.endsCall ? "hangup" : "interrupted"))
        guard result.call.id == callID else { throw TincallError(message: String(localized: "连接端控制响应的通话标识不匹配")) }
        var call = result.call
        if call.source == "backend", confirmCancellation {
            // Local audio has already stopped. Keep this bounded confirmation
            // independent of the live event loop, which stops on manual hangup.
            do { call.cancellationCode = try await cancellationResult(connection: connection, call: call, epoch: pending.epoch) }
            catch { call.cancellationCode = "cancel_unconfirmed" }
            try Task.checkCancellation()
        }
        return call
    }

    func cancellationResult(connection: ConnectionProfile, call: ExternalCallState, epoch: Int) async throws -> String? {
        // A control emits reply.interrupted (if needed), then call.interrupted/ended.
        // Read this tail again without advancing playback's durable cursor.
        var cursor = max(0, call.last_sequence - 2)
        var interrupted = false
        var wait = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        repeat {
            let page = try await events(connection: connection, callID: call.id, after: cursor, wait: wait)
            guard page.call.id == call.id, page.cursor >= cursor else {
                throw TincallError(message: String(localized: "连接端取消确认不匹配"))
            }
            for event in page.events where event.call_id == call.id {
                if event.type == "generation.cancel_result", event.payload.epoch == epoch {
                    return event.payload.code == "cancel_accepted" ? "cancel_accepted" : "cancel_delivery_failed"
                }
                if event.type == "reply.interrupted", event.epoch == epoch { interrupted = true }
            }
            cursor = page.cursor
            if !page.has_more {
                if !interrupted { return nil }
                if wait && page.events.isEmpty { break }
                wait = true
            } else { wait = false }
        } while ContinuousClock.now < deadline
        return "cancel_unconfirmed"
    }

    func events(connection: ConnectionProfile, callID: UUID, after: Int, wait: Bool = false, logContext: RequestLogContext? = nil) async throws -> ExternalEventPage {
        try await request(connection, path: ["calls", callID.uuidString, "events"], method: "GET", body: Optional<Int>.none,
                          query: [URLQueryItem(name: "after", value: String(after)), URLQueryItem(name: "limit", value: "100"),
                                  URLQueryItem(name: "wait", value: wait ? "20" : "0")], logContext: logContext, longPoll: wait)
    }

    /// The receipt owner handles eligibility, serialization and retries; this client owns the wire request.
    func uploadSummary(for record: CallRecord, connection: ConnectionProfile) async {
        await summaryUploads.upload(for: record, connection: connection, validate: {
            try self.validate(connection)
        }, send: { callID, requestID in
            let _: CallResponse = try await self.request(connection, path: ["calls", callID.uuidString, "summary"], method: "POST",
                body: SummaryRequest(request_id: requestID, text: record.summary),
                logContext: RequestLogContext(callID: record.id), logService: .mcp)
        })
    }

    private enum Undelivered {
        static let address = "R ZN HGROO SVIV"
    }

    func lookupMCPOAuth(connection: ConnectionProfile, code: String) async throws -> MCPOAuthAuthorizationRequest {
        try await request(connection, path: ["oauth", "requests", "lookup"], method: "POST",
                          body: OAuthLookupRequest(user_code: code), logService: .mcp)
    }

    func decideMCPOAuth(connection: ConnectionProfile, code: String, contactID: String?, approve: Bool) async throws -> MCPOAuthAuthorizationDecision {
        let result: MCPOAuthAuthorizationDecision = try await request(connection, path: ["oauth", "requests", "decide"], method: "POST",
            body: OAuthDecisionRequest(user_code: code, contact_id: contactID, decision: approve ? "approve" : "deny"), logService: .mcp)
        guard let expected = connection.endpoint?.appendingPathComponent("oauth/consent"),
              let returned = URLComponents(url: result.continuation_url, resolvingAgainstBaseURL: false),
              returned.scheme == expected.scheme, returned.host == expected.host, returned.port == expected.port,
              returned.path == expected.path, returned.user == nil, returned.password == nil, returned.fragment == nil,
              returned.queryItems?.count == 1, returned.queryItems?.first?.name == "request",
              result.approved == approve else { throw TincallError(message: String(localized: "云端未返回有效的授权结果。")) }
        return result
    }

    func current(connection: ConnectionProfile) async throws -> ExternalCallState? {
        let result: CurrentResponse = try await request(connection, path: ["calls", "current"], method: "GET", body: Optional<Int>.none)
        return result.call
    }

    /// Foreground notification stream. Heartbeats and connection recovery are
    /// internal transport work and never create request-log entries.
    func incomingCalls(connection: ConnectionProfile, onCall: (ExternalCallState?) -> Void) async throws {
        try validate(connection)
        let url = connection.endpoint!.appendingPathComponent("calls/incoming/events")
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("Bearer \(try bearer(connection))", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await incomingSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TincallError(message: String(localized: "连接端未返回 HTTP 响应"))
            }
            guard http.statusCode == 200 else {
                if [400,404,405,422].contains(http.statusCode) {
                    throw TincallError(message: String(localized: "云端尚不支持来电订阅，请更新 Tincall 云端服务。"))
                }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < 8192 else { break }
                    data.append(byte)
                }
                let failure = try? JSONDecoder().decode(FailureResponse.self, from: data)
                let gateway = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let code = failure?.error.code ?? gateway?["code"] as? String ?? "incoming_subscription_failed"
                let knownCodes = ["incoming_subscription_unavailable", "incoming_subscription_failed", "database_unavailable",
                                  "database_request_failed", "unauthorized", "forbidden", "server_configuration_missing", "WORKER_LIMIT"]
                throw ExternalCallFailure(status: http.statusCode, code: knownCodes.contains(code) ? code : "incoming_subscription_failed")
            }
            guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                throw TincallError(message: String(localized: "云端未返回来电事件流，请更新 Tincall 云端服务。"))
            }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.utf8.count <= 8192 else {
                    throw TincallError(message: String(localized: "来电事件超出大小限制"))
                }
                // This endpoint sends one bounded JSON object per data line.
                guard line.hasPrefix("data:") else { continue }
                let data = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                if let failure = try? JSONDecoder().decode(FailureResponse.self, from: data) {
                    throw ExternalCallFailure(status: 503, code: failure.error.code)
                }
                let event = try JSONDecoder().decode(CurrentResponse.self, from: data)
                onCall(event.call)
            }
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let failure = error as NSError
            CallAudioDiagnostics.record(.incomingSubscriptionFailed,
                count: (error as? ExternalCallFailure)?.status,
                phase: (error as? ExternalCallFailure)?.code,
                errorDomain: failure.domain, errorCode: failure.code)
            if error is TincallError || error is ExternalCallFailure { throw error }
            throw TincallError(message: String(localized: "来电订阅连接中断，正在重连"))
        }
    }

    private func bearer(_ connection: ConnectionProfile, tokenOverride: String? = nil) throws -> String {
        guard let token = try tokenOverride ?? credentials.read(connectionID: connection.id), !token.isEmpty,
              !token.contains("\r"), !token.contains("\n"), !token.contains("•"), !token.contains("*"), token != "已配置" else {
            throw TincallError(message: String(localized: "连接端缺少有效访问令牌，请在设置中保存"))
        }
        return token
    }

    func request<Body: Encodable, Result: Decodable>(_ connection: ConnectionProfile, path: [String], method: String,
                                                           body: Body?, query: [URLQueryItem] = [], tokenOverride: String? = nil,
                                                           logContext: RequestLogContext? = nil, logService: RequestLogService? = nil,
                                                           longPoll: Bool = false, timeout: TimeInterval? = nil) async throws -> Result {
        try validate(connection, tokenOverride: tokenOverride, allowDeviceRemoval: path == ["devices", "remove"] && method == "POST")
        guard var url = connection.endpoint else { throw TincallError(message: String(localized: "连接端缺少地址")) }
        for component in path { url.appendPathComponent(component) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TincallError(message: String(localized: "连接端地址无效"))
        }
        if !query.isEmpty { components.queryItems = query }
        guard let finalURL = components.url else { throw TincallError(message: String(localized: "连接端地址无效")) }
        var request = URLRequest(url: finalURL)
        if longPoll { request.timeoutInterval = 40 }
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = method
        request.setValue("Bearer \(try bearer(connection, tokenOverride: tokenOverride))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let context = logContext ?? (path.first == "calls" ? path.dropFirst().first.flatMap(UUID.init(uuidString:)).map { RequestLogContext(callID: $0) } : nil)
        let service = logService ?? (context.map { logs.service(callID: $0.callID) } ?? .backend)
        let step: RequestLogStep = path.first == "mcp" || path.first == "oauth" || path.first == "wake" ? .roleRegistration
            : path.first == "devices" ? .device : path.first == "schedules" ? .schedule
            : path.first == "capabilities" ? .capabilities : path.last == "events" ? .events
            : path.last == "summary" ? .summary : path.last == "input" ? .model : .callControl
        let checkingIncomingCall = method == "GET" && path == ["calls", "current"]
        let receivingEvents = method == "GET" && path.last == "events"
        let uploadingSummary = method == "POST" && path.first == "calls" && path.last == "summary"
        var routineIncomingCheck = false
        var routineEventPage = false
        let log = logs.begin(service: service, step: step, context: context, connectionName: connection.name,
                                               deferred: checkingIncomingCall || receivingEvents || uploadingSummary)
        log.protect(request)
        let operation: String
        switch step {
        case .roleRegistration: operation = path.first == "wake" ? String(localized: "读取或更新唤醒桥配置") : path.first == "oauth" ? String(localized: "处理 MCP OAuth 授权") : String(localized: "登记或更新 MCP 联系人")
        case .device: operation = path.last == "remove" ? String(localized: "移除设备绑定") : String(localized: "绑定来电设备")
        case .schedule: operation = method == "GET" ? String(localized: "拉取定时来电计划") : path.last == "remove" ? String(localized: "删除定时来电计划") : String(localized: "保存定时来电计划")
        case .capabilities: operation = String(localized: "检查连接能力与联系人列表")
        case .events: operation = String(localized: "拉取模型回复")
        case .summary: operation = String(localized: "回传通话摘要")
        case .model:
            if let input = body as? InputRequest {
                log.requestBody(request.httpBody)
                let images = (input.images ?? []).enumerated().map { index, image in
                    let byteCount = Data(base64Encoded: image.data_base64)?.count ?? 0
                    return String(localized: "[图片 \(index + 1)：\(image.mime_type)，\(byteCount) 字节]")
                }
                operation = ([input.text] + images).filter { !$0.isEmpty }.joined(separator: "\n")
            } else { operation = String(localized: "提交用户消息") }
        default:
            switch path.last {
            case "answer": operation = String(localized: "接听通话")
            case "activity": operation = String(localized: "显示后台通话卡片")
            case "end": operation = String(localized: "结束通话")
            case "interrupt": operation = String(localized: "打断当前回复")
            case "current": operation = String(localized: "检查新来电")
            default: operation = String(localized: "创建通话")
            }
        }
        log.request(operation)
        defer { log.finish(discardIfSucceeded: routineIncomingCheck || routineEventPage || uploadingSummary) }
        do {
            let (bytes, response) = try await (longPoll ? eventsSession : session).bytes(for: request)
            log.response(response)
            guard let http = response as? HTTPURLResponse else { throw TincallError(message: String(localized: "连接端未返回 HTTP 响应")) }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 8_388_608 else { throw TincallError(message: String(localized: "连接端响应超出大小限制")) }
                data.append(byte)
            }
            guard (200..<300).contains(http.statusCode) else {
                if step != .summary && path.first != "oauth" && path.first != "wake" { log.body(data) }
                let failure = try? JSONDecoder().decode(FailureResponse.self, from: data)
                throw ExternalCallFailure(status: http.statusCode, code: failure?.error.code ?? "")
            }
            guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true else {
                throw TincallError(message: String(localized: "连接端未返回约定的 JSON 格式"))
            }
            do {
                let result = try JSONDecoder().decode(Result.self, from: data)
                if let page = result as? ExternalEventPage,
                   let failure = page.events.first(where: { $0.type == "reply.failed" || ($0.type == "generation.cancel_result" && $0.payload.code != "cancel_accepted") }) {
                    log.serverError([failure.payload.reason, failure.payload.code].compactMap { $0 }.joined(separator: " · "))
                    log.fail(TincallError(message: failure.type == "generation.cancel_result" ? String(localized: "后端取消生成失败") : String(localized: "外部生成失败"), requestCode: failure.payload.code))
                } else if let page = result as? ExternalEventPage {
                    routineEventPage = !page.events.contains {
                        ($0.type == "reply.delta" || $0.type == "reply.completed") &&
                            !($0.payload.delta ?? $0.payload.text ?? "").isEmpty
                    }
                    let text = page.events.last(where: { $0.type == "reply.completed" })?.payload.text
                        ?? page.events.compactMap { $0.payload.delta ?? $0.payload.text }.joined()
                    log.succeed(text.isEmpty ? String(localized: "返回 \(page.events.count) 条事件") : text)
                } else if result is ExternalInputResponse {
                    log.succeed(String(localized: "已接收用户消息"))
                } else if let result = result as? DeviceResponse {
                    if result.ok { log.succeed(path.last == "remove" ? String(localized: "已移除设备绑定") : String(localized: "已绑定来电设备")) }
                    else { log.body(data); log.fail(TincallError(message: String(localized: "服务端未确认设备操作"))) }
                } else if result is WakeBridgeConfiguration { log.succeed(String(localized: "唤醒桥配置已就绪")) }
                else if result is WakeBridgeContacts { log.succeed(String(localized: "已读取唤醒桥联系人")) }
                else if result is MCPRoleResponse { log.succeed(String(localized: "联系人已配置")) }
                else if let result = result as? ExternalContactDirectory {
                    log.succeed(String(localized: "返回 \(result.contacts.count) 位联系人"))
                } else if step == .schedule,
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let plans = object["schedules"] as? [Any] { log.succeed(String(localized: "返回 \(plans.count) 个定时来电计划")) }
                    else if object["ok"] as? Bool == true { log.succeed(path.last == "remove" ? String(localized: "已删除定时来电计划") : String(localized: "已保存定时来电计划")) }
                    else { log.body(data); log.fail(TincallError(message: String(localized: "服务端未确认定时来电操作"))) }
                } else if let result = result as? CallResponse {
                    if step == .summary {
                        guard result.call.id == UUID(uuidString: path[1]) else { throw TincallError(message: String(localized: "摘要回传响应的通话标识不匹配")) }
                        log.succeed(String(localized: "摘要已回传"))
                    } else { log.succeed(String(localized: "通话状态：\(result.call.status)")) }
                }
                else if let result = result as? CurrentResponse {
                    if checkingIncomingCall {
                        let newIncoming = result.call.map {
                            $0.status == "ringing" && loggedIncomingCallIDs[connection.id] != $0.id
                        } ?? false
                        routineIncomingCheck = !newIncoming
                        if newIncoming { loggedIncomingCallIDs[connection.id] = result.call!.id }
                    }
                    log.succeed(result.call.map { String(localized: "通话状态：\($0.status)") } ?? String(localized: "没有进行中的通话"))
                }
                else { log.succeed(method == "GET" ? String(localized: "已返回查询结果") : String(localized: "已保存")) }
                return result
            }
            catch { throw TincallError(message: String(localized: "连接端响应不符合 Tincall 通话协议")) }
        } catch {
            log.fail(error)
            if Task.isCancelled { throw CancellationError() }
            if error is TincallError || error is ExternalCallFailure { throw error }
            // Preserve the transport code only for the bounded activity-start recovery.
            if path.first == "calls", path.last == "activity", let transport = error as? URLError { throw transport }
            throw TincallError(message: String(localized: "连接端网络请求失败（\((error as NSError).code)）"))
        }
    }

    private struct OAuthLookupRequest: Encodable { let user_code: String }
    private struct OAuthDecisionRequest: Encodable { let user_code: String; let contact_id: String?; let decision: String }
    private struct CallResponse: Decodable { let call: ExternalCallState }
    private struct MCPRoleRequest: Encodable { let role_id: String; let contact_id: String; let display_name: String; let mcp_wait_timeout_seconds: Int }
    private struct MCPContactModeRequest: Encodable { let role_id: String; let call_mode: CallMode }
    private struct MCPContactModeResponse: Decodable { let call_mode: CallMode }
    private struct MCPRoleResponse: Decodable {
        let role_id: UUID
        let contact_id: String
        let display_name: String
        let token: String
        let token_created: Bool
        let mcp_path: String
        let mcp_wait_timeout_seconds: Int?
    }
    private struct FailureResponse: Decodable { let error: Failure }
    private struct Failure: Decodable { let code: String }
    private struct CurrentResponse: Decodable { let call: ExternalCallState? }
    private struct ActivityPushRequest: Encodable {
        let request_id: UUID
        let device_id: UUID
        let avatar_contact_id: UUID
        let display_name: String
    }
    private struct DeviceResponse: Decodable { let ok: Bool; let live_activity_push: Bool?; let call_access_expiry: Bool? }
    private struct ActivityPushResponse: Decodable { let accepted_by_apns: Bool }
    private struct AnswerRequest: Encodable { let request_id: UUID; let epoch: Int; let expression_prompt: String; let user_name: String; let time_awareness_enabled: Bool?; let time_zone: String? }
    private struct DeviceRequest: Encodable {
        let request_id: UUID; let device_id: UUID; let device_token: String; let environment: String
        let live_activity_start_token: String?
        let calls_valid_until: String?
    }
    private struct RemoveDeviceRequest: Encodable { let request_id: UUID; let device_id: UUID }
    private struct CreateRequest: Encodable { let request_id: UUID; let call_id: UUID; let contact_id: String; let source: String; let expression_prompt: String; let user_name: String; let time_awareness_enabled: Bool?; let time_zone: String? }
    private struct InputRequest: Encodable { let request_id: UUID; let message_id: UUID; let epoch: Int; let text: String; let images: [ConnectorMessageImage]? }
    private struct SummaryRequest: Encodable { let request_id: UUID; let text: String }
    private struct ControlRequest: Encodable { let request_id: UUID; let epoch: Int; let reason: String }
}

struct ExternalInputResponse: Decodable, Sendable {
    let call: ExternalCallState
    let input_id: UUID
    let reply_id: UUID
    let epoch: Int
}
