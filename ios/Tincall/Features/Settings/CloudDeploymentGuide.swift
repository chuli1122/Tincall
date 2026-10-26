// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

struct CloudDeploymentGuide<NextSteps: View>: View {
    private let deploymentGuideURL = URL(string: "https://github.com/chuli1122/Tincall/blob/main/connector/README.md")
    let connectExisting: Bool
    let onConnect: (ConnectionProfile, String) async throws -> Void
    let nextSteps: NextSteps
    @Environment(\.dismiss) private var dismiss
    @State private var isConnected = false
    @State private var endpoint = ""
    @State private var token = ""
    @State private var allowsDeploymentSharing = false
    @State private var connection = ConnectionProfile(name: String(localized: "我的 Tincall 云端"), provider: .genericConnector)
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var deployment: SupabaseDeploymentService
    @State private var accessToken = ""
    @State private var deploymentProjectRef = ""
    @State private var deploymentAttempt = 0
    @State private var deploymentRequested = false
    @State private var deploymentFinished = false
    @State private var deploymentError: String?

    init(connectExisting: Bool = false, @ViewBuilder nextSteps: () -> NextSteps,
         onConnect: @escaping (ConnectionProfile, String) async throws -> Void) {
        self.connectExisting = connectExisting
        self.onConnect = onConnect
        self.nextSteps = nextSteps()
        _deployment = State(initialValue: SupabaseDeploymentService(onConnect: onConnect))
    }

    var body: some View {
        SettingsList {
            if isConnected { connectedStep }
            else if connectExisting {
                connectionStep
                ConnectionDataSharingSection(connection: sharingConnection)
            }
            else {
                oneClickDeployment
            }
        }
        .onChange(of: deploymentProjectRef) { _, _ in allowsDeploymentSharing = false }
        .id(isConnected)
        .disabled(isConnecting)
        .modifier(SettingsPageStyle(title: isConnected ? String(localized: "连接已完成") : connectExisting ? String(localized: "连接已有服务") : String(localized: "部署或更新服务"), subtitle: isConnected ? String(localized: "服务已保存，选择要设置的功能") : connectExisting ? String(localized: "用于接入通过电脑或服务器手动部署的 Tincall 服务") : String(localized: "首次部署或更新已有服务，完成后自动保存连接"), symbol: "cloud", index: "CLOUD SETUP", dismissDisabled: isConnecting, sectionSpacing: isConnected || connectExisting ? 18 : 10))
        .modifier(DeploymentHelpOverlay())
        .task(id: deploymentAttempt) {
            guard deploymentAttempt > 0, deploymentRequested else { return }
            defer { deploymentRequested = false }
            do {
                guard allowsDeploymentSharing else { throw TincallError(message: String(localized: "请先确认接收方并允许数据发送。")) }
                guard let projectRef = normalizedProjectRef else {
                    throw TincallError(message: String(localized: "请粘贴有效的 Supabase Project URL 或项目编号。"))
                }
                connection = try await deployment.deploy(pat: accessToken, projectRef: projectRef, allowDataSharing: allowsDeploymentSharing)
                deploymentFinished = true
                accessToken = ""
            } catch {
                // The service supplies credential-safe reasons; never display transport errors.
                deploymentError = (error as? TincallError)?.message ?? String(localized: "部署未完成，请重新部署。")
            }
        }
        .onDisappear { accessToken = "" }
        .alert("连接尚未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var canDeploy: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && normalizedProjectRef != nil
            && allowsDeploymentSharing
            && !deploymentRequested && !deployment.isDeploying && !deploymentFinished
    }

    private var normalizedProjectRef: String? {
        let raw = deploymentProjectRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let url = URL(string: raw), url.scheme?.lowercased() == "https",
           let host = url.host?.lowercased() {
            if host.hasSuffix(".supabase.co") {
                candidate = String(host.dropLast(".supabase.co".count))
            } else if host == "supabase.com" {
                let parts = url.path.split(separator: "/").map(String.init)
                guard let projectIndex = parts.firstIndex(of: "project"),
                      parts.index(after: projectIndex) < parts.endIndex else { return nil }
                candidate = parts[parts.index(after: projectIndex)]
            } else {
                return nil
            }
        } else {
            candidate = raw
        }
        guard (19...20).contains(candidate.count),
              candidate.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }) else { return nil }
        return candidate
    }

    private var oneClickDeployment: some View {
        Group {
            deploymentStep("01", title: "选择项目", caption: "PROJECT") {
                Text("在 Supabase 打开或创建项目。\n更新服务时，请使用此前在这台手机部署的原项目。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    deploymentLink("打开 Supabase", destination: "https://supabase.com/dashboard")
                    Spacer(minLength: 0)
                    DeploymentHelpButton(title: "第一次使用？", heading: "第一次使用 Supabase", detail: "登录 Supabase，选择组织，点击 New project。\n\n填写项目名称、数据库密码和地区，创建后等待项目就绪。数据库密码不要填到 Tincall。")
                }
            }
            deploymentStep("02", title: "填写项目地址", caption: "URL") {
                deploymentInput("Supabase 项目地址") {
                    TextField("https://项目编号.supabase.co", text: $deploymentProjectRef)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .disabled(deploymentRequested || deploymentFinished)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("项目页面 → Copy → Project URL")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    DeploymentHelpButton(title: "复制说明", heading: "复制项目地址", detail: "在 Supabase 控制台打开项目，点击项目网址右侧的 Copy，选择第一项 Project URL，回到这里粘贴。不要复制 API Key。\n\n也可以粘贴浏览器中的 Supabase 项目页面地址，或只填项目编号。")
                }
            }
            deploymentStep("03", title: "创建部署令牌", caption: "ACCESS") {
                deploymentLink("打开令牌页面", destination: "https://supabase.com/dashboard/account/tokens")
                Text("点 Generate new token，按下面选择：")
                    .font(.footnote).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    deploymentOption("范围", value: "Project")
                    deploymentOption("组织", value: "项目所在的组织")
                    deploymentOption("项目", value: "仅选择本次部署的项目")
                    deploymentOption("许可", value: "Full access")
                }
                .font(.footnote)
                .padding(.vertical, 5)
                deploymentInput("部署令牌") {
                    SettingsSecretInput(prompt: String(localized: "生成后立即复制，粘贴到这里"), text: $accessToken)
                }
                .disabled(deploymentRequested || deploymentFinished)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("仅用于部署，完成后可撤销。")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    DeploymentHelpButton(title: "用途与更新", heading: "部署令牌说明", detail: "部署令牌用于授权 Tincall 在选定的 Supabase 项目中创建数据库表、安装或更新云端服务。日常通话和同步不使用这个令牌。\n\n更新时也需填写有效令牌。旧令牌过期或已撤销，请重新创建。部署完成后可撤销，不影响日常通话和同步。")
                }
            }
            deploymentStep("04", title: "部署并保存连接", caption: "DEPLOY") {
                Button {
                    guard canDeploy else { return }
                    deploymentError = nil
                    deploymentRequested = true
                    deploymentAttempt += 1
                } label: {
                    HStack(spacing: 8) {
                        if deploymentRequested { ProgressView() }
                        else { Image(systemName: "icloud.and.arrow.up") }
                        Text(deploymentRequested ? String(localized: "正在部署…") : deploymentAttempt > 0 ? String(localized: "重试部署或更新") : String(localized: "开始部署或更新"))
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .padding(.horizontal, 12)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.settingsSurface(lightOpacity: 0.12), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75))
                    .opacity(canDeploy || deploymentRequested ? 1 : 0.6)
                }
                .buttonStyle(.plain).disabled(!canDeploy)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("完成后自动保存连接。\n更新会保留原有数据和连接令牌。")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    DeploymentHelpButton(title: "接收方与数据用途", detail: "\(deploymentDataSharingDetail)")
                }
                DataSharingAgreementRow(isOn: $allowsDeploymentSharing)
                    .disabled(deploymentRequested || deploymentFinished)
                if deploymentRequested,
                   let current = deployment.progress.first(where: { $0.status == .running }) {
                    Text(LocalizedStringKey(current.step.rawValue))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let deploymentError {
                    Text(deploymentError).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if deploymentFinished {
                    VStack(spacing: 12) {
                        Label("服务已部署或更新，连接已保存", systemImage: "checkmark.circle")
                            .font(.footnote).foregroundStyle(Color.accentColor)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("查看接下来怎么用") { isConnected = true }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(minHeight: 44)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                    .padding(.bottom, 20)
                } else if deploymentAttempt > 0, !deploymentRequested {
                    guidanceNote("修正上方提示后点「重试部署或更新」，会接着上次继续，不会覆盖已有数据。")
                }
            }
        }
    }

    private var deploymentDataSharingDetail: String {
        var detail = String(localized: "Supabase 会接收项目部署配置及必要的账户标识。部署的 Tincall 服务按所启用功能接收通话输入、联系人设定、图片与路由信息；记录和录音同步需另外开启。")
        if let ref = normalizedProjectRef { detail += "\n\nhttps://\(ref).supabase.co" }
        if CallAccessStore.isStoreBuild {
            detail += "\n\n" + String(localized: "部署会同时接入官方来电推送服务，向其提供项目标识和专用推送凭据，不发送聊天或录音。后台来电仍需由你在设置中开启。")
        }
        return detail
    }

    private func deploymentStep<Content: View>(_ number: String, title: LocalizedStringResource, caption: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } header: {
            SettingsSectionHeading(number: number, title: String(localized: title), caption: caption)
        } footer: {
            if number != "04" { VStack(spacing: 0) { Divider() } }
        }
    }

    private func deploymentLink(_ title: LocalizedStringKey, destination: String) -> some View {
        Link(destination: URL(string: destination)!) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.caption)
            }
            .font(.subheadline)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    private func deploymentInput<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.subheadline)
            .accessibilityLabel(title)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(Color.settingsSurface(lightOpacity: 0.055), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75))
    }

    private func deploymentOption(_ title: LocalizedStringKey, value: LocalizedStringKey) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func guidanceNote(_ text: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle").accessibilityHidden(true)
            Text(verbatim: String(localized: text)).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var connectionStep: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("通过 App「部署或更新服务」部署后，连接会自动保存，无需使用本页。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("电脑或服务器的部署步骤见 GitHub 上的 Tincall 仓库 README 中的「部署到自己的电脑或服务器」章节。更新时获取新版源码，并按原部署方式更新。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let deploymentGuideURL {
                    Link("查看 GitHub 部署说明", destination: deploymentGuideURL)
                        .font(.footnote).foregroundStyle(Color.accentColor)
                        .buttonStyle(.borderless)
                }
                Text("在电脑或服务器完成部署后，将得到的服务地址和手机访问令牌填入下方。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 6) {
                SettingsField(title: String(localized: "服务地址")) {
                    TextField("粘贴部署生成的服务地址", text: $endpoint)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                guidanceNote("部署完成后提供的 Tincall 服务网址，需使用手机可访问的 HTTPS 地址。")
            }
            .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 6) {
                SettingsField(title: String(localized: "手机访问令牌")) {
                    SettingsSecretInput(prompt: String(localized: "粘贴部署生成的手机访问令牌"), text: $token)
                }
                guidanceNote("部署时生成，供 Tincall App 连接服务使用，相当于连接密码。")
            }
            .padding(.vertical, 6)
            Button { connect() } label: {
                SettingsActionLabel(title: String(localized: "检查连接"), symbol: "checkmark.icloud")
            }
            .buttonStyle(.plain)
            .disabled(validatedEndpoint == nil || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if isConnecting {
                ProgressView("正在检查连接…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            SettingsSectionHeading(title: String(localized: "服务信息"), caption: "CONNECT")
        } footer: {
            Text("「检查连接」仅验证服务地址和访问令牌，并保存连接。通话记录不会在此步骤同步；如需同步，请到「云端同步」设置。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowSeparator(.hidden)
    }

    private var connectedStep: some View {
        Section {
            Label("连接已保存，服务检查通过", systemImage: "checkmark.circle")
                .foregroundStyle(Color.accentColor)
            Text("点下面的入口继续设置，需要哪项就开启哪项。")
                .font(.caption).foregroundStyle(.secondary)
            nextSteps
            Button("完成，返回 Tincall 云端") { dismiss() }
                .foregroundStyle(Color.accentColor)
        } header: { SettingsSectionHeading(title: String(localized: "选择下一步"), caption: "CONNECTED") }
    }

    private var sharingConnection: ConnectionProfile {
        var value = connection
        value.endpoint = validatedEndpoint
        return value
    }

    private var validatedEndpoint: URL? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    private func connect() {
        guard let url = validatedEndpoint, !isConnecting else { return }
        connection.name = url.host ?? String(localized: "我的 Tincall 云端")
        connection.endpoint = url
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        isConnecting = true
        Task { @MainActor in
            defer { isConnecting = false }
            do {
                try await onConnect(connection, value)
                token = ""
                isConnected = true
            } catch {
                if let failure = error as? ExternalCallFailure {
                    errorMessage = failure.status == 401 || failure.status == 403
                        ? String(localized: "访问令牌未通过检查，请使用该服务提供的手机令牌。")
                        : String(localized: "服务检查未通过（HTTP \(failure.status)），请确认地址已支持 Tincall 协议。")
                } else { errorMessage = error.localizedDescription }
            }
        }
    }

}

struct DeploymentHelpButton: View {
    let title: LocalizedStringResource
    var heading: LocalizedStringResource? = nil
    let detail: LocalizedStringResource
    var systemImage: String? = nil
    var isAccented = false
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.footnote)
                        .frame(width: 32, height: 44, alignment: .leading)
                } else {
                    Text(title)
                        .font(.caption)
                        .underline(true, color: Color.secondary.opacity(0.3))
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minHeight: 44)
                }
            }
            .foregroundStyle(systemImage == nil
                ? (isPresented || isAccented ? Color.accentColor : .secondary)
                : (isPresented ? .secondary : Color.accentColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .anchorPreference(key: DeploymentHelpPreference.self, value: .bounds) { anchor in
            isPresented ? DeploymentHelpPresentation(anchor: anchor, heading: heading, detail: detail,
                                                     dismiss: { isPresented = false }) : nil
        }
    }
}

private struct DeploymentHelpPresentation {
    let anchor: Anchor<CGRect>
    let heading: LocalizedStringResource?
    let detail: LocalizedStringResource
    let dismiss: () -> Void
}

private struct DeploymentHelpPreference: PreferenceKey {
    static var defaultValue: DeploymentHelpPresentation? { nil }

    static func reduce(value: inout DeploymentHelpPresentation?, nextValue: () -> DeploymentHelpPresentation?) {
        value = nextValue() ?? value
    }
}

struct DeploymentHelpOverlay: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(DeploymentHelpPreference.self) { help in
            if let help {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: help.dismiss)
                        .accessibilityHidden(true)
                    DeploymentHelpLayout(anchor: geometry[help.anchor]) {
                        ViewThatFits(in: .vertical) {
                            panelContent(help)
                            ScrollView { panelContent(help) }
                                .scrollBounceBehavior(.basedOnSize)
                        }
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75))
                        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                        .onTapGesture { }
                        .accessibilityAddTraits(.isModal)
                        .accessibilityAction(.escape, help.dismiss)
                    }
                }
            }
        }
    }

    private func panelContent(_ help: DeploymentHelpPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let heading = help.heading {
                HStack(spacing: 12) {
                    Text(heading).font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    closeButton(help.dismiss)
                }
                detailText(help.detail)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    detailText(help.detail)
                    closeButton(help.dismiss)
                }
            }
        }
        .padding(16)
    }

    private func detailText(_ detail: LocalizedStringResource) -> some View {
        Text(detail)
            .font(.footnote).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func closeButton(_ dismiss: @escaping () -> Void) -> some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("收起说明")
    }
}

/// Position in the page viewport, so neither scrolling nor a bottom-edge button clips the panel.
private struct DeploymentHelpLayout: Layout {
    let anchor: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let panel = subviews.first else { return }
        let anchor = anchor.offsetBy(dx: bounds.minX, dy: bounds.minY)
        let viewport = bounds.insetBy(dx: 16, dy: 12)
        let width = max(0, min(292, viewport.width))
        let ideal = panel.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let below = max(0, viewport.maxY - anchor.maxY - 6)
        let above = max(0, anchor.minY - viewport.minY - 6)
        let opensBelow = ideal.height <= below || below >= above
        let height = min(ideal.height, max(0, min(viewport.height, opensBelow ? below : above)))
        let x = max(viewport.minX, min(anchor.maxX - width, viewport.maxX - width))
        let preferredY = opensBelow ? anchor.maxY + 6 : anchor.minY - height - 6
        let y = max(viewport.minY, min(preferredY, viewport.maxY - height))
        panel.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: height))
    }
}
