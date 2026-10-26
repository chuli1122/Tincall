// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import Contacts
import ContactsUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

extension RoleEditor {
    var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            connectionModes
                .padding(.top, 8)
                .padding(.bottom, 4)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                Text(modeDescription)
                    .fixedSize(horizontal: false, vertical: true)
            }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if role.effectiveCallMode == .standalone {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("聊天模型")
                        Spacer()
                        Menu {
                            Picker(String(localized: "聊天模型"), selection: $role.modelConnectionID) {
                                Text("请选择预设").tag(nil as UUID?)
                                ForEach(store.connections.filter { $0.provider.isLanguageModel }) {
                                    Text($0.name).tag(Optional($0.id))
                                }
                            }
                        } label: {
                            presetMenuLabel(store.connections.first(where: { $0.id == role.modelConnectionID })?.name ?? String(localized: "请选择预设"))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("聊天模型")
                    }
                    Divider()
                    RoleContextLimitRow(role: $role)
                    if role.summaryConnectionID != nil {
                        Divider()
                        SettingsPickerRow(title: String(localized: "携带摘要条数"), value: role.effectiveHistorySummaryCount == 0 ? String(localized: "0 · 不携带") : String(localized: "\(role.effectiveHistorySummaryCount) 条"), selection: Binding(get: { role.effectiveHistorySummaryCount }, set: { role.historySummaryCount = $0 })) {
                            ForEach(0...5, id: \.self) { count in
                                Text(count == 0 ? String(localized: "0 · 不携带") : String(localized: "\(count) 条")).tag(count)
                            }
                        }
                        Text("聊天时携带这个联系人最近的已完成摘要；0 表示不携带，不影响生成新摘要。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 16)
                promptCard
                NavigationLink {
                    RoleContextSettings(role: $role, connections: store.connections, records: records?.records ?? [],
                                        userName: store.userProfile.name)
                } label: {
                    Label("请求预览", systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if role.effectiveCallMode == .mcp {
                        mcpIntegrationPicker
                        Divider()
                    }
                    SettingsPickerRow(title: role.effectiveCallMode == .mcp ? String(localized: "MCP 连接") : String(localized: "后端连接"),
                                      value: store.connections.first { $0.id == role.externalConnectionID }?.name ?? String(localized: "选择配置"),
                                      selection: Binding(get: { role.externalConnectionID }, set: { id in
                        guard id != role.externalConnectionID else { return }
                        role.externalConnectionID = id
                        role.externalRoleID = nil
                        role.externalRoleName = nil
                        copiedMCPAddress = false
                        copiedMCPAuthorization = false
                        copiedWakeBridgeConfiguration = false
                        mcpSetup.resetConnection()
                        manualMCPContactID = nil
                        errorMessage = nil
                        loadSavedMCPConfiguration()
                    })) {
                        Text("选择配置").tag(nil as UUID?)
                        ForEach(store.connections.filter { $0.provider == .genericConnector }) {
                            Text($0.name).tag(Optional($0.id))
                        }
                    }
                    if !store.connections.contains(where: { $0.provider == .genericConnector }) {
                        Text("请先到设置 → Tincall 云端，部署或连接已有服务。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let connection = store.connections.first(where: { $0.id == role.externalConnectionID && $0.provider == .genericConnector }) {
                        if role.effectiveCallMode == .mcp {
                            mcpIdentityDetails(connection)
                        } else {
                            Divider()
                            BackendContactSettings(role: $role, connection: connection)
                                .id(connection.id)
                        }
                    }
                }
                .padding(.vertical, 16)
            }
        }
    }

    private var mcpIntegrationPicker: some View {
        SettingsPickerRow(title: String(localized: "接入方式"),
                          value: role.mcpWakeBridgeEnabled == true ? String(localized: "MCP＋唤醒桥") : String(localized: "普通 MCP"),
                          selection: Binding(get: { role.mcpWakeBridgeEnabled == true }, set: {
            role.mcpWakeBridgeEnabled = $0
            copiedWakeBridgeConfiguration = false
            copiedMCPAddress = false
            copiedMCPAuthorization = false
        })) {
            Text("普通 MCP").tag(false)
            Text("MCP＋唤醒桥").tag(true)
        }
    }

    private var mcpTransportPicker: some View {
        SettingsPickerRow(title: String(localized: "传输方式"), value: mcpUsesSSE ? "SSE" : "HTTP", selection: $mcpUsesSSE) {
            Text("HTTP（Streamable HTTP）").tag(false)
            Text("SSE").tag(true)
        }
        .onChange(of: mcpUsesSSE) { _, _ in
            copiedMCPAddress = false
            copiedMCPAuthorization = false
            copiedWakeBridgeConfiguration = false
        }
    }

    private var mcpIntegrationLinks: some View {
        HStack(spacing: 18) {
            DeploymentHelpButton(title: "ChatGPT 接入", detail: "1. 复制上面的完整 URL，地址已包含 /mcp，不要重复追加。传输方式选 HTTP。\n\n2. 在 ChatGPT 添加自定义 MCP，身份验证选择 OAuth，使用动态客户端注册。\n\n3. 授权页显示一次性授权码后，到 Tincall 的「设置 → Tincall 云端」打开对应连接的「MCP OAuth 授权」，输入授权码，选择这位联系人并同意。\n\n4. 回到刚才的授权网页完成连接，再返回 ChatGPT 加载工具。", isAccented: true)
            DeploymentHelpButton(title: "Claude 接入", detail: "1. 复制上面的完整 URL，填入 Claude 的 Add custom connector。\n\n2. Authentication 选择 Sign in now，OAuth client 选择 Register automatically，Transport 使用 Streamable HTTP。\n\n3. 授权页显示一次性授权码后，到 Tincall 的「设置 → Tincall 云端」打开对应连接的「MCP OAuth 授权」，输入授权码，选择这位联系人并同意。\n\n4. 回到刚才的授权网页完成连接，再返回 Claude 加载工具。", isAccented: true)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Color.accentColor)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    @ViewBuilder private func mcpIdentityDetails(_ connection: ConnectionProfile) -> some View {
        Divider()
        mcpTransportPicker
        Divider()
        if role.mcpWakeBridgeEnabled == true {
            let configuration = mcpSetup.savedWakeConfiguration(connection: connection, contactID: role.mcpContactID)
            let endpoint = configuration?.mcpEndpoint(usesSSE: mcpUsesSSE)
            mcpCredentialRows(address: endpoint?.url, authorization: endpoint?.headers["Authorization"])
            if let wakeBridgeIssue = mcpSetup.wakeIssue { Text(wakeBridgeIssue).font(.caption).foregroundStyle(.red) }
            Button {
                Task { await copyWakeBridgeConfiguration(connection) }
            } label: {
                HStack {
                    SettingsActionLabel(title: String(localized: "复制唤醒桥配置"),
                                        symbol: copiedWakeBridgeConfiguration ? "checkmark" : "doc.on.doc")
                    if isCopyingWakeBridgeConfiguration || mcpSetup.isLoadingWakeConfiguration { ProgressView() }
                }
            }
            .buttonStyle(.plain)
            .disabled(isCopyingWakeBridgeConfiguration || mcpSetup.isLoadingWakeConfiguration)
            .preference(key: CopySuccessPreferenceKey.self, value: wakeBridgeCopyTrigger)
            .task(id: wakeBridgeCopyTrigger) {
                guard copiedWakeBridgeConfiguration else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                copiedWakeBridgeConfiguration = false
            }
            .onDisappear { copiedWakeBridgeConfiguration = false }
        } else {
            ordinaryMCPIdentityDetails(connection)
        }
        mcpConnectionHelp
    }

    private var mcpConnectionHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("其他支持请求头的平台可直接填写上面的 Authorization。")
            Text("推荐 HTTP，仅支持 SSE 的平台再选 SSE。")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func mcpCredentialRows(address: URL?, authorization: String?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text("URL")
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(address?.absoluteString ?? ((isCopyingWakeBridgeConfiguration || mcpSetup.isLoadingWakeConfiguration) ? String(localized: "正在读取…") : "—"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button {
                        guard let address else { return }
                        UIPasteboard.general.setItems([[UTType.plainText.identifier: address.absoluteString]],
                                                     options: [.expirationDate: Date().addingTimeInterval(300)])
                        copiedMCPAddress = true
                        mcpAddressCopyTrigger = Date()
                    } label: {
                        Image(systemName: copiedMCPAddress ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(.tint)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .disabled(address == nil)
                    .accessibilityLabel(copiedMCPAddress ? String(localized: "已复制 URL") : String(localized: "复制 URL"))
                    .preference(key: CopySuccessPreferenceKey.self, value: mcpAddressCopyTrigger)
                    .task(id: mcpAddressCopyTrigger) {
                        guard copiedMCPAddress else { return }
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        copiedMCPAddress = false
                    }
                    .onDisappear { copiedMCPAddress = false }
                }
            }
            .frame(minHeight: 44)
            Divider()
            HStack(spacing: 16) {
                Text("Authorization")
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(authorization == nil ? "—" : "Bearer ••••••").foregroundStyle(.secondary)
                    Button {
                        guard let authorization else { return }
                        UIPasteboard.general.setItems([[UTType.plainText.identifier: authorization]],
                                                     options: [.expirationDate: Date().addingTimeInterval(300)])
                        copiedMCPAuthorization = true
                        mcpAuthorizationCopyTrigger = Date()
                    } label: {
                        Image(systemName: copiedMCPAuthorization ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(.tint)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .disabled(authorization == nil)
                    .accessibilityLabel(copiedMCPAuthorization ? String(localized: "已复制 Authorization") : String(localized: "复制 Authorization"))
                    .preference(key: CopySuccessPreferenceKey.self, value: mcpAuthorizationCopyTrigger)
                    .task(id: mcpAuthorizationCopyTrigger) {
                        guard copiedMCPAuthorization else { return }
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        copiedMCPAuthorization = false
                    }
                    .onDisappear { copiedMCPAuthorization = false }
                }
            }
            .frame(minHeight: 44)
        }
    }

    private func ordinaryMCPIdentityDetails(_ connection: ConnectionProfile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            mcpWaitTimeoutField
            Divider()
            if isSavingRole {
                ProgressView("正在配置这位联系人…").tint(.accentColor)
            } else if let configuration = mcpSetup.configuration {
                let address = mcpUsesSSE ? configuration.mcp_url.appendingPathComponent("sse") : configuration.mcp_url
                mcpCredentialRows(address: address, authorization: "Bearer \(configuration.token)")
                mcpIntegrationLinks
            } else if mcpSetup.manualDirectory == nil {
                Text("点右上角 ✓ 保存联系人后，可复制 URL 和 Authorization，填入 AI 平台的 MCP 服务设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let directory = mcpSetup.manualDirectory {
                Text("此服务不支持自动配置，需要服务端手动配置联系人及专用令牌。")
                    .font(.caption).foregroundStyle(.secondary)
                if let address = connection.mcpURL {
                    Text(address.absoluteString)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = address.absoluteString
                        copiedMCPAddress = true
                        mcpAddressCopyTrigger = Date()
                    } label: {
                        Label(String(localized: "复制 MCP 地址"),
                              systemImage: copiedMCPAddress ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .preference(key: CopySuccessPreferenceKey.self, value: mcpAddressCopyTrigger)
                    .task(id: mcpAddressCopyTrigger) {
                        guard copiedMCPAddress else { return }
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        copiedMCPAddress = false
                    }
                    .onDisappear { copiedMCPAddress = false }
                }
                if !directory.contacts.isEmpty {
                    SettingsPickerRow(title: String(localized: "已配置的联系人"), value: directory.contacts.first { $0.id == manualMCPContactID }?.displayName ?? String(localized: "请选择"),
                                      selection: $manualMCPContactID) {
                        Text("请选择").tag(nil as String?)
                        ForEach(directory.contacts) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    Button("保存为手动接入", action: saveManualMCPRole)
                        .foregroundStyle(Color.accentColor).buttonStyle(.plain)
                        .disabled(manualMCPContactID == nil || !hasDisplayName || isCallActive)
                }
                Text("按 connector/README.md 配置后，将联系人的 MCP 令牌填入对应 AI 平台，再回到此页保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var mcpWaitTimeoutField: some View {
        HStack(spacing: 6) {
            Text("MCP 等待时长")
            DeploymentHelpButton(title: "MCP 等待时长说明", detail: "AI 回复后，最多等待你下一句话的时间。可填写 1–130 秒，默认 120 秒；超出范围会自动调整。\n\n等待超时不会挂断通话。", systemImage: "info.circle")
            Spacer(minLength: 0)
            TextField("120", value: Binding(
                get: { role.effectiveMCPWaitTimeoutSeconds },
                set: { role.mcpWaitTimeoutSeconds = min(130, max(1, $0)) }
            ), format: .number)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 72)
            .textFieldStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("MCP 等待时长")
            Text("秒").foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
    }

    private var modeDescription: String {
        switch role.effectiveCallMode {
        case .standalone: String(localized: "由 Tincall 直接连接模型。下方「对话设定」会随每次请求发送，可填写对方的设定、你的信息、双方关系和对话要求。留空则不发送这部分内容。")
        case .mcp:
            role.mcpWakeBridgeEnabled == true
                ? String(localized: "适合希望从 Tincall 拨号或说话时自动唤醒 AI 的用户，也支持 AI 主动来电。需按仓库指南运行接入程序，自行配置外部 AI 的启动命令和此处的专用 MCP；也可在支持自动化的平台自行配置。程序自动取齐消息后启动 AI，回复工具立即返回，本轮结束，下一轮再唤醒。普通 MCP 则会在回复后继续等待下一句话。")
                : String(localized: "适合直接在支持 MCP 的 AI 平台中使用。支持 AI 主动来电；AI 调用回复工具后，工具会挂起等待你的下一句话，默认120秒，可根据对应平台客户端超时时间自行调整，超时后不会自动挂断。从 Tincall 拨号不能自动唤醒 AI；需要自动唤醒可选「MCP＋唤醒桥」。")
        case .backend: String(localized: "连接已有的聊天后端，自由管理人物设定、上下文和回复。")
        }
    }

    private var connectionModes: some View {
        HStack(spacing: 32) {
            ForEach(CallMode.allCases, id: \.self) { mode in
                connectionModeButton(mode)
            }
        }
    }

    private func connectionModeButton(_ mode: CallMode) -> some View {
        let isSelected = role.effectiveCallMode == mode
        return Button {
            role.callMode = mode
            if mode == .mcp { loadSavedMCPConfiguration() }
            copiedWakeBridgeConfiguration = false
        } label: {
            Text(modeName(mode))
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .lineLimit(1).minimumScaleFactor(0.85)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(minWidth: 44, minHeight: 44, alignment: .center)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? Color.accentColor : Color.clear)
                        .frame(width: 24, height: 2)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    var canCopyWakeBridgeConfiguration: Bool {
        role.effectiveCallMode == .mcp
            && store.connections.contains { $0.id == role.externalConnectionID && $0.provider == .genericConnector }
    }

    var savedWakeBridgeRole: CallRole? {
        guard store.roles.contains(where: { $0.id == role.id }), savedRole.effectiveCallMode == .mcp,
              savedRole.externalConnectionID == role.externalConnectionID,
              savedRole.mcpContactID == role.mcpContactID else { return nil }
        return savedRole
    }

    var wakeBridgeConfigurationID: String? {
        guard role.effectiveCallMode == .mcp, canCopyWakeBridgeConfiguration,
              let connectionID = role.externalConnectionID else { return nil }
        return connectionID.uuidString + ":" + role.mcpContactID + ":" + (mcpSetup.configuration?.contact_id ?? "")
    }

    @MainActor private func copyWakeBridgeConfiguration(_ connection: ConnectionProfile) async {
        guard !isCopyingWakeBridgeConfiguration, !mcpSetup.isLoadingWakeConfiguration else { return }
        isCopyingWakeBridgeConfiguration = true
        defer { isCopyingWakeBridgeConfiguration = false }
        copiedWakeBridgeConfiguration = false
        errorMessage = nil
        guard canCopyWakeBridgeConfiguration else { return }
        let contactID = role.mcpContactID
        if mcpSetup.savedWakeConfiguration(connection: connection, contactID: contactID) == nil {
            await mcpSetup.loadWakeConfiguration(connection: connection, contactID: contactID, role: savedWakeBridgeRole)
        }
        do {
            guard let configuration = mcpSetup.savedWakeConfiguration(connection: connection, contactID: contactID), editorIsActive,
                  role.effectiveCallMode == .mcp, role.mcpWakeBridgeEnabled == true,
                  role.externalConnectionID == connection.id, role.mcpContactID == contactID else { return }
            try configuration.validate(connection: connection, contactID: contactID)
            UIPasteboard.general.setItems([[UTType.plainText.identifier: try configuration.exportText(mcpUsesSSE: mcpUsesSSE)]],
                                         options: [.expirationDate: Date().addingTimeInterval(600)])
            copiedWakeBridgeConfiguration = true
            wakeBridgeCopyTrigger = Date()
        } catch is CancellationError {
        } catch {
            guard editorIsActive, role.effectiveCallMode == .mcp, role.mcpWakeBridgeEnabled == true,
                  role.externalConnectionID == connection.id, role.mcpContactID == contactID else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func modeName(_ mode: CallMode) -> String {
        switch mode {
        case .standalone: String(localized: "独立模式")
        case .mcp: "MCP"
        case .backend: String(localized: "后端")
        }
    }

    var canReuseMCPConfiguration: Bool {
        mcpSetup.canReuse(role: role, connection: store.connections.first { $0.id == role.externalConnectionID })
    }

    func loadSavedMCPConfiguration() {
        do {
            if let saved = try mcpSetup.loadSaved(role: role, connection: store.connections.first { $0.id == role.externalConnectionID }) {
                role.externalRoleID = saved.contact_id
                role.externalRoleName = saved.display_name
                if savedRole.externalConnectionID == role.externalConnectionID {
                    savedRole.externalRoleID = saved.contact_id
                    savedRole.externalRoleName = saved.display_name
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor func saveMCPRole() async {
        defer { isSavingRole = false }
        do {
            let next = try await mcpSetup.save(role: role, previous: savedRole, store: store)
            guard editorIsActive else { return }
            didSaveRole(next)
            copiedMCPAddress = false
            copiedMCPAuthorization = false
            Task { await store.refreshLinkedContacts() }
        } catch is CancellationError {
            // No local success is published; retrying the same role reuses the server identity.
        } catch {
            guard editorIsActive, !Task.isCancelled else { return }
            if let directory = mcpSetup.manualDirectory {
                manualMCPContactID = directory.contacts.first { $0.id == role.externalRoleID }?.id
            }
            if let failure = error as? ExternalCallFailure {
                switch failure.status {
                case 400:
                    switch failure.code {
                    case "invalid_role":
                        errorMessage = String(localized: "这套 Tincall 云端服务不支持当前 MCP 配置字段，通常是服务版本过旧。请在「设置 → Tincall 云端」检查服务版本并重新部署后，再保存联系人。")
                    case "invalid_json", "invalid_object", "json_required", "body_required":
                        errorMessage = String(localized: "云端没有收到有效的 MCP 配置请求（原因：\(failure.code)）。请检查服务地址和部署版本后重试。")
                    default:
                        let reason = failure.code.isEmpty ? String(localized: "未知原因") : failure.code
                        errorMessage = String(localized: "云端拒绝了这次 MCP 配置（HTTP 400，原因：\(reason)）。请检查服务版本和联系人配置后重试。")
                    }
                case 401, 403: errorMessage = String(localized: "MCP 未配置：请检查这套云端连接的手机访问令牌及管理权限。")
                case 404, 405, 501: errorMessage = String(localized: "服务尚未提供联系人管理接口，需要升级服务或在服务端手动配置。")
                case 409: errorMessage = String(localized: "联系人身份发生冲突，请检查服务端已有绑定后重试。")
                default: errorMessage = String(localized: "MCP 配置失败（HTTP \(failure.status)），草稿已保留，请重试。")
                }
            } else {
                errorMessage = (error as? TincallError)?.message ?? String(localized: "联系人未保存：\(error.localizedDescription)")
            }
        }
    }

    private func saveManualMCPRole() {
        guard !isSavingRole, !isCallActive, let contact = mcpSetup.manualDirectory?.contacts.first(where: { $0.id == manualMCPContactID }) else { return }
        role = roleWithDraftName
        var next = role
        next.externalRoleID = contact.id
        next.externalRoleName = contact.displayName
        do {
            try store.saveRole(next)
            didSaveRole(next)
        } catch { errorMessage = String(localized: "联系人未保存：\(error.localizedDescription)") }
    }
}
