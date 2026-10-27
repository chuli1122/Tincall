// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation
import Observation
import Security

struct CloudDeploymentResources {
    let root: URL
    static let functionPaths = [
        "supabase/functions/tincall/index.ts",
        "supabase/functions/_shared/tincall/service.mjs",
        "supabase/functions/_shared/tincall/server-version.json",
        "supabase/functions/_shared/tincall/protocol.mjs",
        "supabase/functions/_shared/tincall/supabase-store.mjs",
        "supabase/functions/_shared/tincall/message-images.mjs",
        "supabase/functions/_shared/tincall/call-commands.mjs",
        "supabase/functions/_shared/tincall/call-jobs.mjs",
        "supabase/functions/_shared/tincall/mcp.mjs",
        "supabase/functions/_shared/tincall/oauth.mjs"
    ]
    static func bundled() throws -> Self {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("CloudDeployment"),
              FileManager.default.fileExists(atPath: root.path) else {
            throw TincallError(message: String(localized: "App 缺少云端部署资源，请重新构建 App。"))
        }
        return Self(root: root)
    }
    func read(_ path: String) throws -> Data {
        do { return try Data(contentsOf: root.appendingPathComponent(path)) }
        catch { throw TincallError(message: String(localized: "无法读取 App 内的云端部署资源，请重新构建 App。")) }
    }
}

enum CloudDeploymentStep: String, Codable, CaseIterable, Sendable {
    case project = "确认项目", inspection = "检查旧安装", tokens = "生成部署令牌"
    case connector = "迁移：通话与备份", cron = "迁移：扩展与定时任务", roles = "迁移：MCP 联系人", voiceInstructions = "迁移：通话语音提示"
    case recentCalls = "迁移：近期通话", sse = "迁移：MCP SSE", mcpTools = "迁移：MCP 通话工具", schedules = "迁移：定时来电设置", incomingEvents = "迁移：前台来电订阅"
    case oauth = "迁移：MCP OAuth 授权", callPresence = "迁移：通话占用回收", contactMode = "迁移：联系人模式同步", wakeBridge = "迁移：MCP 唤醒桥"
    case mcpConversation = "迁移：MCP 简洁对话"
    case mcpVoiceAck = "迁移：MCP 朗读规则确认"
    case messageImages = "迁移：图片消息"
    case serviceSafety = "迁移：授权注册与推送清理"
    case callContext = "迁移：MCP 通话与授权保护"
    case mcpWaitPreferences = "迁移：MCP 等待偏好"
    case hotPathIndexes = "迁移：通话查询索引"
    case secrets = "写入函数 secrets", function = "部署 Edge Function", vault = "填写 Vault"
    case owner = "取得服务密钥并建立 owner", binding = "绑定手机令牌与 owner", push = "开通官方来电推送", connection = "检查能力并保存连接"
}

struct CloudDeploymentProgress: Identifiable, Sendable {
    enum Status: Sendable { case pending, running, completed, failed }
    let step: CloudDeploymentStep
    var status: Status = .pending
    var skipped = false
    var reason: String?
    var id: CloudDeploymentStep { step }
}

/// Recovery is independent of a screen's lifetime. Never add PATs or service keys here.
private struct CloudDeploymentCheckpoint: Codable {
    // Generated internally for Supabase Auth; never requested from the user.
    let email: String
    let connectionID: UUID
    let phoneToken: String
    var workerToken: String?
    var ownerID: UUID?
    var pushToken: String?
    var completed: Set<CloudDeploymentStep> = []
}

/// A UI may observe `progress`/`isDeploying` and call deploy(pat:projectRef:).
/// Inject the EXISTING CloudDeploymentGuide.onConnect callback: it requests /capabilities,
/// then invokes onSaveConnection (Keychain + configuration, including credential rollback).
/// No UI is wired here; keeping this callback required prevents a successful unsaved deployment.
@MainActor @Observable
final class SupabaseDeploymentService {
    private(set) var progress = CloudDeploymentStep.allCases.map { CloudDeploymentProgress(step: $0) }
    private(set) var isDeploying = false
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let resources: CloudDeploymentResources?
    @ObservationIgnored private let configuration: () -> URLSessionConfiguration
    @ObservationIgnored private let onConnect: (ConnectionProfile, String) async throws -> Void

    init(credentials: CredentialStore = CredentialStore(), resources: CloudDeploymentResources? = nil,
         configuration: @escaping () -> URLSessionConfiguration = { .ephemeral },
         onConnect: @escaping (ConnectionProfile, String) async throws -> Void) {
        self.credentials = credentials
        self.resources = resources
        self.configuration = configuration
        self.onConnect = onConnect
    }

    @discardableResult
    func deploy(pat: String, projectRef: String, email: String? = nil, allowDataSharing: Bool = false) async throws -> ConnectionProfile {
        guard !isDeploying else { throw TincallError(message: String(localized: "已有部署正在进行，请等待它结束。")) }
        isDeploying = true
        progress = CloudDeploymentStep.allCases.map { CloudDeploymentProgress(step: $0) }
        let client = SupabaseManagementClient(configuration: configuration())
        // Session/request references are invalidated on success, cancellation and every failure.
        // Swift strings cannot promise secure memory zeroing. Callers must also clear their PAT input.
        defer { client.close(); isDeploying = false }
        var step = CloudDeploymentStep.project
        func start(_ next: CloudDeploymentStep) throws {
            step = next
            update(next, status: .running)
            try Task.checkCancellation()
        }
        do {
            try start(.project)
            let pat = pat.trimmingCharacters(in: .whitespacesAndNewlines)
            let ref = projectRef.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedOwnerEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !pat.isEmpty, !pat.contains("\r"), !pat.contains("\n") else { throw TincallError(message: String(localized: "请填写有效的 Supabase 访问令牌。")) }
            guard (19...20).contains(ref.count), ref.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }) else {
                throw TincallError(message: String(localized: "项目编号应为 19 至 20 位小写字母或数字。"))
            }
            let resources = try resources ?? CloudDeploymentResources.bundled()
            // Validate all local resources before making any remote writes.
            for path in Self.migrations.map(\.path) + CloudDeploymentResources.functionPaths { _ = try resources.read(path) }
            struct Project: Decodable { let id: String; let status: String }
            let project = try SupabaseManagementClient.decode(Project.self, await client.management(ref, pat: pat))
            guard project.id == ref, project.status == "ACTIVE_HEALTHY" else { throw TincallError(message: String(localized: "项目尚未就绪，请先在 Supabase 恢复或等待项目启动。")) }
            update(step, status: .completed)

            try start(.inspection)
            var checkpoint = try credentials.readCloudDeployment(projectRef: ref).map {
                try JSONDecoder().decode(CloudDeploymentCheckpoint.self, from: $0)
            }
            if let requestedOwnerEmail, let checkpoint, checkpoint.email != requestedOwnerEmail {
                throw TincallError(message: String(localized: "此项目的续跑邮箱不匹配，请使用上次部署的邮箱；原配置已保留。"))
            }
            struct SecretName: Decodable { let name: String }
            struct FunctionName: Decodable { let slug: String }
            let secrets = try SupabaseManagementClient.decode([SecretName].self, await client.management("\(ref)/secrets", pat: pat))
            let functions = try SupabaseManagementClient.decode([FunctionName].self, await client.management("\(ref)/functions", pat: pat))
            let history = try await Self.history(client, ref: ref, pat: pat)
            let footprint = try await Self.footprint(client, ref: ref, pat: pat)
            try Self.validate(history: history, footprint: footprint, installationID: checkpoint?.connectionID)
            let installed = secrets.contains { $0.name.hasPrefix("TINCALL_") } || functions.contains { $0.slug == "tincall" }
                || !history.filter { Self.versions.contains($0.version) }.isEmpty || footprint.hasInstallation
            guard checkpoint != nil || !installed else {
                throw TincallError(message: String(localized: "项目已有 Tincall 安装，但本机没有原部署凭据。已停止，不能覆盖旧手机令牌或数据。"))
            }
            if checkpoint != nil {
                for completed in [CloudDeploymentStep.project, .inspection, .tokens] {
                    update(completed, status: .completed, skipped: true)
                }
                for completed in checkpoint!.completed {
                    update(completed, status: .completed, skipped: true)
                }
            }
            update(step, status: .completed)

            try start(.tokens)
            let reused = checkpoint != nil
            if checkpoint == nil {
                let connectionID = UUID()
                checkpoint = CloudDeploymentCheckpoint(email: requestedOwnerEmail ?? Self.ownerEmail(for: connectionID), connectionID: connectionID,
                                                       phoneToken: try Self.token(), workerToken: try Self.token())
                try save(checkpoint!, ref: ref) // Before the first remote write, so uncertain writes remain recoverable.
            }
            var saved = checkpoint!
            update(step, status: .completed, skipped: reused)
            let endpoint = URL(string: "https://\(ref).supabase.co/functions/v1/tincall")!
            let profile = ConnectionProfile(id: saved.connectionID, name: String(localized: "Tincall 云端"), provider: .genericConnector, endpoint: endpoint)
            if allowDataSharing { DataSharingConsent.setAllowed(true, for: profile) }
            var currentHistory = history
            for migration in Self.migrations {
                // Attribute a failed remote check to the migration being checked, while
                // keeping already completed rows visually complete during a retry.
                step = migration.step
                try Task.checkCancellation()
                // Inspection has already validated remote history and footprint for this attempt.
                // Refresh them after each write; local completed flags never decide SQL execution.
                let exists = currentHistory.contains { $0.version == migration.version }
                if exists {
                    saved.completed.insert(migration.step)
                    try save(saved, ref: ref)
                    update(migration.step, status: .completed, skipped: true)
                    continue
                }
                try start(migration.step)
                let sql = String(decoding: try resources.read(migration.path), as: UTF8.self)
                _ = try await client.query(ref: ref, pat: pat, sql: Self.transaction(migration, sql: sql, installationID: saved.connectionID))
                let confirmed = try await Self.history(client, ref: ref, pat: pat)
                let confirmedFootprint = try await Self.footprint(client, ref: ref, pat: pat)
                try Self.validate(history: confirmed, footprint: confirmedFootprint, installationID: saved.connectionID)
                guard confirmed.contains(where: { $0.version == migration.version }) else {
                    throw TincallError(message: String(localized: "迁移请求已返回，但未查到对应版本，已停止后续部署。"))
                }
                currentHistory = confirmed
                saved.completed.insert(migration.step); try save(saved, ref: ref)
                update(migration.step, status: .completed)
            }

            if saved.completed.contains(.connection) {
                // Completed installations no longer retain the worker token. Upgrade SQL
                // and function source without rewriting secrets, Vault or owner bindings.
                for next in [CloudDeploymentStep.secrets, .vault, .owner, .binding] {
                    update(next, status: .completed, skipped: true)
                }
                try start(.function)
                try await client.deployFunction(ref: ref, pat: pat, resources: resources)
                saved.completed.insert(step); try save(saved, ref: ref); update(step, status: .completed)
                try start(.push)
                let skipped = try await configureOfficialPush(client, ref: ref, pat: pat, saved: &saved, secretNames: Set(secrets.map(\.name)))
                update(.push, status: .completed, skipped: skipped)
                try start(.connection)
                try await onConnect(profile, saved.phoneToken)
                update(step, status: .completed)
                return profile
            }
            guard let worker = saved.workerToken else { throw TincallError(message: String(localized: "本次安装的 worker 续跑凭据缺失，已停止覆盖。")) }

            if saved.completed.contains(.secrets) {
                update(.secrets, status: .completed, skipped: true)
            } else {
                try start(.secrets)
                // Owner creation comes later in the prescribed order. A fresh deployment initially
                // accepts no phone tokens; bind the real auth.users UUID after Auth Admin succeeds.
                try await Self.writeSecrets(client, ref: ref, pat: pat, checkpoint: saved, worker: worker, initial: true)
                saved.completed.insert(.secrets); try save(saved, ref: ref); update(.secrets, status: .completed)
            }

            // A retry may come from a newer App containing a function fix. Upload its current
            // source even if the previous attempt reached the connection check.
            try start(.function)
            try await client.deployFunction(ref: ref, pat: pat, resources: resources)
            saved.completed.insert(.function); try save(saved, ref: ref); update(.function, status: .completed)

            if saved.completed.contains(.vault) {
                update(.vault, status: .completed, skipped: true)
            } else {
                try start(.vault)
                // Fill Vault only after deployment. No secret values are read back or logged.
                for (name, value) in [("tincall_function_base", endpoint.absoluteString), ("tincall_worker_token", worker)] {
                    struct SecretID: Decodable { let id: UUID }
                    let existing = try SupabaseManagementClient.decode([SecretID].self, await client.query(ref: ref, pat: pat,
                        sql: "select id from vault.secrets where name=$1::text;", parameters: [name], readOnly: true))
                    guard existing.count <= 1 else { throw Self.conflict() }
                    if let secret = existing.first {
                        _ = try await client.query(ref: ref, pat: pat, sql: "select vault.update_secret($1::uuid,$2::text);",
                                                   parameters: [secret.id.uuidString, value])
                    } else {
                        _ = try await client.query(ref: ref, pat: pat, sql: "select vault.create_secret($1::text,$2::text,$3::text);",
                                                   parameters: [value, name, "Tincall deployment"])
                    }
                }
                saved.completed.insert(.vault); try save(saved, ref: ref); update(.vault, status: .completed)
            }

            struct Key: Decodable { let name: String?; let type: String?; let api_key: String? }
            let owner: UUID
            if saved.completed.contains(.owner), let savedOwner = saved.ownerID {
                owner = savedOwner
                update(.owner, status: .completed, skipped: true)
            } else {
                try start(.owner)
                // This block is the ONLY lifetime of revealed service keys; never put them in recovery.
                owner = try await {
                    let keys = try SupabaseManagementClient.decode([Key].self, await client.management("\(ref)/api-keys?reveal=true", pat: pat))
                    guard let key = keys.first(where: { $0.name == "service_role" && !($0.api_key ?? "").isEmpty })?.api_key
                        ?? keys.first(where: { $0.type == "secret" && $0.api_key?.hasPrefix("sb_secret_") == true })?.api_key else {
                        throw TincallError(message: String(localized: "无法取得可用的项目服务密钥，请检查 API Keys 与 API Key Secrets 读取权限；不会自动创建或启用密钥。"))
                    }
                    struct Owner: Decodable { let id: UUID }
                    // The generated owner identifier also recovers a createUser whose response was lost.
                    let ownerEmail = saved.email
                    let users = try SupabaseManagementClient.decode([Owner].self, await client.query(ref: ref, pat: pat,
                        sql: "select id from auth.users where lower(email) = $1::text;", parameters: [ownerEmail], readOnly: true))
                    guard users.count <= 1 else { throw TincallError(message: String(localized: "云端数据归属存在多个用户，无法安全继续部署。")) }
                    if let user = users.first {
                        guard saved.ownerID == nil || saved.ownerID == user.id else { throw TincallError(message: String(localized: "Auth owner 与上次部署不一致，已停止覆盖。")) }
                        return user.id
                    }
                    guard saved.ownerID == nil else { throw TincallError(message: String(localized: "原 Auth owner 已不存在，已停止；不会新建用户替换原数据归属。")) }
                    return try await client.createOwner(ref: ref, key: key, email: ownerEmail)
                }()
                saved.ownerID = owner; saved.completed.insert(.owner); try save(saved, ref: ref); update(.owner, status: .completed)
            }

            if saved.completed.contains(.binding) {
                update(.binding, status: .completed, skipped: true)
            } else {
                try start(.binding)
                try await Self.writeSecrets(client, ref: ref, pat: pat, checkpoint: saved, worker: worker, initial: false)
                saved.completed.insert(.binding); try save(saved, ref: ref); update(.binding, status: .completed)
            }

            try start(.push)
            let skipped = try await configureOfficialPush(client, ref: ref, pat: pat, saved: &saved, secretNames: Set(secrets.map(\.name)))
            update(.push, status: .completed, skipped: skipped)
            try start(.connection)
            try await onConnect(profile, saved.phoneToken)
            // Remove the installation-only worker copy only AFTER the existing save callback succeeds.
            saved.completed.insert(.connection); saved.workerToken = nil; try save(saved, ref: ref)
            update(.connection, status: .completed)
            return profile
        } catch {
            let reason: String
            if error is CancellationError { reason = String(localized: "部署已取消，已完成资源保留；可重新输入 PAT 继续。") }
            else if let safe = error as? TincallError { reason = safe.message }
            else if let failure = error as? ExternalCallFailure {
                if failure.status == 401 || failure.status == 403 {
                    reason = String(localized: "手机令牌尚未通过检查，请稍后重试部署。")
                } else {
                    let code = failure.code.isEmpty ? "" : " · \(failure.code)"
                    reason = String(localized: "连接能力检查失败（HTTP \(failure.status)\(code)），请检查部署函数和手机令牌。")
                }
            } else { reason = String(localized: "当前步骤未完成，已停止。已完成资源和本机续跑凭据保留，请重试。") }
            update(step, status: .failed, reason: reason)
            throw TincallError(message: reason)
        }
    }

    private func configureOfficialPush(_ client: SupabaseManagementClient, ref: String, pat: String,
                                       saved: inout CloudDeploymentCheckpoint, secretNames: Set<String>) async throws -> Bool {
        #if TINCALL_APP_STORE
        let names: Set<String> = ["TINCALL_PUSH_URL", "TINCALL_PUSH_TOKEN"]
        if let pushToken = saved.pushToken, names.isSubset(of: secretNames) {
            // A previous attempt may have written the official names before its response was lost.
            // Verify that they still contain our pending credential before retrying registration;
            // never overwrite a sender configured while the retry was pending.
            guard try await client.verifyConfiguredOfficialPush(ref: ref, token: pushToken) else {
                throw TincallError(message: String(localized: "检测到已有推送配置，未覆盖原配置；请保留现有发送端，或移除后再重试官方推送开通。"))
            }
            try await client.registerOfficialPush(token: pushToken)
            saved.pushToken = nil
            saved.completed.insert(.push)
            try save(saved, ref: ref)
            return false
        }
        if saved.pushToken == nil {
            // Keep existing official or custom senders; never rotate a user's working credential.
            if names.isSubset(of: secretNames) { return true }
            guard names.isDisjoint(with: secretNames) else {
                throw TincallError(message: String(localized: "已有推送配置不完整，请先补齐或移除原配置，再重试部署；原配置未被覆盖。"))
            }
            saved.pushToken = "tcpush_\(ref)_\(try Self.token())"
            try save(saved, ref: ref)
        } else if !names.isDisjoint(with: secretNames) {
            throw TincallError(message: String(localized: "已有推送配置不完整，请先补齐或移除原配置，再重试部署；原配置未被覆盖。"))
        }
        guard let pushToken = saved.pushToken else { return true }
        _ = try await client.management("\(ref)/secrets", pat: pat, body: [
            ["name": "TINCALL_PUSH_URL", "value": SupabaseManagementClient.officialPushURL.absoluteString],
            ["name": "TINCALL_PUSH_TOKEN", "value": pushToken]
        ])
        try await client.registerOfficialPush(token: pushToken)
        saved.pushToken = nil
        saved.completed.insert(.push)
        try save(saved, ref: ref)
        return false
        #else
        return true
        #endif
    }

    private func save(_ checkpoint: CloudDeploymentCheckpoint, ref: String) throws {
        try credentials.writeCloudDeployment(JSONEncoder().encode(checkpoint), projectRef: ref)
    }
    private func update(_ step: CloudDeploymentStep, status: CloudDeploymentProgress.Status, skipped: Bool = false, reason: String? = nil) {
        guard let index = progress.firstIndex(where: { $0.step == step }) else { return }
        progress[index].status = status; progress[index].skipped = skipped; progress[index].reason = reason
    }
    private static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw TincallError(message: String(localized: "无法生成安全随机令牌，尚未开始写入云端。"))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func ownerEmail(for connectionID: UUID) -> String {
        "owner-\(connectionID.uuidString.lowercased())@tincall.invalid"
    }

    private struct Migration {
        let version: String; let name: String; let step: CloudDeploymentStep
        var path: String { "supabase/migrations/\(version)_\(name).sql" }
    }
    private static let migrations = [Migration(version: "202610110001", name: "tincall_connector", step: .connector),
                                     Migration(version: "202610110002", name: "tincall_cron", step: .cron),
                                     Migration(version: "202610140001", name: "tincall_mcp_roles", step: .roles),
                                     Migration(version: "202610160001", name: "tincall_voice_instructions", step: .voiceInstructions),
                                     Migration(version: "202610180001", name: "tincall_recent_calls", step: .recentCalls),
                                     Migration(version: "202610190001", name: "tincall_mcp_sse", step: .sse),
                                     Migration(version: "202610190002", name: "tincall_mcp_tools", step: .mcpTools),
                                     Migration(version: "202610200001", name: "tincall_schedule_controls", step: .schedules),
                                     Migration(version: "202610200002", name: "tincall_incoming_events", step: .incomingEvents),
                                     Migration(version: "202610200003", name: "tincall_mcp_oauth", step: .oauth),
                                     Migration(version: "202610200004", name: "tincall_call_presence", step: .callPresence),
                                     Migration(version: "202610200005", name: "tincall_contact_mode", step: .contactMode),
                                     Migration(version: "202610200006", name: "tincall_wake_bridge", step: .wakeBridge),
                                     Migration(version: "202610210001", name: "tincall_mcp_voice_ack", step: .mcpVoiceAck),
                                     Migration(version: "202610210002", name: "tincall_mcp_conversation", step: .mcpConversation),
                                     Migration(version: "202610210003", name: "tincall_message_images", step: .messageImages),
                                     Migration(version: "202610220001", name: "tincall_service_safety", step: .serviceSafety),
                                     Migration(version: "202610220002", name: "tincall_mcp_safety", step: .callContext),
                                     Migration(version: "202610250001", name: "tincall_mcp_wait_preferences", step: .mcpWaitPreferences),
                                     Migration(version: "202610270001", name: "tincall_hot_path_indexes", step: .hotPathIndexes)]
    private static let versions = Set(migrations.map(\.version))
    private struct History: Decodable { let version: String; let name: String? }
    private static func history(_ client: SupabaseManagementClient, ref: String, pat: String) async throws -> [History] {
        try SupabaseManagementClient.decode([History].self, await client.management("\(ref)/database/migrations", pat: pat))
    }

    private struct Footprint: Decodable {
        let tables: [String]; let functions: [String]; let policies: [String]
        let bucket: Bool; let private_bucket: Bool; let insecure_tables: Bool; let exposed_tables: Bool; let has_images: Bool
        let has_cron: Bool; let has_vault: Bool; let installation: String?
        var cronJobs: [String] = []; var vaultNames: [String] = []
        enum CodingKeys: String, CodingKey { case tables, functions, policies, bucket, private_bucket, insecure_tables, exposed_tables, has_images, has_cron, has_vault, installation }
        var hasInstallation: Bool { !tables.isEmpty || !functions.isEmpty || !policies.isEmpty || bucket || !cronJobs.isEmpty || !vaultNames.isEmpty }
    }
    private static func footprint(_ client: SupabaseManagementClient, ref: String, pat: String) async throws -> Footprint {
        let rows = try SupabaseManagementClient.decode([Footprint].self, await client.query(ref: ref, pat: pat, sql: footprintSQL, readOnly: true))
        guard rows.count == 1, var result = rows.first else { throw TincallError(message: String(localized: "无法识别项目中的安装状态。")) }
        struct Name: Decodable { let name: String }
        if result.has_cron {
            result.cronJobs = try SupabaseManagementClient.decode([Name].self, await client.query(ref: ref, pat: pat,
                sql: "select jobname as name from cron.job where jobname = 'tincall-worker';", readOnly: true)).map(\.name)
        }
        if result.has_vault {
            result.vaultNames = try SupabaseManagementClient.decode([Name].self, await client.query(ref: ref, pat: pat,
                sql: "select name from vault.secrets where name in ('tincall_function_base','tincall_worker_token');", readOnly: true)).map(\.name)
        }
        return result
    }
    private static let connectorTables: Set<String> = ["tincall_owners", "tincall_calls", "tincall_messages", "tincall_events", "tincall_requests", "tincall_jobs", "tincall_devices", "tincall_schedules", "tincall_push_jobs", "tincall_records"]
    private static let connectorFunctions: Set<String> = ["tincall_emit", "tincall_stop_reply", "tincall_next_daily", "tincall_command", "tincall_worker_owners"]
    private static let roleFunctions: Set<String> = ["tincall_mcp_role", "tincall_mcp_authenticate"]
    private static let voiceInstructionFunctions: Set<String> = ["tincall_set_voice_prompt", "tincall_claim_voice_instructions"]
    private static let mediaPolicies: Set<String> = ["tincall_media_read", "tincall_media_insert", "tincall_media_update", "tincall_media_delete"]
    private static func validate(history: [History], footprint: Footprint, installationID: UUID?) throws {
        let applied = Set(history.map(\.version))
        if applied.contains(migrations[0].version), let installationID {
            guard footprint.installation == "Tincall mobile installation \(installationID.uuidString.lowercased())" else { throw conflict() }
        }
        var gap = false
        for migration in migrations {
            if applied.contains(migration.version) {
                guard !gap, history.filter({ $0.version == migration.version }).count == 1,
                      history.first(where: { $0.version == migration.version })?.name.map({ $0 == migration.name }) ?? true else { throw conflict() }
            } else { gap = true }
        }
        // This is a first-install service, not a general migration reconciler. Unknown
        // versions (even from another app) require review rather than inserting old versions
        // into a newer remote history and claiming CLI compatibility.
        guard applied.isSubset(of: versions) else { throw conflict() }
        // The previous documented manual SQL had no migration-history row. Recognize
        // its column/function pair, then apply the canonical migration without losing data.
        let images = applied.contains("202610210003") || (applied.contains(migrations[0].version) && footprint.has_images)
        let expectedTables = (applied.contains(migrations[0].version) ? connectorTables : []).union(applied.contains(migrations[2].version) ? ["tincall_mcp_roles"] : []).union(applied.contains(migrations[5].version) ? ["tincall_mcp_sse"] : []).union(applied.contains(migrations[9].version) ? ["tincall_oauth_clients", "tincall_oauth_requests", "tincall_oauth_grants"] : []).union(applied.contains(migrations[12].version) ? ["tincall_wake_bridges"] : [])
        let expectedFunctions = (applied.contains(migrations[0].version) ? connectorFunctions : []).union(applied.contains(migrations[2].version) ? roleFunctions : []).union(applied.contains(migrations[3].version) ? voiceInstructionFunctions : []).union(applied.contains(migrations[4].version) ? ["tincall_recent_calls"] : []).union(applied.contains(migrations[5].version) ? ["tincall_mcp_sse_command"] : []).union(applied.contains(migrations[6].version) ? ["tincall_mcp"] : []).union(applied.contains(migrations[7].version) ? ["tincall_schedule_command", "tincall_schedule_next"] : []).union(applied.contains(migrations[8].version) ? ["tincall_broadcast_incoming"] : []).union(applied.contains(migrations[9].version) ? ["tincall_oauth"] : []).union(applied.contains(migrations[10].version) ? ["tincall_call_presence"] : []).union(applied.contains(migrations[11].version) ? ["tincall_contact_mode"] : []).union(applied.contains(migrations[12].version) ? ["tincall_wake_bridge", "tincall_broadcast_wake"] : [])
        guard Set(footprint.tables) == expectedTables,
              Set(footprint.functions) == expectedFunctions.union(images ? ["tincall_image_command"] : []).union(applied.contains("202610220001") ? ["tincall_remove_push_device"] : []).union(applied.contains("202610220002") ? ["tincall_resolve_call_context"] : []),
              footprint.has_images == images,
              Set(footprint.policies) == (applied.contains(migrations[0].version) && !applied.contains("202610220001") ? mediaPolicies : []),
              footprint.bucket == applied.contains(migrations[0].version), !footprint.bucket || footprint.private_bucket,
              !footprint.insecure_tables,
              !applied.contains("202610220001") || !footprint.exposed_tables,
              footprint.cronJobs.count == (applied.contains(migrations[1].version) ? 1 : 0),
              !applied.contains(migrations[1].version) || footprint.has_vault else { throw conflict() }
    }
    private static func conflict() -> TincallError { TincallError(message: String(localized: "迁移版本或实际表、函数、RLS、存储桶、定时任务不一致，已停止；请先核对原安装，不会清除数据。")) }

    private static func transaction(_ migration: Migration, sql: String, installationID: UUID) -> String {
        let guardSQL: String
        switch migration.step {
        case .connector:
            guardSQL = "if exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname like 'tincall\\_%' escape '\\') then raise exception 'tincall_install_conflict'; end if;"
        case .cron:
            guardSQL = "if to_regclass('cron.job') is not null then if exists(select 1 from cron.job where jobname='tincall-worker') then raise exception 'tincall_install_conflict'; end if; end if;"
        case .voiceInstructions:
            guardSQL = "if to_regclass('public.tincall_calls') is null or exists(select 1 from information_schema.columns where table_schema='public' and table_name='tincall_calls' and column_name in ('tts_expression_prompt','voice_instructions_sent')) then raise exception 'tincall_install_conflict'; end if;"
        case .recentCalls:
            guardSQL = "if to_regclass('public.tincall_calls') is null or exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='tincall_recent_calls') then raise exception 'tincall_install_conflict'; end if;"
        case .mcpConversation:
            guardSQL = "if to_regclass('public.tincall_calls') is null or exists(select 1 from information_schema.columns where table_schema='public' and table_name='tincall_calls' and column_name in ('user_name','mcp_read_sequence','mcp_read_epoch','mcp_dial_until')) then raise exception 'tincall_install_conflict'; end if;"
        case .mcpVoiceAck:
            guardSQL = "if to_regprocedure('public.tincall_mcp(text,uuid,text,jsonb)') is null then raise exception 'tincall_install_conflict'; end if;"
        case .serviceSafety:
            guardSQL = "if to_regprocedure('public.tincall_oauth(text,jsonb)') is null or to_regclass('public.tincall_devices') is null then raise exception 'tincall_install_conflict'; end if;"
        case .callContext:
            guardSQL = "if to_regprocedure('public.tincall_mcp(text,uuid,text,jsonb)') is null then raise exception 'tincall_install_conflict'; end if;"
        case .hotPathIndexes:
            guardSQL = "if to_regclass('public.tincall_messages') is null or to_regclass('public.tincall_jobs') is null or to_regclass('public.tincall_push_jobs') is null or to_regclass('public.tincall_requests') is null then raise exception 'tincall_install_conflict'; end if;"
        case .mcpWaitPreferences:
            guardSQL = "if to_regclass('public.tincall_mcp_roles') is null or exists(select 1 from information_schema.columns where table_schema='public' and table_name='tincall_mcp_roles' and column_name='mcp_wait_timeout_seconds') then raise exception 'tincall_install_conflict'; end if;"
        case .messageImages:
            guardSQL = "if to_regclass('public.tincall_messages') is null or exists(select 1 from information_schema.columns where table_schema='public' and table_name='tincall_messages' and column_name='images' and udt_name<>'jsonb') then raise exception 'tincall_install_conflict'; end if;"
        case .mcpTools:
            guardSQL = "if to_regclass('public.tincall_messages') is null or exists(select 1 from information_schema.columns where table_schema='public' and table_name='tincall_messages' and column_name='reply_touched_at') then raise exception 'tincall_install_conflict'; end if;"
        case .schedules:
            guardSQL = "if to_regclass('public.tincall_schedules') is null or exists(select 1 from information_schema.columns where table_schema='public' and table_name='tincall_schedules' and column_name='week_day') or exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('tincall_schedule_command','tincall_schedule_next')) then raise exception 'tincall_install_conflict'; end if;"
        case .callPresence:
            guardSQL = "if to_regclass('public.tincall_calls') is null or exists(select 1 from information_schema.columns where table_schema='public' and table_name='tincall_calls' and column_name='phone_seen_at') or exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='tincall_call_presence') then raise exception 'tincall_install_conflict'; end if;"
        case .wakeBridge:
            guardSQL = "if to_regclass('public.tincall_mcp_roles') is null or to_regclass('public.tincall_wake_bridges') is not null or exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('tincall_wake_bridge','tincall_broadcast_wake')) then raise exception 'tincall_install_conflict'; end if;"
        case .contactMode:
            guardSQL = "if to_regclass('public.tincall_mcp_roles') is null or exists(select 1 from information_schema.columns where table_schema='public' and table_name='tincall_mcp_roles' and column_name='call_mode') or exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='tincall_contact_mode') then raise exception 'tincall_install_conflict'; end if;"
        case .oauth:
            guardSQL = "if to_regclass('public.tincall_mcp_roles') is null or to_regclass('public.tincall_oauth_clients') is not null or to_regclass('public.tincall_oauth_requests') is not null or to_regclass('public.tincall_oauth_grants') is not null or exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='tincall_oauth') then raise exception 'tincall_install_conflict'; end if;"
        case .incomingEvents:
            guardSQL = "if to_regclass('public.tincall_calls') is null or exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='tincall_broadcast_incoming') then raise exception 'tincall_install_conflict'; end if;"
        case .sse:
            guardSQL = "if to_regclass('public.tincall_calls') is null or to_regclass('public.tincall_mcp_sse') is not null then raise exception 'tincall_install_conflict'; end if;"
        default:
            guardSQL = "if to_regclass('public.tincall_mcp_roles') is not null then raise exception 'tincall_install_conflict'; end if;"
        }
        // Management API does NOT document implicit atomicity or caller-supplied versions.
        // Avoid POST /migrations' unspecified generated version: send one explicit transaction
        // per original file, including CLI-compatible version history, guarded under a fixed
        // advisory lock. No rollback API assumption, no automatic resend after uncertainty.
        // Real-project rollback, query API multi-statement/transaction semantics and CLI db push
        // interoperation remain unverified. If the API rejects this, stop; never split the batch.
        let installation = "Tincall mobile installation \(installationID.uuidString.lowercased())"
        // A table comment claims this fresh installation without a new business table. Recheck
        // under the same lock: two phones that both inspected an empty project cannot rotate
        // each other's tokens after racing to apply the first migration.
        let claim = migration.step == .connector
            ? "comment on table public.tincall_owners is '\(installation)';" : ""
        return """
        begin;
        set local lock_timeout = '10s';
        set local statement_timeout = '60s';
        select pg_advisory_xact_lock(202610110001);
        create schema if not exists supabase_migrations;
        create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);
        do $tincall_install$
        begin
          if exists(select 1 from supabase_migrations.schema_migrations where version='202610110001')
             and obj_description(to_regclass('public.tincall_owners'),'pg_class') is distinct from '\(installation)' then
            raise exception 'tincall_install_conflict';
          end if;
          if not exists(select 1 from supabase_migrations.schema_migrations where version='\(migration.version)') then
            \(guardSQL)
            execute $tincall_source$\(sql)$tincall_source$;
            \(claim)
            insert into supabase_migrations.schema_migrations(version,name,statements)
              values ('\(migration.version)','\(migration.name)',array[$tincall_source$\(sql)$tincall_source$]::text[]);
          end if;
        end $tincall_install$;
        commit;
        """
    }
    private static let footprintSQL = """
    select array(select c.relname::text from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relkind in ('r','p','v','m','f') and c.relname like 'tincall\\_%' escape '\\') as tables,
    array(select distinct p.proname::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname like 'tincall\\_%' escape '\\') as functions,
    array(select policyname::text from pg_policies where schemaname='storage' and tablename='objects' and policyname like 'tincall\\_%' escape '\\') as policies,
    exists(select 1 from storage.buckets where id='tincall-private') as bucket,
    exists(select 1 from storage.buckets where id='tincall-private' and not public) as private_bucket,
    exists(select 1 from information_schema.columns where table_schema='public' and table_name='tincall_messages'
      and column_name='images' and udt_name='jsonb') as has_images,
    exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public'
      and c.relkind in ('r','p') and c.relname like 'tincall\\_%' escape '\\' and not c.relrowsecurity) as insecure_tables,
    exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public'
      and c.relkind in ('r','p') and c.relname like 'tincall\\_%' escape '\\'
      and (has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
        or has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'))) as exposed_tables,
    to_regclass('cron.job') is not null as has_cron, to_regclass('vault.secrets') is not null as has_vault,
    obj_description(to_regclass('public.tincall_owners'),'pg_class') as installation;
    """
    private static func writeSecrets(_ client: SupabaseManagementClient, ref: String, pat: String,
                                     checkpoint: CloudDeploymentCheckpoint, worker: String, initial: Bool) async throws {
        let clients: [[String: String]] = checkpoint.ownerID.map { [["token": checkpoint.phoneToken, "owner_id": $0.uuidString.lowercased()]] } ?? []
        let value = String(decoding: try JSONSerialization.data(withJSONObject: clients), as: UTF8.self)
        var secrets = [["name": "TINCALL_CLIENTS", "value": value], ["name": "TINCALL_WORKER_TOKEN", "value": worker]]
        if initial && !checkpoint.completed.contains(.secrets) {
            secrets += [["name": "TINCALL_BINDINGS", "value": "[]"], ["name": "TINCALL_ALLOWED_ORIGINS", "value": "[]"]]
        }
        _ = try await client.management("\(ref)/secrets", pat: pat, body: secrets)
    }
}
