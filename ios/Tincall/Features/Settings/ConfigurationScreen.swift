// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

private enum ConfigurationSection: String, CaseIterable, Hashable {
    case modelsAndVoices = "01"
    case connections = "02"
    case appAndData = "03"

    var title: String {
        switch self {
        case .modelsAndVoices: String(localized: "模型与声音")
        case .connections: String(localized: "连接与自动化")
        case .appAndData: String(localized: "应用与数据")
        }
    }
}

private struct ConfigurationSectionPositionKey: PreferenceKey {
    static let defaultValue: [ConfigurationSection: CGFloat] = [:]

    static func reduce(value: inout [ConfigurationSection: CGFloat], nextValue: () -> [ConfigurationSection: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

struct ConfigurationScreen: View {
    @Environment(\.navigationDockClearance) private var dockClearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: LocalConfigurationStore
    var records: CallRecordStore? = nil
    var isCallActive: Bool = false
    var onRequestSummary: ((UUID) -> Void)? = nil
    var canRequestSummary: ((UUID) -> Bool)? = nil
    var isDockPage = false
    var incomingController: IncomingCallController? = nil
    private let credentials = CredentialStore()
    @State private var errorMessage: String?
    var cloudSync: CloudSyncStore? = nil
    var cloudSyncLoadingError: String? = nil
    /// Set by a reminder to open Tincall Cloud directly; cleared when that page closes.
    var opensCloud: Binding<Bool> = .constant(false)
    /// That direct route bypasses the tab root's appearance, so the dock is hidden explicitly.
    var onCloudOpened: () -> Void = {}
    @State private var activeSection: ConfigurationSection = .modelsAndVoices
    @State private var scrollHeight: CGFloat = 0
    @State private var sectionHeaderHeight: CGFloat = 0
    @State private var lastSectionHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .largeTitle) private var titleFontSize = 48.0
    @ScaledMetric(relativeTo: .body) private var profileAvatarSize = 48.0
    #if DEBUG
    @State private var showsLaunchRequestLogs = false
    @State private var didHandleRequestLogLaunch = false
    #endif

    var body: some View {
        Group {
            if isDockPage {
                content
                    .safeAreaBar(edge: .top, spacing: 0) { header }
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .background(Color(.systemBackground))
                    .toolbar(.hidden, for: .navigationBar)
            } else {
                content.navigationTitle("Settings")
            }
        }
        .coordinateSpace(name: "settingsPage")
        .onPreferenceChange(ConfigurationSectionPositionKey.self) { positions in
            guard isDockPage, let headerTop = positions[.modelsAndVoices] else { return }
            activeSection = ConfigurationSection.allCases.last {
                positions[$0].map { $0 <= headerTop + 0.5 } == true
            } ?? .modelsAndVoices
        }
        .navigationDestination(isPresented: opensCloud) { cloudScreen.onAppear(perform: onCloudOpened) }
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        #if DEBUG
        .navigationDestination(isPresented: $showsLaunchRequestLogs) {
            RequestLogScreen()
        }
        .task {
            guard isDockPage, !didHandleRequestLogLaunch else { return }
            didHandleRequestLogLaunch = true
            let arguments = ProcessInfo.processInfo.arguments
            showsLaunchRequestLogs = arguments.contains("-TincallOpenRequestLogs")
                || arguments.contains("-TincallOpenRequestLogFailedCall")
        }
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !isDockPage {
                    profileLink.padding(.vertical, 12)
                    Rectangle().fill(Color.primary).frame(height: 1)
                        .accessibilityHidden(true)
                }
                if !isDockPage {
                    settingsSectionHeader(.modelsAndVoices)
                }
                settingsLink(String(localized: "API设置"), detail: String(localized: "聊天模型 · 摘要模型")) {
                    APISettingsScreen(store: store, isCallActive: isCallActive, onSave: saveConnection)
                }
                settingsLink(String(localized: "文字转语音设置（TTS）"), detail: String(localized: "语音服务 · 声音 · 合成参数")) {
                    connectionSettings(.elevenLabs, title: String(localized: "文字转语音设置（TTS）"))
                }
                scrollingSectionHeader(.connections)
                settingsLink(String(localized: "Tincall 云端"), detail: String(localized: "服务连接 · 通话同步 · 后台与定时来电")) {
                    cloudScreen
                }
                settingsLink(String(localized: "快捷指令"), detail: String(localized: "App 在后台时，也能随时发送文字和截图")) {
                    ShortcutSettingsScreen()
                }
                VStack(spacing: 0) {
                    scrollingSectionHeader(.appAndData)
                    if CallAccessStore.isStoreBuild {
                        settingsLink(String(localized: "试用与解锁"), detail: String(localized: "7 天免费试用 · 一次性买断 · 恢复购买")) {
                            CallAccessScreen()
                        }
                    }
                    settingsLink(String(localized: "显示与字体"), detail: String(localized: "外观 · 语言 · 通话字体")) {
                        AppearanceLanguageSettings()
                    }
                    settingsLink(String(localized: "本机数据与备份"), detail: String(localized: "存储用量 · 录音保存 · 备份文件")) {
                        if let records {
                            GlobalBackupScreen(configuration: store, records: records, isCallActive: isCallActive,
                                               cloudSync: cloudSync, cloudSyncLoadingError: cloudSyncLoadingError)
                        } else {
                            localStorageSettings
                        }
                    }
                    settingsLink(String(localized: "请求日志"), detail: String(localized: "请求详情 · 错误排查 · 日志导出")) {
                        RequestLogScreen()
                    }
                    settingsLink(String(localized: "关于 Tincall"), detail: TincallVersion.version) {
                        AboutTincallScreen()
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { lastSectionHeight = $0 }
            }
            .padding(.horizontal, 24)
        }
        // Allow the final group to reach the fixed section row as well.
        .contentMargins(.bottom, isDockPage
            ? max(dockClearance + 24, scrollHeight + sectionHeaderHeight - lastSectionHeight)
            : dockClearance + 24, for: .scrollContent)
        .onScrollGeometryChange(for: CGFloat.self, of: {
            max(0, $0.containerSize.height - $0.contentInsets.top)
        }) { _, height in
            scrollHeight = height
        }
        .tint(.accentColor)
    }

    private func scrollingSectionHeader(_ section: ConfigurationSection) -> some View {
        settingsSectionHeader(section)
            .opacity(isDockPage && activeSection.rawValue >= section.rawValue ? 0 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: activeSection)
            .accessibilityHidden(isDockPage && activeSection.rawValue >= section.rawValue)
            .background { sectionPosition(section) }
    }

    private func sectionPosition(_ section: ConfigurationSection) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ConfigurationSectionPositionKey.self,
                                   value: [section: geometry.frame(in: .named("settingsPage")).minY])
        }
    }

    private func settingsSectionHeader(_ section: ConfigurationSection) -> some View {
        HStack {
            Text(section.rawValue)
            Spacer()
            Text(section.title)
        }
        .font(.system(size: 9, weight: .regular, design: .monospaced))
        .tracking(1)
        .foregroundStyle(.secondary)
        .padding(.top, 22)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
    }

    private var cloudScreen: some View {
        CloudSyncScreen(configuration: store, sync: cloudSync, records: records,
                        syncLoadingError: cloudSyncLoadingError, isCallActive: isCallActive,
                        incomingController: incomingController, onSaveConnection: saveConnection,
                        onDeleteConnection: deleteConnection)
    }

    private func settingsLink<Destination: View>(_ title: String, detail: String,
                                                  @ViewBuilder destination: () -> Destination) -> some View {
        VStack(spacing: 0) {
            NavigationLink(destination: destination) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(Color.primary.opacity(0.18)).frame(height: 0.75)
                .accessibilityHidden(true)
        }
    }

    private func connectionSettings(_ provider: ConnectionProvider, title: String) -> some View {
        let providers: [ConnectionProvider] = provider == .elevenLabs ? [.elevenLabs, .miniMax, .fishAudio] : [provider]
        return SettingsList {
            ForEach(Array(providers.enumerated()), id: \.element) { offset, service in
                Section {
                    ForEach(store.connections.filter { $0.provider == service }) { connection in
                        NavigationLink {
                            ConnectionEditor(connection: connection, isCallActive: isCallActive,
                                             onDelete: deleteConnection, onSave: saveConnection)
                        } label: {
                            Text(connection.name).foregroundStyle(.primary)
                        }
                        .disabled(isCallActive || ((incomingController?.isEnabled == true || incomingController?.needsDeviceRemoval == true) && incomingController?.connectionIDs.contains(connection.id) == true))
                    }
                    NavigationLink {
                        ConnectionEditor(connection: newConnection(service), isExisting: false, isCallActive: isCallActive,
                                         onDelete: deleteConnection, onSave: saveConnection)
                    } label: {
                        SettingsActionLabel(title: String(localized: "添加\(service.settingsDisplayName)"), symbol: "plus", detail: String(localized: "保存一套可复用的服务预设"))
                    }
                } header: {
                    SettingsSectionHeading(number: providers.count > 1 ? String(format: "%02d", offset + 1) : nil, title: service.settingsDisplayName)
                }
            }
        }
        .modifier(SettingsPageStyle(title: provider == .elevenLabs ? String(localized: "文字转语音") : title,
                                   subtitle: provider == .elevenLabs ? String(localized: "语音服务 · 声音 · 合成参数") : String(localized: "服务地址与访问令牌"),
                                   symbol: provider == .elevenLabs ? "speaker.wave.2" : "link",
                                   index: provider == .elevenLabs ? "TEXT TO SPEECH" : "CONNECTIONS"))
    }

    private func newConnection(_ provider: ConnectionProvider) -> ConnectionProfile {
        var connection = ConnectionProfile(name: provider.displayName, provider: provider)
        if provider == .bailian { connection.model = "paraformer-realtime-v2"; connection.region = "beijing" }
        if provider == .miniMax { connection.model = "speech-02-hd"; connection.region = "china" }
        if provider == .fishAudio { connection.model = "s2.1-pro" }
        if provider == .appleSpeech { connection.language = "zh-CN" }
        return connection
    }

    private var localStorageSettings: some View {
        SettingsList {
            Section {
                LabeledContent("联系人", value: "\(store.roles.count)")
                if let records {
                    LabeledContent("通话记录", value: "\(records.records.count)")
                    LabeledContent("已保存音频", value: String(localized: "\(records.records.reduce(0) { $0 + $1.audioAssets.count }) 段"))
                }
            } header: { SettingsSectionHeading(number: "01", title: String(localized: "本机数据"), caption: "ON THIS IPHONE") }
            Section {
                Toggle("保存录音", isOn: Binding(get: {
                    store.retention.user || store.retention.assistant
                }, set: { enabled in
                    do { try store.saveRetention(AudioRetention(user: enabled, assistant: enabled)) }
                    catch { errorMessage = String(localized: "录音存储设置未保存，请重试。") }
                }))
                if store.retention.user || store.retention.assistant {
                    Toggle("保存我的声音", isOn: retentionBinding(user: true))
                    Toggle("保存对方声音", isOn: retentionBinding(user: false))
                }
            } header: { SettingsSectionHeading(number: "02", title: String(localized: "录音存储"), caption: "AUDIO") } footer: {
                Text("默认关闭。开启后可分别选择两方声音；关闭只停止保存后续录音，已有录音和文字记录会保留。数据保存在本机。")
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .modifier(SettingsPageStyle(title: String(localized: "本机数据与备份"), subtitle: String(localized: "本机记录与录音保存"), symbol: "externaldrive", index: "LOCAL STORAGE"))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TINCALL")
                Spacer()
                Text("PERSONAL DIRECTORY")
            }
            .font(.system(size: 9, weight: .regular, design: .monospaced))
            .tracking(1)
            .foregroundStyle(.secondary)

            HStack(alignment: .center) {
                Text("Settings")
                    .font(.system(size: titleFontSize, weight: .bold))
                    .tracking(-2.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                NavigationLink { ConnectionHelpScreen() } label: {
                    Image(systemName: "questionmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 32, height: 32)
                        .background(Color.primary, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("帮助与指引")
            }
            .padding(.top, 24)
            profileLink
                .padding(.top, 8)
                .padding(.bottom, 8)
            Rectangle().fill(Color.primary).frame(height: 1)
                .accessibilityHidden(true)
            ZStack {
                settingsSectionHeader(activeSection)
                    .id(activeSection)
                    .transition(.opacity)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: activeSection)
            .background { sectionPosition(.modelsAndVoices) }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { sectionHeaderHeight = $0 }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
    }

    private var profileLink: some View {
        HStack(alignment: .center, spacing: 16) {
                CallIdentityPortrait(name: store.userProfile.name, data: store.userProfile.avatarData,
                                     size: profileAvatarSize, coversFrame: false)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.userProfile.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text("我的设置 · 语音识别")
                        .font(.caption2)
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            NavigationLink {
                MyProfileSettings(store: store, isCallActive: isCallActive, onSaveConnection: saveConnection,
                                  onDeleteConnection: deleteConnection)
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .regular))
                    Text("编辑")
                        .font(.caption2)
                }
                .frame(minWidth: 44, minHeight: 44)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 0.75, height: 28)
                        .offset(x: -8)
                        .accessibilityHidden(true)
                }
                .fixedSize()
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑我的设置")
            .accessibilityHint("修改头像、名字和语音识别服务")
        }
        .foregroundStyle(.primary)
        .frame(minHeight: 52)
    }

    private func retentionBinding(user: Bool) -> Binding<Bool> {
        Binding(get: { user ? store.retention.user : store.retention.assistant }, set: { enabled in
            var next = store.retention
            if user { next.user = enabled } else { next.assistant = enabled }
            do { try store.saveRetention(next) } catch { errorMessage = String(localized: "音频保留设置未保存，请重试。") }
        })
    }

    private func deleteConnection(_ id: UUID) throws {
        guard !isCallActive else { throw TincallError(message: String(localized: "请结束通话后再删除连接。")) }
        if store.connections.first(where: { $0.id == id })?.provider == .genericConnector,
           cloudSyncLoadingError != nil {
            throw TincallError(message: String(localized: "云端同步状态未能读取，请重新打开 App 后再删除连接。"))
        }
        if cloudSync?.selectedConnectionID == id {
            guard cloudSync?.isBusy != true, cloudSync?.hasPendingOperation != true else {
                throw TincallError(message: String(localized: "请先完成云端同步及未提交的操作，再删除连接。"))
            }
        }
        try incomingController?.removeConnectionBinding(id)
        try store.deleteConnection(id)
        do {
            if cloudSync?.selectedConnectionID == id { try cloudSync?.select(nil) }
            try credentials.delete(connectionID: id)
            try credentials.delete(connectionID: id, field: .apiSecret)
        } catch {
            throw TincallError(message: String(localized: "连接配置已删除，但关联设置或凭据清理未完成：\(error.localizedDescription)"))
        }
    }

    private func saveConnection(_ connection: ConnectionProfile, _ apiKey: String?, _ apiSecret: String?) throws {
        // Blank fields preserve the existing Keychain values. No credentials enter configuration JSON.
        if connection.provider == .appleSpeech { try store.saveConnection(connection); return }
        let oldKey = try credentials.read(connectionID: connection.id)
        let oldSecret = try credentials.read(connectionID: connection.id, field: .apiSecret)
        do {
            if let apiKey { try credentials.write(apiKey, connectionID: connection.id) }
            if let apiSecret { try credentials.write(apiSecret, connectionID: connection.id, field: .apiSecret) }
            try store.saveConnection(connection)
        } catch {
            do {
                if apiKey != nil { try credentials.write(oldKey ?? "", connectionID: connection.id) }
                if apiSecret != nil { try credentials.write(oldSecret ?? "", connectionID: connection.id, field: .apiSecret) }
            } catch {
                throw TincallError(message: String(localized: "配置未保存，凭据恢复也失败。请重新填写此连接凭据。"))
            }
            throw error
        }
    }
}
