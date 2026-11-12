// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

private final class DeploymentNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Deliberately separate from RequestLogStore and the ordinary connector transport.
/// Neither request/response bodies nor underlying errors (which can contain credentials) escape.
@MainActor
final class SupabaseManagementClient {
    static let officialPushURL = URL(string: "https://tincall-push.tincall-app.workers.dev")!
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration, delegate: DeploymentNoRedirects(), delegateQueue: nil)
    }

    func close() { session.invalidateAndCancel() }

    func management(_ path: String, pat: String, body: Any? = nil) async throws -> Data {
        try await send(URL(string: "https://api.supabase.com/v1/projects/\(path)")!,
                       headers: ["Authorization": "Bearer \(pat)"], body: body)
    }

    func query(ref: String, pat: String, sql: String, parameters: [String] = [], readOnly: Bool = false) async throws -> Data {
        var body: [String: Any] = ["query": sql]
        if !parameters.isEmpty { body["parameters"] = parameters }
        if readOnly { body["read_only"] = true }
        return try await management("\(ref)/database/query", pat: pat, body: body)
    }

    /// The user's deployment relays enrollment: phones on some networks cannot
    /// reach the official push host, while they already reach their Supabase.
    func registerOfficialPush(ref: String, token: String) async throws {
        var request = URLRequest(url: URL(string: "https://\(ref).supabase.co/functions/v1/tincall/push/register")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        struct Registration: Decodable { let registered: Bool }
        do {
            for attempt in 1...5 {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // A function deployed, or a credential written, moments earlier can still be
                // served by the previous version or environment.
                if [403, 404].contains(status), attempt < 5 { try await Task.sleep(for: .seconds(2)); continue }
                guard (200..<300).contains(status), try Self.decode(Registration.self, data).registered else { break }
                return
            }
        } catch is CancellationError { throw CancellationError() }
        catch {}
        throw TincallError(message: String(localized: "官方来电推送尚未开通。云端配置已保留，请稍后重试部署，会继续完成开通。"))
    }

    func verifyConfiguredOfficialPush(ref: String, token: String) async throws -> Bool {
        let challenge = UUID().uuidString.lowercased()
        var request = URLRequest(url: URL(string: "https://\(ref).supabase.co/functions/v1/tincall/push/verify")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(challenge, forHTTPHeaderField: "x-tincall-push-challenge")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw TincallError(message: String(localized: "无法核对现有官方推送配置，原配置未被覆盖。"))
            }
            if [401, 403].contains(http.statusCode) { return false }
            guard (200..<300).contains(http.statusCode) else {
                throw TincallError(message: String(localized: "无法核对现有官方推送配置，原配置未被覆盖。"))
            }
            struct Proof: Decodable { let verified: Bool; let challenge: String }
            guard let proof = try? Self.decode(Proof.self, data), proof.verified, proof.challenge == challenge else {
                throw TincallError(message: String(localized: "无法核对现有官方推送配置，原配置未被覆盖。"))
            }
            return true
        } catch is CancellationError { throw CancellationError() }
        catch let error as TincallError { throw error }
        catch {
            throw TincallError(message: String(localized: "无法核对现有官方推送配置，原配置未被覆盖。"))
        }
    }

    func createOwner(ref: String, key: String, email: String) async throws -> UUID {
        var headers = ["apikey": key]
        // sb_secret_ keys are not JWTs. Legacy service_role JWTs need both headers.
        if !key.hasPrefix("sb_secret_") { headers["Authorization"] = "Bearer \(key)" }
        let data = try await send(URL(string: "https://\(ref).supabase.co/auth/v1/admin/users")!,
                                  headers: headers, body: ["email": email, "email_confirm": true])
        struct User: Decodable { let id: UUID; let email: String }
        let user = try Self.decode(User.self, data)
        guard user.email.lowercased() == email else { throw TincallError(message: String(localized: "Auth 返回的用户邮箱不匹配，已停止部署。")) }
        return user.id
    }

    func deployFunction(ref: String, pat: String, resources: CloudDeploymentResources) async throws {
        let boundary = "Tincall-\(UUID().uuidString)"
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n")
        let metadata: [String: Any] = ["name": "tincall", "entrypoint_path": "supabase/functions/tincall/index.ts",
                                      "verify_jwt": false, "import_map_path": "", "static_patterns": [String]()]
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        append("\r\n")
        for path in CloudDeploymentResources.functionPaths {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(path)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            body.append(try resources.read(path))
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        _ = try await send(URL(string: "https://api.supabase.com/v1/projects/\(ref)/functions/deploy?slug=tincall")!,
                           headers: ["Authorization": "Bearer \(pat)"], rawBody: body,
                           contentType: "multipart/form-data; boundary=\(boundary)")
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw TincallError(message: String(localized: "Supabase 返回的数据格式无法识别，已停止部署。")) }
    }

    private func send(_ url: URL, headers: [String: String], body: Any? = nil,
                      rawBody: Data? = nil, contentType: String = "application/json") async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = body == nil && rawBody == nil ? "GET" : "POST"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        if let rawBody { request.httpBody = rawBody }
        if request.httpBody != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw TincallError(message: String(localized: "Supabase 未返回有效的 HTTP 响应。")) }
            guard (200..<300).contains(http.statusCode) else {
                // Classify known failures without forwarding server text, SQL or echoed secrets.
                let text = String(decoding: data, as: UTF8.self).lowercased()
                let message: String
                switch http.statusCode {
                case 401, 403: message = String(localized: "令牌不对或权限不够，请检查本次部署授权。")
                case 404: message = String(localized: "项目或所需接口没找到，请检查项目编号和项目状态。")
                case 429: message = String(localized: "Supabase 请求过于频繁，请稍后重新部署。")
                default:
                    if text.contains("extension") || text.contains("pg_cron") || text.contains("pg_net") || text.contains("supabase_vault") {
                        message = String(localized: "所需扩展不可用或没有启用权限，请检查 pg_cron、pg_net 和 Vault。")
                    } else if text.contains("tincall_install_conflict") || text.contains("already exists") || text.contains("duplicate") {
                        message = String(localized: "已有资源或迁移版本冲突，已停止；不会清除原有数据。")
                    } else if text.contains("permission denied") {
                        message = String(localized: "数据库权限不足，无法执行当前部署步骤。")
                    } else { message = String(localized: "Supabase 未完成当前步骤（HTTP \(http.statusCode)），请检查项目后重试。") }
                }
                throw TincallError(message: message)
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as TincallError { throw error }
        catch {
            throw TincallError(message: String(localized: "网络连接中断或请求超时，远端结果可能尚未返回；重新部署会先检查已完成的迁移，不会直接重复执行。"))
        }
    }
}
