// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

/// A backend identity belongs to this contact, independent of other contacts on the service.
struct BackendContactSettings: View {
    @Binding var role: CallRole
    let connection: ConnectionProfile
    @State private var isLoading = false
    @State private var directory: ExternalContactDirectory?
    @State private var issue: String?
    @State private var requestID: UUID?

    private var selectedBackendContact: ExternalContact? {
        directory?.backendContacts.first { $0.id == role.externalRoleID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPickerRow(title: String(localized: "后端联系人"), value: selectedBackendContact?.displayName ?? String(localized: "请选择"),
                                  selection: Binding(get: { selectedBackendContact?.id }, set: { id in
                    role.externalRoleID = id
                    role.externalRoleName = directory?.backendContacts.first { $0.id == id }?.displayName
                })) {
                    Text("请选择").tag(nil as String?)
                    ForEach(directory?.backendContacts ?? []) { Text($0.displayName).tag(Optional($0.id)) }
                }
                .disabled(isLoading || directory?.backendContacts.isEmpty != false)
            Divider()
            Button { requestID = UUID() } label: {
                HStack(spacing: 16) {
                    SettingsActionLabel(title: directory == nil ? String(localized: "读取后端联系人") : String(localized: "刷新后端联系人"), symbol: "arrow.clockwise")
                    if isLoading { ProgressView().tint(.accentColor) }
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .foregroundStyle(Color.accentColor).buttonStyle(.plain)
            .disabled(isLoading)
            if let issue {
                Text(issue).font(.caption).foregroundStyle(.secondary)
            } else if let directory, let saved = role.externalRoleID, !directory.backendContacts.contains(where: { $0.id == saved }) {
                Text("后端未提供原关联的联系人，请重新选择。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("一键部署的 Supabase 仅负责连接和转发；使用后端模式还需在服务端接入你的聊天后端。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: requestID) {
            await loadContacts()
        }
    }

    @MainActor private func loadContacts() async {
        issue = nil
        isLoading = true
        do {
            let result = try await ExternalCallClient().contactDirectory(connection: connection)
            guard !Task.isCancelled, role.externalConnectionID == connection.id else { return }
            directory = result
            role.externalRoleID = result.selection(preserving: role.externalRoleID)
            if role.externalRoleID == nil { role.externalRoleName = nil }
            if let selected = result.backendContacts.first(where: { $0.id == role.externalRoleID }) {
                role.externalRoleName = selected.displayName
            }
            if result.backendContacts.isEmpty {
                issue = String(localized: "此服务尚未配置聊天后端接口，请先在服务端完成接入。")
            }
            isLoading = false
        } catch {
            guard !Task.isCancelled, role.externalConnectionID == connection.id else { return }
            isLoading = false
            if let failure = error as? ExternalCallFailure, failure.status == 401 || failure.status == 403 {
                issue = String(localized: "无法读取对话对象，请检查手机访问令牌。")
            } else if let failure = error as? TincallError {
                issue = failure.message
            } else {
                issue = String(localized: "暂时无法读取对话对象，请检查服务配置后重试。")
            }
        }
    }
}

struct MCPOAuthAuthorizationSettings: View {
    let connection: ConnectionProfile
    /// Preselected when opened from a contact; the person still confirms it.
    var preferredContactID: String? = nil
    @State private var code = ""
    @State private var request: MCPOAuthAuthorizationRequest?
    @State private var contactID: String?
    @State private var decision: MCPOAuthAuthorizationDecision?
    @State private var isWorking = false
    @State private var issue: String?
    private let client = ExternalCallClient()

    var body: some View {
        SettingsList {
            step("01", title: String(localized: "输入授权码"), caption: "CODE") {
                TextField("XXXX-XXXX", text: Binding(get: { code }, set: { code = Self.formatted($0) }))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.settingsSurface(lightOpacity: 0.055), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75))
                    .disabled(isWorking || request != nil || decision != nil)
                    .accessibilityLabel("一次性授权码")
                    .onChange(of: code) { _, value in
                        if value.count == 9, request == nil, decision == nil, !isWorking { lookup() }
                    }
                Text("填入 ChatGPT 或 Claude 授权网页上显示的 8 位授权码，填满后自动读取。")
                    .font(.footnote).foregroundStyle(.secondary)
                if request == nil, decision == nil {
                    if isWorking { ProgressView().frame(maxWidth: .infinity) }
                    if let issue {
                        Text(issue).font(.footnote).foregroundStyle(.red)
                        primaryButton(String(localized: "重新读取"), symbol: "arrow.clockwise") { lookup() }
                            .disabled(code.count != 9 || isWorking)
                    }
                }
            }
            if let request, decision == nil {
                step("02", title: String(localized: "确认授权"), caption: "REQUEST") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(String(localized: "\(request.client_name) 请求连接"), systemImage: "link")
                            .font(.subheadline.weight(.semibold))
                        if let date = request.requestedAt {
                            HStack(spacing: 4) {
                                Text("请求发起于")
                                Text(date, style: .relative)
                            }
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                        Divider()
                        SettingsPickerRow(title: String(localized: "允许访问的联系人"),
                            value: request.contacts.first { $0.id == contactID }?.display_name ?? String(localized: "请选择"), selection: $contactID) {
                            Text("请选择").tag(nil as String?)
                            ForEach(request.contacts) { Text($0.display_name).tag(Optional($0.id)) }
                        }
                        Text("这个 MCP 客户端可以查看这位联系人的通话文字、发送回复及发起或结束通话。它不能访问其他联系人或云端备份。仅确认你刚刚发起的授权。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if request.contacts.isEmpty {
                            Text("此服务还没有 MCP 联系人，请先在联系人设置中选择 MCP 模式并保存。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(Color.settingsSurface(lightOpacity: 0.055), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75))
                    primaryButton(String(localized: "同意授权"), symbol: "checkmark.shield") { decide(approve: true) }
                        .disabled(contactID == nil || isWorking)
                    Button("拒绝", role: .destructive) { decide(approve: false) }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(isWorking)
                    if isWorking { ProgressView().frame(maxWidth: .infinity) }
                    if let issue { Text(issue).font(.footnote).foregroundStyle(.red) }
                }
            }
            if let decision {
                step("02", title: decision.approved ? String(localized: "授权完成") : String(localized: "已拒绝"), caption: "DONE") {
                    Label(decision.approved ? String(localized: "已授权") : String(localized: "已拒绝此次授权。"),
                          systemImage: decision.approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(decision.approved ? Color.green : Color.secondary)
                    if decision.approved {
                        Text("回到 ChatGPT 或 Claude 里的授权页面，页面会自动继续；没有反应时刷新该页面。")
                            .font(.subheadline)
                        Link("在浏览器中继续", destination: decision.continuation_url)
                            .font(.footnote.weight(.medium))
                        Text("仅适用于在浏览器里发起的授权；在 ChatGPT 或 Claude App 内发起时，直接回到该 App。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Label("只输入你自己刚在浏览器里看到的授权码。别人发给你的码不要输入，也不要替别人批准授权。", systemImage: "exclamationmark.shield")
                    .font(.footnote).foregroundStyle(.orange)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
        .modifier(SettingsPageStyle(title: String(localized: "MCP OAuth 授权"), subtitle: connection.name, symbol: "key", index: "MCP OAUTH", dismissDisabled: isWorking))
    }

    /// Uppercase, keep the code alphabet only, and show it as XXXX-XXXX.
    private static func formatted(_ value: String) -> String {
        let characters = value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8)
        return characters.count > 4 ? String(characters.prefix(4)) + "-" + String(characters.dropFirst(4)) : String(characters)
    }

    private func step<Content: View>(_ number: String, title: String, caption: String, @ViewBuilder content: () -> Content) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } header: {
            SettingsSectionHeading(number: number, title: title, caption: caption)
        }
    }

    private func primaryButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(Color.accentColor)
                .background(Color.settingsSurface(lightOpacity: 0.12), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
    }

    private func lookup() {
        isWorking = true; issue = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let result = try await client.lookupMCPOAuth(connection: connection, code: code)
                request = result
                contactID = result.contacts.contains(where: { $0.id == preferredContactID }) ? preferredContactID
                    : result.contacts.count == 1 ? result.contacts.first?.id : nil
            } catch { issue = authorizationIssue(error) }
        }
    }

    private func decide(approve: Bool) {
        guard let request else { return }
        isWorking = true; issue = nil
        Task { @MainActor in
            defer { isWorking = false }
            do { decision = try await client.decideMCPOAuth(connection: connection, code: request.user_code, contactID: contactID, approve: approve) }
            catch { issue = authorizationIssue(error) }
        }
    }

    private func authorizationIssue(_ error: Error) -> String {
        if let failure = error as? ExternalCallFailure {
            if failure.status == 404 { return String(localized: "云端尚未支持 OAuth，请先用此版本 App 更新一键部署。") }
            if failure.status == 410 { return String(localized: "授权码已失效或已处理，请重新发起 MCP OAuth 连接。") }
            if failure.status == 401 || failure.status == 403 { return String(localized: "无法授权，请检查此连接的手机访问令牌。") }
        }
        return (error as? TincallError)?.message ?? String(localized: "暂时无法处理授权，请检查授权码和连接后重试。")
    }
}

struct ConnectorCurrentCallSettings: View {
    let connection: ConnectionProfile
    let isCallActive: Bool
    @State private var call: ExternalCallState?
    @State private var hasLoaded = false
    @State private var contactName: String?
    @State private var isWorking = false
    @State private var showsEndConfirmation = false
    @State private var pending: ExternalPendingControl?
    @State private var issue: String?
    private let client = ExternalCallClient()

    var body: some View {
        SettingsList {
            Section {
                Text("查看服务端记录的未结束通话。若手机已挂断但仍提示占线，可在这里检查并结束残留通话；这里有记录不代表手机仍在通话。仅在打开此页或点击刷新时查询。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let call {
                    LabeledContent("通话状态", value: call.status == "ringing" ? String(localized: "正在来电") : String(localized: "通话中"))
                    if let contactName { LabeledContent("联系人", value: contactName) }
                    Button("结束这通云端通话", role: .destructive) { showsEndConfirmation = true }
                        .disabled(isWorking || isCallActive)
                } else if hasLoaded {
                    Text("没有进行中的云端通话")
                }
                Button("刷新通话状态") { refresh() }.disabled(isWorking)
                if isWorking { ProgressView() }
                if let issue { Text(issue).font(.footnote).foregroundStyle(.red) }
            } header: {
                SettingsSectionHeading(title: String(localized: "账号线路"), caption: "CURRENT CALL")
            }
        }
        .modifier(SettingsPageStyle(title: String(localized: "检查云端通话状态"), subtitle: connection.name, symbol: "phone", index: "CLOUD CALL", dismissDisabled: isWorking))
        .task { if !hasLoaded { refresh() } }
        .confirmationDialog("结束这通云端通话？", isPresented: $showsEndConfirmation, titleVisibility: .visible) {
            Button("结束通话", role: .destructive) { end() }
        } message: {
            Text("如果其他设备正在使用这通通话，也会被挂断。仅在确认它已不再使用时操作。")
        }
    }

    private func refresh() {
        isWorking = true; issue = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let current = try await client.current(connection: connection)
                if current?.id != call?.id || current?.epoch != call?.epoch { pending = nil }
                call = current; hasLoaded = true
                contactName = nil
                if let current, let directory = try? await client.contactDirectory(connection: connection) {
                    contactName = directory.contacts.first { $0.id == current.contact_id }?.displayName
                }
            } catch { issue = (error as? TincallError)?.message ?? String(localized: "暂时无法读取云端通话，请稍后重试。") }
        }
    }

    private func end() {
        guard let call, !isCallActive else { return }
        let control = pending ?? ExternalPendingControl(requestID: UUID(), epoch: call.epoch, endsCall: true)
        pending = control; isWorking = true; issue = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let state = try await client.control(connection: connection, callID: call.id, pending: control)
                guard state.status == "ended" else { throw TincallError(message: String(localized: "云端尚未确认通话结束。")) }
                self.call = nil; pending = nil
                if let code = state.cancellationCode, code != "cancel_accepted" {
                    issue = String(localized: "通话已结束，但后端尚未确认取消生成，请检查后端取消接口。")
                }
            } catch {
                issue = String(localized: "未能确认通话已结束。可以重试；若通话状态已改变，请先刷新。")
            }
        }
    }
}
