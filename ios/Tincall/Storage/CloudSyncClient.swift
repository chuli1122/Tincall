// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

struct CloudSyncFailure: LocalizedError, Sendable, RequestLogCodedError {
    var requestCode: String? { code }
    let status: Int
    let code: String
    var errorDescription: String? {
        switch code {
        case "revision_conflict": return String(localized: "云端记录已被其他设备修改，请刷新后处理冲突。")
        case "operation_retired": return String(localized: "此请求对应的云端副本已删除，请刷新后处理；不会自动恢复旧内容。")
        case "forbidden": return String(localized: "此令牌没有所属账户的备份权限，请更换连接凭据。")
        case "record_deleted": return String(localized: "云端副本已删除，未重新上传。")
        case "media_cleanup_failed", "media_cleanup_pending": return String(localized: "云端文字已删除，媒体清理未完成。请继续上次操作。")
        case "body_too_large": return String(localized: "此通电话超过云端备份大小限制，本机记录保持完整。")
        default: return String(localized: "云端请求失败（HTTP \(status)）：\(code)")
        }
    }
}

private final class CloudSyncNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class CloudSyncClient {
    static let maximumMediaBytes = 512 * 1024 * 1024
    static let maximumJSONBytes = 8 * 1024 * 1024
    private let credentials: CredentialStore
    private let logs: RequestLogStore
    private let session: URLSession
    private var authenticatedConnection: ConnectionProfile?
    private var authenticatedToken: String?
    private(set) var supportsBackupOnlyDeletion = false
    var isAutomaticSync = false

    init(credentials: CredentialStore = CredentialStore(), configuration: URLSessionConfiguration = .ephemeral,
         logs: RequestLogStore = .shared) {
        self.credentials = credentials
        self.logs = logs
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: CloudSyncNoRedirects(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func owner(connection: ConnectionProfile) async throws -> UUID {
        authenticatedConnection = connection
        authenticatedToken = try token(connection)
        supportsBackupOnlyDeletion = false
        struct Capabilities: Decodable { let owner_id: UUID?; let backup_only_deletion: Bool? }
        let response: Capabilities = try await json(connection, path: ["capabilities"])
        guard let owner = response.owner_id else { throw TincallError(message: String(localized: "此连接未提供所属账户的云端备份能力")) }
        supportsBackupOnlyDeletion = response.backup_only_deletion == true
        return owner
    }

    func list(connection: ConnectionProfile) async throws -> [CloudSyncRemote] {
        struct Page: Decodable { let records: [WireRemote]; let next_cursor: CloudSyncCursor? }
        var result: [UUID: CloudSyncRemote] = [:]
        var cursor: CloudSyncCursor?
        for _ in 0..<501 {
            let query = cursor.map { [URLQueryItem(name: "after", value: $0.after), URLQueryItem(name: "after_id", value: $0.after_id.uuidString)] } ?? []
            let page: Page = try await json(connection, path: ["records"], query: query)
            guard page.records.count <= 100 else { throw TincallError(message: String(localized: "云端记录分页格式无效")) }
            for wire in page.records {
                let record = wire.local
                guard record.revision > 0 else { throw TincallError(message: String(localized: "云端记录版本无效")) }
                if let old = result[record.id], old.revision > record.revision { continue }
                result[record.id] = record
            }
            if page.records.isEmpty { return Array(result.values) }
            guard let next = page.next_cursor, next != cursor else { throw TincallError(message: String(localized: "云端记录分页没有推进")) }
            cursor = next
        }
        throw TincallError(message: String(localized: "云端记录数量超过同步限制，未省略记录"))
    }

    func get(connection: ConnectionProfile, id: UUID) async throws -> CloudSyncRemote? {
        struct Response: Decodable { let record: WireRemote? }
        let result: Response = try await json(connection, path: ["records", id.uuidString])
        if var value = result.record?.local {
            guard value.id == id, value.revision > 0 else { throw TincallError(message: String(localized: "云端记录标识或版本不匹配")) }
            if !value.deleted {
                guard let document = value.record else { throw TincallError(message: String(localized: "云端通话备份正文缺失")) }
                value.record = try document.validated(recordID: id)
            }
            return value
        }
        return nil
    }

    func mutate(connection: ConnectionProfile, pending: CloudSyncPending, images: [UUID: ConnectorMessageImage] = [:]) async throws -> CloudSyncRemote {
        struct Body: Encodable { let request_id: UUID; let expected_revision: Int; let record: CloudSyncWireDocument? }
        struct Response: Decodable { let record: WireRemote }
        let document = pending.document.map { CloudSyncWireDocument($0, images: images) }
        let body = try JSONEncoder().encode(Body(request_id: pending.requestID, expected_revision: pending.expectedRevision, record: document))
        let limit = images.isEmpty ? Self.maximumJSONBytes : 28 * 1024 * 1024
        guard body.count <= limit else { throw TincallError(message: String(localized: "此通电话超过云端备份请求大小限制，本机保持完整")) }
        if pending.preserveCallMedia == true, !supportsBackupOnlyDeletion {
            throw TincallError(message: String(localized: "当前云端尚不支持安全清空备份，请先更新云端服务。"))
        }
        let path = ["records", pending.recordID.uuidString] + (pending.isDelete ? [pending.preserveCallMedia == true ? "delete-backup" : "delete"] : [])
        let result: Response = try await json(connection, path: path, method: "POST", body: body)
        guard result.record.id == pending.recordID, result.record.revision == pending.expectedRevision + 1,
              result.record.deleted == pending.isDelete else { throw TincallError(message: String(localized: "云端写入返回了不匹配的版本，请继续上次操作")) }
        let remote = result.record.local
        let hasImages = pending.document?.call.messages.contains { $0.images?.isEmpty == false } == true
        if let document = remote.record {
            _ = try document.validated(recordID: pending.recordID)
            if hasImages, document.call != pending.document?.call {
                throw TincallError(message: String(localized: "云端未确认完整的消息图片，请检查连接端版本后继续上次操作"))
            }
        } else if hasImages {
            throw TincallError(message: String(localized: "云端未返回消息图片引用，请检查连接端版本后继续上次操作"))
        }
        return remote
    }

    private struct WireRemote: Decodable {
        let id: UUID
        let revision: Int
        let deleted: Bool
        let updated_at: String
        let record: CloudSyncWireDocument?
        var local: CloudSyncRemote {
            CloudSyncRemote(id: id, revision: revision, deleted: deleted, updated_at: updated_at, record: record?.document)
        }
    }

    func downloadImage(connection: ConnectionProfile, recordID: UUID, image: CloudSyncImageReference, destination: URL) async throws {
        let request = try request(connection, path: ["records", recordID.uuidString, "media", image.id.uuidString])
        let automaticSync = isAutomaticSync
        let log = logs.begin(service: .cloud, step: .sync, connectionName: connection.name, deferred: automaticSync)
        log.protect(request); log.request(String(localized: "下载消息图片 1 张"))
        defer { log.finish(discardIfSucceeded: automaticSync) }
        do {
            guard image.bytes > 0, image.bytes <= ConnectorMessageImage.maximumBytes else { throw TincallError(message: String(localized: "云端图片大小无效")) }
            let (bytes, response) = try await session.bytes(for: request)
            log.response(response)
            var data = Data()
            let success = (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < (success ? image.bytes : 65_536) else { throw TincallError(message: String(localized: "云端图片响应超出声明大小")) }
                data.append(byte)
            }
            try validate(response, data: data)
            guard response.mimeType == image.mime_type, data.count == image.bytes else { throw TincallError(message: String(localized: "云端图片类型不符或下载不完整")) }
            try ConnectorMessageImage.validate(data, mimeType: image.mime_type)
            try data.write(to: destination, options: .atomic)
            log.succeed(String(localized: "图片已下载"))
        } catch { log.fail(error); throw safe(error) }
    }

    func upload(connection: ConnectionProfile, recordID: UUID, media: CloudSyncMedia, file: URL) async throws {
        var request = try request(connection, path: ["records", recordID.uuidString, "media", media.object_id.uuidString], method: "PUT")
        request.setValue(Self.contentType(media.fileExtension), forHTTPHeaderField: "Content-Type")
        request.setValue(String(media.bytes), forHTTPHeaderField: "Content-Length")
        let automaticSync = isAutomaticSync
        let log = logs.begin(service: .cloud, step: .sync, connectionName: connection.name, deferred: automaticSync)
        log.protect(request)
        log.request(String(localized: "上传通话录音 1 段（\(media.bytes) 字节）"))
        defer { log.finish(discardIfSucceeded: automaticSync) }
        do {
            let (data, response) = try await session.upload(for: request, fromFile: file)
            log.response(response)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { log.body(data) }
            try validate(response, data: data)
            struct Response: Decodable { let ok: Bool }
            guard try JSONDecoder().decode(Response.self, from: data).ok else { throw TincallError(message: String(localized: "云端未确认保存录音")) }
            log.succeed(String(localized: "录音已保存"))
        } catch { log.fail(error); throw safe(error) }
    }

    func download(connection: ConnectionProfile, recordID: UUID, media: CloudSyncMedia, destination: URL) async throws {
        let request = try request(connection, path: ["records", recordID.uuidString, "media", media.object_id.uuidString])
        let automaticSync = isAutomaticSync
        let log = logs.begin(service: .cloud, step: .sync, connectionName: connection.name, deferred: automaticSync)
        log.protect(request)
        log.request(String(localized: "下载通话录音 1 段"))
        defer { log.finish(discardIfSucceeded: automaticSync) }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            log.response(response)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try await log.errorBody(bytes)
                throw CloudSyncFailure(status: (response as? HTTPURLResponse)?.statusCode ?? 0, code: "media_download_failed")
            }
            guard media.bytes > 0, media.bytes <= Self.maximumMediaBytes else { throw TincallError(message: String(localized: "云端录音大小无效")) }
            let file = FileManager.default.createFile(atPath: destination.path, contents: nil)
            guard file else { throw TincallError(message: String(localized: "无法准备录音下载文件")) }
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var buffer = Data()
            var count = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                count += 1
                guard count <= media.bytes else { throw TincallError(message: String(localized: "云端录音超出声明大小，未导入")) }
                buffer.append(byte)
                if buffer.count >= 65_536 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            guard count == media.bytes else { throw TincallError(message: String(localized: "云端录音下载不完整，未导入")) }
            log.succeed(String(localized: "已下载 \(count) 字节"))
        } catch { log.fail(error); throw safe(error) }
    }

    func callImageIDs(connection: ConnectionProfile, callID: UUID) async throws -> Set<UUID> {
        struct Message: Decodable { let images: [CloudSyncImageReference]? }
        struct Record: Decodable { let messages: [Message] }
        do {
            let record: Record = try await json(connection, path: ["calls", callID.uuidString, "record"])
            return Set(record.messages.flatMap { ($0.images ?? []).map(\.id) })
        } catch let failure as CloudSyncFailure where failure.status == 404 && failure.code == "call_not_found" {
            return []
        }
    }

    func removeMedia(connection: ConnectionProfile, recordID: UUID, objectID: UUID) async throws {
        struct Response: Decodable { let ok: Bool }
        let _: Response = try await json(connection, path: ["records", recordID.uuidString, "media", objectID.uuidString], method: "DELETE")
    }

    private func request(_ connection: ConnectionProfile, path: [String], method: String = "GET", query: [URLQueryItem] = []) throws -> URLRequest {
        try DataSharingConsent.require(connection)
        guard connection.provider == .genericConnector, var url = connection.endpoint,
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw TincallError(message: String(localized: "请选择用户自有连接端的 HTTPS 基础地址")) }
        guard authenticatedConnection?.id == connection.id, authenticatedConnection?.endpoint == connection.endpoint,
              let token = authenticatedToken else { throw TincallError(message: String(localized: "请先检查云端连接")) }
        for part in path { url.appendPathComponent(part) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw TincallError(message: String(localized: "云端地址无效")) }
        if !query.isEmpty {
            components.queryItems = query
            // The connector uses form query decoding, where a literal + becomes a
            // space. Preserve the timezone sign in Supabase pagination timestamps.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let final = components.url else { throw TincallError(message: String(localized: "云端地址无效")) }
        var request = URLRequest(url: final)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func token(_ connection: ConnectionProfile) throws -> String {
        try DataSharingConsent.require(connection)
        guard let token = try credentials.read(connectionID: connection.id), !token.isEmpty,
              !token.contains("\r"), !token.contains("\n"), !token.contains("•"), !token.contains("*"), token != "已配置" else {
            throw TincallError(message: String(localized: "请先保存此连接的所属账户访问令牌"))
        }
        return token
    }

    private func json<Result: Decodable>(_ connection: ConnectionProfile, path: [String], method: String = "GET",
                                         body: Data? = nil, query: [URLQueryItem] = []) async throws -> Result {
        var request = try request(connection, path: path, method: method, query: query)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let automaticSync = isAutomaticSync
        let log = logs.begin(service: .cloud, step: .sync, connectionName: connection.name,
                                               deferred: automaticSync)
        log.protect(request)
        let operation = path.first == "capabilities" ? String(localized: "检查云端备份能力")
            : path.contains("media") ? String(localized: "删除云端录音 1 段")
            : method == "POST" ? (path.last?.hasPrefix("delete") == true ? String(localized: "删除通话备份 1 条") : String(localized: "上传通话备份 1 条"))
            : path.count > 1 ? String(localized: "拉取通话备份 1 条") : String(localized: "拉取通话备份列表")
        log.request(operation)
        defer { log.finish(discardIfSucceeded: automaticSync) }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            log.response(response)
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumJSONBytes + 65_536 else { throw TincallError(message: String(localized: "云端响应超过大小限制")) }
                data.append(byte)
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { log.body(data) }
            try validate(response, data: data)
            do {
                let result = try JSONDecoder().decode(Result.self, from: data)
                if method == "GET", let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let records = object["records"] as? [Any] { log.succeed(String(localized: "返回 \(records.count) 条通话备份")) }
                else { log.succeed(method == "GET" ? String(localized: "已返回备份查询结果") : path.last?.hasPrefix("delete") == true || method == "DELETE" ? String(localized: "已删除") : String(localized: "已保存")) }
                return result
            }
            catch { throw TincallError(message: String(localized: "云端响应不符合通话备份协议")) }
        } catch { log.fail(error); throw safe(error) }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw TincallError(message: String(localized: "云端未返回 HTTP 响应")) }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { struct Value: Decodable { let code: String }; let error: Value }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error.code ?? ""
            throw CloudSyncFailure(status: http.statusCode, code: code)
        }
    }

    private func safe(_ error: Error) -> Error {
        if Task.isCancelled { return CancellationError() }
        if error is TincallError || error is CloudSyncFailure { return error }
        return TincallError(message: String(localized: "云端连接或文件处理失败（\((error as NSError).code)）"))
    }

    private static func contentType(_ ext: String) -> String {
        switch ext {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "caf": return "audio/x-caf"
        default: return "application/octet-stream"
        }
    }
}
