// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation
import Security

private let testRef = "aaaaaaaaaaaaaaaaaaaa"
private let testPAT = "synthetic-deployment-PAT"
private let testKey = "sb_secret_synthetic-service-key"
private let testEmail = "owner@example.invalid"
private let testOwner = UUID(uuidString: "2df3ab82-6d7b-4b02-924a-4452d24ad216")!

private final class DeploymentProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = Fixture()
    final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        var versions: [String] = []
        var secretNames: [String] = []
        var functionExists = false
        var owner: UUID?
        var vault: [String: String] = [:]
        var clients: [[String: String]] = []
        var worker: String?
        var pushToken: String?
        var pushURL: String?
        var registrations = 0
        var losePushResponse = false
        var failure: String?
        var failureStatus = 500
        var loseMigrationResponse = false
        var legacyKey = false
        var calls: [String] = []
        var migrationWrites = 0
        var ownerCreates = 0
        var functionWrites = 0
        var secretWrites = 0
        var verifyFunctionBody = false
        var functionSources: [String: Data] = [:]
        var insecure = false
        var exposed = false
        var manualImages = false
        var installation: String?
        var migrationSQL: [String: String] = [:]
        var footprintSQL: String?
        func reset() {
            versions = []; secretNames = []; functionExists = false; owner = nil; vault = [:]
            clients = []; worker = nil; pushToken = nil; pushURL = nil; registrations = 0; losePushResponse = false
            failure = nil; failureStatus = 500; loseMigrationResponse = false
            legacyKey = false; calls = []; installation = nil; migrationWrites = 0; ownerCreates = 0
            functionWrites = 0; secretWrites = 0; verifyFunctionBody = false; insecure = false; exposed = false; manualImages = false; migrationSQL = [:]; footprintSQL = nil
        }
    }
    // Intercept EVERYTHING: an unrecognized URL fails locally, never falls back to the network.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }
    override func startLoading() {
        do {
            let body = try Self.body(request)
            let (status, value, timeout) = try Self.fixture.lock.withLock { () throws -> (Int, Any, Bool) in
                let f = Self.fixture
                let url = request.url!
                precondition(["api.supabase.com", "\(testRef).supabase.co", "tincall-push.tincall-app.workers.dev"].contains(url.host!))
                let path = url.path
                var operation = path
                var result: Any = [:]
                if url.host == "api.supabase.com" {
                    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(testPAT)")
                    precondition(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
                    let base = "/v1/projects/\(testRef)"
                    switch path {
                    case base: result = ["id": testRef, "status": "ACTIVE_HEALTHY"]
                    case base + "/secrets":
                        if request.httpMethod == "POST" {
                            let secrets = try JSONSerialization.jsonObject(with: body) as! [[String: String]]
                            let clientsValue = secrets.first { $0["name"] == "TINCALL_CLIENTS" }?["value"]
                            operation = secrets.contains { $0["name"] == "TINCALL_PUSH_TOKEN" } ? "push.secrets"
                                : clientsValue == "[]" ? "secrets.write" : "secrets.bind"
                            if f.failure != operation {
                                precondition(secrets.allSatisfy { $0["name"]!.hasPrefix("TINCALL_") })
                                for secret in secrets {
                                    if !f.secretNames.contains(secret["name"]!) { f.secretNames.append(secret["name"]!) }
                                    if secret["name"] == "TINCALL_WORKER_TOKEN" { f.worker = secret["value"] }
                                    if secret["name"] == "TINCALL_PUSH_TOKEN" { f.pushToken = secret["value"] }
                                    if secret["name"] == "TINCALL_PUSH_URL" { f.pushURL = secret["value"] }
                                    if secret["name"] == "TINCALL_CLIENTS" {
                                        f.clients = try JSONSerialization.jsonObject(with: Data(secret["value"]!.utf8)) as! [[String: String]]
                                    }
                                }
                                f.secretWrites += 1
                            }
                        } else { result = f.secretNames.map { ["name": $0] } }
                    case base + "/functions": result = f.functionExists ? [["slug": "tincall"]] : []
                    case base + "/database/migrations":
                        precondition(request.httpMethod == "GET")
                        result = f.versions.map { ["version": $0, "name": Self.migrationName($0)] }
                    case base + "/database/query":
                        let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                        let sql = payload["query"] as! String
                        let params = payload["parameters"] as? [String] ?? []
                        precondition(!sql.contains(testPAT) && !sql.contains(testKey))
                        if sql.hasPrefix("begin;") {
                            let version = ["202610110001", "202610110002", "202610140001", "202610160001", "202610180001", "202610190001", "202610190002", "202610200001", "202610200002", "202610200003", "202610200004", "202610200005", "202610200006", "202610210001", "202610210002", "202610210003", "202610220001", "202610220002", "202610250001"].first { sql.contains("values ('\($0)'") }!
                            operation = "migration.\(version)"
                            f.migrationSQL[version] = sql
                            precondition(sql.hasSuffix("commit;") && sql.contains("pg_advisory_xact_lock") && sql.contains("insert into supabase_migrations.schema_migrations"))
                            precondition(!sql.lowercased().contains("drop table") && !sql.lowercased().contains("truncate"))
                            if f.failure != operation {
                                precondition(!f.versions.contains(version), "Applied migration was re-executed")
                                if version == "202610110001" {
                                    let marker = "comment on table public.tincall_owners is '"
                                    let start = sql.range(of: marker)!.upperBound
                                    f.installation = String(sql[start...].prefix { $0 != "'" })
                                }
                                f.versions.append(version); f.migrationWrites += 1
                                if f.loseMigrationResponse {
                                    f.loseMigrationResponse = false; f.calls.append(operation)
                                    return (200, [:], true)
                                }
                            }
                        } else if sql.hasPrefix("select array(") {
                            f.footprintSQL = sql
                            result = [Self.footprint(f)]
                        } else if sql.contains("from cron.job") {
                            result = f.versions.contains("202610110002") ? [["name": "tincall-worker"]] : []
                        } else if sql.hasPrefix("select name from vault.secrets") {
                            result = f.vault.keys.map { ["name": $0] }
                        } else if sql.hasPrefix("select id from vault.secrets") {
                            result = f.vault[params[0]] == nil ? [] : [["id": Self.vaultID(params[0])]]
                        } else if sql.contains("vault.create_secret") {
                            operation = "vault.write"
                            if f.failure != operation { f.vault[params[1]] = params[0] }
                        } else if sql.contains("vault.update_secret") {
                            operation = "vault.write"
                            let name = params[0].lowercased() == Self.vaultID("tincall_worker_token") ? "tincall_worker_token" : "tincall_function_base"
                            if f.failure != operation { f.vault[name] = params[1] }
                        } else if sql.hasPrefix("select id from auth.users") {
                            precondition(params == [testEmail] && payload["read_only"] as? Bool == true)
                            result = f.owner.map { [["id": $0.uuidString]] } ?? []
                        } else { preconditionFailure("Unexpected SQL contract") }
                    case base + "/api-keys":
                        operation = "keys"
                        precondition(url.query == "reveal=true")
                        result = f.legacyKey ? [["name": "service_role", "api_key": "synthetic.legacy.jwt"]]
                            : [["name": "service_role", "api_key": NSNull()], ["type": "secret", "api_key": testKey]]
                    case base + "/functions/deploy":
                        operation = "function.deploy"
                        precondition(url.query == "slug=tincall")
                        let text = String(decoding: body, as: UTF8.self)
                        precondition(text.contains("name=\"metadata\"") && text.contains("\"verify_jwt\":false"))
                        for path in CloudDeploymentResources.functionPaths { precondition(text.contains("name=\"file\"; filename=\"\(path)\"")) }
                        for source in f.functionSources.values { precondition(text.contains(String(decoding: source, as: UTF8.self))) }
                        precondition(text.contains("import {configFromEnvironment") && text.contains("export function createConnector"))
                        f.verifyFunctionBody = true
                        if f.failure != operation { f.functionExists = true; f.functionWrites += 1 }
                    default: preconditionFailure("Unexpected Management API route")
                    }
                } else if path == "/auth/v1/admin/users" {
                    operation = "owner.create"
                    precondition(request.value(forHTTPHeaderField: "apikey") == (f.legacyKey ? "synthetic.legacy.jwt" : testKey))
                    precondition(request.value(forHTTPHeaderField: "Authorization") == (f.legacyKey ? "Bearer synthetic.legacy.jwt" : nil))
                    let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                    precondition(payload["email"] as? String == testEmail && payload["email_confirm"] as? Bool == true)
                    if f.failure != operation { f.owner = testOwner; f.ownerCreates += 1 }
                    result = ["id": testOwner.uuidString, "email": testEmail]
                } else if url.host == "tincall-push.tincall-app.workers.dev" {
                    precondition(path == "/services/register" && request.httpMethod == "POST")
                    precondition(f.pushURL == "https://tincall-push.tincall-app.workers.dev")
                    precondition(f.pushToken?.hasPrefix("tcpush_\(testRef)_") == true)
                    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(f.pushToken!)")
                    precondition(body == Data("{}".utf8))
                    precondition(!body.contains(Data(testPAT.utf8)) && !body.contains(Data(testKey.utf8)))
                    operation = "push.register"
                    if f.failure != operation { f.registrations += 1 }
                    if f.losePushResponse { f.losePushResponse = false; f.calls.append(operation); return (200, [:], true) }
                    result = ["registered": true]
                } else if path == "/functions/v1/tincall/capabilities" {
                    operation = "capabilities"
                    precondition(f.clients.count == 1 && f.clients[0]["owner_id"] == testOwner.uuidString.lowercased())
                    precondition(f.clients[0]["contact_id"] == nil)
                    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(f.clients[0]["token"]!)")
                    precondition(f.vault["tincall_worker_token"] == f.worker)
                    result = ["bindings": [], "owner_id": testOwner.uuidString]
                } else if path == "/functions/v1/tincall/push/verify" {
                    operation = "push.verify"
                    precondition(request.httpMethod == "POST")
                    precondition(body == Data("{}".utf8))
                    if request.value(forHTTPHeaderField: "Authorization") == "Bearer \(f.pushToken ?? "")" {
                        result = ["verified": true, "challenge": request.value(forHTTPHeaderField: "x-tincall-push-challenge") ?? ""]
                    } else {
                        return (403, ["error": "forbidden"], false)
                    }
                } else { preconditionFailure("Unexpected project route") }
                f.calls.append(operation)
                if f.failure == operation {
                    let message = operation == "capabilities" ? "synthetic capability failure" : "extension unavailable; \(testPAT) \(testKey)"
                    return (f.failureStatus, ["message": message], false)
                }
                return (operation == "function.deploy" ? 201 : 200, result, false)
            }
            if timeout { throw URLError(.timedOut) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: value))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    static func migrationName(_ version: String) -> String {
        ["202610110001": "tincall_connector", "202610110002": "tincall_cron", "202610140001": "tincall_mcp_roles", "202610160001": "tincall_voice_instructions", "202610180001": "tincall_recent_calls", "202610190001": "tincall_mcp_sse", "202610190002": "tincall_mcp_tools", "202610200001": "tincall_schedule_controls", "202610200002": "tincall_incoming_events", "202610200003": "tincall_mcp_oauth", "202610200004": "tincall_call_presence", "202610200005": "tincall_contact_mode", "202610200006": "tincall_wake_bridge", "202610210001": "tincall_mcp_voice_ack", "202610210002": "tincall_mcp_conversation", "202610210003": "tincall_message_images", "202610220001": "tincall_service_safety", "202610220002": "tincall_mcp_safety", "202610250001": "tincall_mcp_wait_preferences"][version] ?? "tincall_future"
    }
    static func vaultID(_ name: String) -> String {
        name == "tincall_worker_token" ? "ec02eca0-bee6-48df-a467-2c282198d192" : "0c676f4b-23b7-4d76-a442-6c362567bd7b"
    }
    static func footprint(_ f: Fixture) -> [String: Any] {
        let voice = f.versions.contains("202610160001"), recent = f.versions.contains("202610180001"), sse = f.versions.contains("202610190001")
        let first = f.versions.contains("202610110001"), cron = f.versions.contains("202610110002"), roles = f.versions.contains("202610140001")
        var functions: [String] = first ? ["tincall_emit", "tincall_stop_reply", "tincall_next_daily", "tincall_command", "tincall_worker_owners"] : []
        if roles { functions += ["tincall_mcp_role", "tincall_mcp_authenticate"] }
        if voice { functions += ["tincall_set_voice_prompt", "tincall_claim_voice_instructions"] }
        if recent { functions += ["tincall_recent_calls"] }
        if sse { functions += ["tincall_mcp_sse_command"] }
        if f.versions.contains("202610190002") { functions += ["tincall_mcp"] }
        if f.versions.contains("202610200001") { functions += ["tincall_schedule_command", "tincall_schedule_next"] }
        if f.versions.contains("202610200002") { functions += ["tincall_broadcast_incoming"] }
        if f.versions.contains("202610200003") { functions += ["tincall_oauth"] }
        if f.versions.contains("202610200004") { functions += ["tincall_call_presence"] }
        if f.versions.contains("202610200005") { functions += ["tincall_contact_mode"] }
        if f.versions.contains("202610200006") { functions += ["tincall_wake_bridge", "tincall_broadcast_wake"] }
        let images = f.manualImages || f.versions.contains("202610210003")
        if images { functions += ["tincall_image_command"] }
        if f.versions.contains("202610220001") { functions += ["tincall_remove_push_device"] }
        if f.versions.contains("202610220002") { functions += ["tincall_resolve_call_context"] }
        return ["tables": (first ? ["tincall_owners", "tincall_calls", "tincall_messages", "tincall_events", "tincall_requests", "tincall_jobs", "tincall_devices", "tincall_schedules", "tincall_push_jobs", "tincall_records"] : []) + (roles ? ["tincall_mcp_roles"] : []) + (sse ? ["tincall_mcp_sse"] : []) + (f.versions.contains("202610200003") ? ["tincall_oauth_clients", "tincall_oauth_requests", "tincall_oauth_grants"] : []) + (f.versions.contains("202610200006") ? ["tincall_wake_bridges"] : []),
                "functions": functions,
                "policies": first && !f.versions.contains("202610220001") ? ["tincall_media_read", "tincall_media_insert", "tincall_media_update", "tincall_media_delete"] : [],
                "bucket": first, "private_bucket": first, "has_images": images, "insecure_tables": f.insecure, "exposed_tables": first && (!f.versions.contains("202610220001") || f.exposed), "has_cron": cron, "has_vault": cron, "installation": f.installation as Any? ?? NSNull()]
    }
    static func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

@main private struct SupabaseDeploymentChecks {
    @MainActor static func main() async throws {
        let credentials = CredentialStore()
        let root = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1])
            : Bundle.main.resourceURL!.appendingPathComponent("CloudDeployment")
        var connected: [ConnectionProfile] = []
        var ids: Set<UUID> = []
        defer { for id in ids { try? credentials.delete(connectionID: id) }; clearCheckpoint() }
        func config() -> URLSessionConfiguration {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DeploymentProtocol.self]
            return config
        }
        func service() -> SupabaseDeploymentService {
            SupabaseDeploymentService(resources: CloudDeploymentResources(root: root), configuration: config) { profile, token in
                ids.insert(profile.id)
                // Same onConnect contract as the existing UI: capabilities first, then save.
                // No production UI code is changed or imported by the deployer.
                let client = ExternalCallClient(configuration: config())
                _ = try await client.contactDirectory(connection: profile, tokenOverride: token)
                let previous = try credentials.read(connectionID: profile.id)
                do {
                    try credentials.write(token, connectionID: profile.id)
                    connected.removeAll { $0.id == profile.id }
                    connected.append(profile)
                } catch {
                    try credentials.write(previous ?? "", connectionID: profile.id)
                    throw error
                }
            }
        }
        func run(_ service: SupabaseDeploymentService) async throws -> ConnectionProfile {
            try await service.deploy(pat: testPAT, projectRef: testRef, email: testEmail, allowDataSharing: true)
        }
        let fixture = DeploymentProtocol.fixture
        for path in CloudDeploymentResources.functionPaths {
            fixture.functionSources[path] = try CloudDeploymentResources(root: root).read(path)
        }
        func reset() { clearCheckpoint(); fixture.lock.withLock { fixture.reset() } }
        func failed(_ service: SupabaseDeploymentService, at step: CloudDeploymentStep) async throws {
            do { _ = try await run(service); preconditionFailure("Expected deployment failure") }
            catch let error as TincallError {
                precondition(!error.message.contains(testPAT) && !error.message.contains(testKey))
                precondition(service.progress.first(where: { $0.step == step })?.status == .failed)
                precondition(!service.isDeploying)
            }
        }

        if CommandLine.arguments.contains("--push-only") {
            reset()
            _ = try await run(service())
            #if TINCALL_APP_STORE
            let originalToken = fixture.pushToken!
            precondition(fixture.registrations == 1)
            let recovery = try JSONSerialization.jsonObject(with: credentials.readCloudDeployment(projectRef: testRef)!) as! [String: Any]
            precondition(recovery["pushToken"] == nil, "Remove the installation copy after successful enrollment")
            _ = try await run(service())
            precondition(fixture.registrations == 1 && fixture.pushToken == originalToken)
            fixture.lock.withLock { fixture.pushToken = "existing-custom-credential"; fixture.pushURL = "https://custom.invalid" }
            _ = try await run(service())
            precondition(fixture.pushToken == "existing-custom-credential" && fixture.registrations == 1)
            print("PASS: Store deployment enrolls once, removes its temporary credential and preserves existing senders")

            // Upgrade an old completed installation that has no push configuration.
            fixture.lock.withLock {
                fixture.secretNames.removeAll { $0.hasPrefix("TINCALL_PUSH_") }
                fixture.pushToken = nil; fixture.pushURL = nil
            }
            _ = try await run(service())
            precondition(fixture.registrations == 2 && fixture.pushToken != originalToken)
            print("PASS: an old completed deployment without a sender gains automatic enrollment")

            reset()
            fixture.lock.withLock { fixture.losePushResponse = true }
            try await failed(service(), at: .push)
            let pending = fixture.pushToken!
            _ = try await run(service())
            precondition(fixture.pushToken == pending && fixture.registrations == 2)
            print("PASS: a lost enrollment response resumes with the same credential")

            reset()
            fixture.lock.withLock { fixture.losePushResponse = true }
            try await failed(service(), at: .push)
            fixture.lock.withLock { fixture.pushToken = "existing-custom-credential"; fixture.pushURL = "https://custom.invalid" }
            let customWrites = fixture.secretWrites
            try await failed(service(), at: .push)
            precondition(fixture.pushToken == "existing-custom-credential" && fixture.secretWrites == customWrites)
            print("PASS: a custom sender added during enrollment retry is preserved")

            fixture.lock.withLock { fixture.secretNames.removeAll { $0 == "TINCALL_PUSH_TOKEN" } }
            let writes = fixture.secretWrites
            try await failed(service(), at: .push)
            precondition(fixture.secretWrites == writes)
            print("PASS: incomplete existing sender configuration is not overwritten")
            #else
            precondition(fixture.pushToken == nil && fixture.registrations == 0)
            _ = try await run(service())
            precondition(fixture.pushToken == nil && fixture.registrations == 0)
            print("PASS: source deployments never enroll with the official sender")
            #endif
            return
        }

        reset()
        let success = service()
        let profile = try await run(success)
        fixture.lock.withLock {
            precondition(fixture.migrationSQL["202610210003"]?.contains("tincall_image_command") == true,
                         "One-click deployment must install the image database migration")
            precondition(fixture.migrationSQL["202610250001"]?.contains("add column mcp_wait_timeout_seconds") == true,
                         "One-click deployment must install the MCP wait preference column")
        }
        // Export the actual production transactions for the isolated PostgreSQL check.
        // Only synthetic test installation identifiers are included.
        if CommandLine.arguments.count > 2 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (version, sql) in fixture.migrationSQL {
                try sql.write(to: directory.appendingPathComponent(version + ".sql"), atomically: true, encoding: .utf8)
            }
            if let sql = fixture.footprintSQL {
                try sql.write(to: directory.appendingPathComponent("footprint.sql"), atomically: true, encoding: .utf8)
            }
        }
        precondition(success.progress.allSatisfy { $0.status == .completed })
        precondition(connected.contains { $0.id == profile.id })
        let phone = try credentials.read(connectionID: profile.id)!
        precondition(phone.count == 64)
        let checkpoint = try credentials.readCloudDeployment(projectRef: testRef)!
        let recovery = try JSONSerialization.jsonObject(with: checkpoint) as! [String: Any]
        precondition(recovery["workerToken"] == nil)
        let recoveryText = String(decoding: checkpoint, as: UTF8.self)
        precondition(!recoveryText.contains(testPAT) && !recoveryText.contains(testKey))
        fixture.lock.withLock {
            precondition(fixture.migrationWrites == 19 && fixture.ownerCreates == 1 && fixture.verifyFunctionBody)
        }
        _ = try await run(service()) // New service instance, persisted recovery, completed deployment.
        fixture.lock.withLock { precondition(fixture.migrationWrites == 19 && fixture.ownerCreates == 1 && fixture.functionWrites == 2) }
        print("PASS: success, multipart production resources, owner binding, capabilities/save, Keychain recovery, completed rerun")
        fixture.lock.withLock { fixture.exposed = true }
        try await failed(service(), at: .inspection)
        fixture.lock.withLock { fixture.exposed = false }
        print("PASS: a hardened installation with restored anonymous/authenticated table grants stops before remote writes")

        // Adopt the former manually installed image SQL without rotating credentials.
        fixture.lock.withLock {
            fixture.versions.removeAll { ["202610210003", "202610220001", "202610220002", "202610250001"].contains($0) }
            fixture.manualImages = true
            fixture.migrationWrites = 0
        }
        let legacyImages = try await run(service())
        let legacyPhone = try credentials.read(connectionID: legacyImages.id)
        precondition(legacyImages.id == profile.id && legacyPhone == phone)
        fixture.lock.withLock {
            precondition(fixture.migrationWrites == 4 && fixture.ownerCreates == 1)
            fixture.manualImages = false
        }
        print("PASS: manually installed image schema upgrades into migration history without rotating credentials")

        // Simulate a completed seven-migration installation: its worker token has already
        // been removed. Upgrade must preserve credentials and apply only the missing SQL.
        var oldRecovery = recovery
        oldRecovery["completed"] = (recovery["completed"] as! [String]).filter { !["迁移：定时来电设置", "迁移：前台来电订阅", "迁移：MCP OAuth 授权", "迁移：通话占用回收", "迁移：联系人模式同步", "迁移：MCP 唤醒桥", "迁移：MCP 朗读规则确认", "迁移：MCP 简洁对话", "迁移：图片消息", "迁移：授权注册与推送清理", "迁移：MCP 通话与授权保护", "迁移：MCP 等待偏好"].contains($0) }
        try credentials.writeCloudDeployment(JSONSerialization.data(withJSONObject: oldRecovery), projectRef: testRef)
        fixture.lock.withLock {
            fixture.versions.removeAll { ["202610200001", "202610200002", "202610200003", "202610200004", "202610200005", "202610200006", "202610210001", "202610210002", "202610210003", "202610220001", "202610220002", "202610250001"].contains($0) }
            fixture.migrationWrites = 0; fixture.functionWrites = 0; fixture.calls = []
            fixture.failure = "migration.202610200001"
        }
        let upgradeFailure = service()
        do { _ = try await run(upgradeFailure); preconditionFailure("Expected missing migration failure") }
        catch { precondition(upgradeFailure.progress.contains { $0.status == .failed }) }
        fixture.lock.withLock {
            precondition(fixture.calls.last == "migration.202610200001")
            fixture.failure = "function.deploy"
        }
        try await failed(service(), at: .function)
        fixture.lock.withLock {
            precondition(fixture.migrationWrites == 12 && fixture.functionWrites == 0)
            fixture.failure = nil
        }
        let upgrade = service()
        let upgraded = try await run(upgrade)
        let upgradedPhone = try credentials.read(connectionID: upgraded.id)
        precondition(upgraded.id == profile.id && upgradedPhone == phone)
        for step in [CloudDeploymentStep.connector, .cron, .roles, .voiceInstructions] {
            precondition(upgrade.progress.first { $0.step == step }?.skipped == true)
        }
        fixture.lock.withLock {
            precondition(fixture.migrationWrites == 12 && fixture.functionWrites == 1)
            precondition(!fixture.calls.contains { ["secrets.write", "secrets.bind", "vault.write", "keys", "owner.create"].contains($0) })
        }
        print("PASS: completed old installation upgrades only missing migration, uploads current function, preserves credentials, and retries safely")

        reset()
        fixture.lock.withLock { fixture.failure = "migration.202610110002" }
        let interrupted = service()
        try await failed(interrupted, at: .cron)
        let before = try JSONSerialization.jsonObject(with: credentials.readCloudDeployment(projectRef: testRef)!) as! [String: Any]
        fixture.lock.withLock {
            precondition(fixture.migrationWrites == 1 && fixture.secretWrites == 0 && fixture.functionWrites == 0 && fixture.ownerCreates == 0)
            fixture.failure = nil
        }
        let retry = service()
        let resumed = try await run(retry)
        precondition(retry.progress.first { $0.step == .connector }?.skipped == true)
        let resumedPhone = try credentials.read(connectionID: resumed.id)
        precondition(resumedPhone == before["phoneToken"] as? String)
        fixture.lock.withLock { precondition(fixture.migrationWrites == 19 && fixture.worker == before["workerToken"] as? String) }
        print("PASS: extension failure stops; a new service resumes without reapplying migration or rotating tokens")

        reset()
        fixture.lock.withLock { fixture.failure = "migration.202610210003" }
        try await failed(service(), at: .messageImages)
        fixture.lock.withLock {
            precondition(fixture.migrationWrites == 15 && fixture.functionWrites == 0 && fixture.secretWrites == 0)
            fixture.failure = nil
            fixture.loseMigrationResponse = true
        }
        try await failed(service(), at: .messageImages)
        let imageRetry = service()
        _ = try await run(imageRetry)
        precondition(imageRetry.progress.first { $0.step == .messageImages }?.skipped == true)
        fixture.lock.withLock { precondition(fixture.migrationWrites == 19 && fixture.functionWrites == 1) }
        print("PASS: image migration failure stops deployment; a lost committed response resumes without reapplying SQL")

        reset()
        fixture.lock.withLock { fixture.loseMigrationResponse = true }
        try await failed(service(), at: .connector)
        _ = try await run(service())
        fixture.lock.withLock { precondition(fixture.migrationWrites == 19) }
        print("PASS: committed migration with lost response is discovered before retry")

        // Each later remote failure must prevent the connection callback; retry safely overwrites
        // secrets/functions/Vault and reuses an existing exact-email owner rather than duplicating it.
        for (operation, step) in [("secrets.write", CloudDeploymentStep.secrets), ("function.deploy", .function),
                                  ("vault.write", .vault), ("keys", .owner), ("owner.create", .owner), ("secrets.bind", .binding), ("capabilities", .connection)] {
            reset()
            fixture.lock.withLock { fixture.failure = operation }
            let count = connected.count
            try await failed(service(), at: step)
            precondition(connected.count == count)
            fixture.lock.withLock {
                precondition(fixture.calls.last == operation)
                fixture.failure = nil
            }
            _ = try await run(service())
            fixture.lock.withLock {
                precondition(fixture.migrationWrites == 19 && fixture.ownerCreates == 1 && fixture.vault.count == 2)
                if operation == "capabilities" {
                    precondition(fixture.functionWrites == 2, "Retry must upload the current function source after a failed connection check")
                    // One history inspection per attempt, plus confirmation after each actual migration.
                    precondition(fixture.calls.filter { $0.hasSuffix("/database/migrations") }.count == 21)
                }
            }
        }
        print("PASS: secrets/function/Vault/keys/Auth/capabilities failures stop immediately and recover")

        reset()
        fixture.lock.withLock { fixture.legacyKey = true; fixture.owner = testOwner }
        _ = try await run(service())
        fixture.lock.withLock { precondition(fixture.ownerCreates == 0) }
        reset()
        fixture.lock.withLock { fixture.legacyKey = true }
        _ = try await run(service())
        print("PASS: exact-email owner reuse and legacy JWT versus sb_secret_ request headers")

        reset()
        fixture.lock.withLock { fixture.secretNames = ["TINCALL_CLIENTS"] }
        try await failed(service(), at: .inspection)
        let missingRecovery = try credentials.readCloudDeployment(projectRef: testRef)
        precondition(missingRecovery == nil)
        fixture.lock.withLock { precondition(fixture.migrationWrites == 0 && fixture.secretWrites == 0) }
        reset()
        fixture.lock.withLock { fixture.versions = ["202610110001", "202610110002", "202610140001", "209901010001"] }
        try await failed(service(), at: .inspection)
        reset()
        fixture.lock.withLock { fixture.failure = "/v1/projects/\(testRef)"; fixture.failureStatus = 401 }
        try await failed(service(), at: .project)
        fixture.lock.withLock { precondition(fixture.calls.count == 1) }
        reset()
        fixture.lock.withLock { fixture.failure = "/v1/projects/\(testRef)"; fixture.failureStatus = 404 }
        try await failed(service(), at: .project)
        print("PASS: unknown installation/version and 401/404 fail closed without remote writes")

        reset()
        fixture.lock.withLock { fixture.loseMigrationResponse = true }
        try await failed(service(), at: .connector)
        fixture.lock.withLock { fixture.installation = "Tincall mobile installation another-device" }
        try await failed(service(), at: .inspection)
        fixture.lock.withLock { precondition(fixture.migrationWrites == 1 && fixture.secretWrites == 0) }
        let logText = String(decoding: try JSONEncoder().encode(RequestLogStore.shared.entries), as: UTF8.self)
        precondition(!logText.contains(testPAT) && !logText.contains(testKey))
        print("PASS: another installation cannot claim recovery credentials; PAT/service keys absent from request logs")
    }
    static func clearCheckpoint() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: "com.tincall.app.connections",
                       kSecAttrAccount as String: "cloud-deployment.\(testRef)"] as CFDictionary)
    }
}
