// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import AVFoundation
import Contacts
import ContactsUI
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

private struct ConnectionEditorSnapshot: Equatable {
    let connection: ConnectionProfile
    let endpoint: String
}

private enum TTSModelCatalog {
    static let customSelection = "__tincall_custom_tts_model__"

    static func models(for provider: ConnectionProvider) -> [String] {
        switch provider {
        case .miniMax:
            return [
                "speech-2.8-hd", "speech-2.8-turbo",
                "speech-2.6-hd", "speech-2.6-turbo",
                "speech-02-hd", "speech-02-turbo",
                "speech-01-hd", "speech-01-turbo"
            ]
        case .elevenLabs:
            return [
                "eleven_v4", "eleven_v4_turbo", "eleven_v3",
                "eleven_v3_conversational", "eleven_multilingual_v2",
                "eleven_flash_v2_5", "eleven_flash_v2"
            ]
        case .fishAudio:
            return ["s2.1-pro", "s2.1-pro-free", "s2-pro"]
        default:
            return []
        }
    }
}

struct ConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State var connection: ConnectionProfile
    @State private var isExisting: Bool
    let isCallActive: Bool
    let isConnectionLocked: Bool
    let onSave: (ConnectionProfile, String?, String?) throws -> Void
    let onDelete: ((UUID) throws -> Void)?
    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var errorMessage: String?
    @State private var didCopyExpression = false
    @State private var expressionCopyTrigger: Date?
    @State private var savedSnapshot: ConnectionEditorSnapshot?
    @State private var actionConfirmed = false
    @State private var actionFeedbackTrigger = 0
    @State private var confirmationToken = UUID()
    @State private var speechTest = SpeechConnectionProbe()
    @State private var speechTestText = ""
    @State private var isCustomTTSModel = false
    @State private var isConfirmingDeletion = false
    @State private var showsAdvancedConfiguration = false

    init(connection: ConnectionProfile, isExisting: Bool = true, isCallActive: Bool = false,
         isConnectionLocked: Bool = false,
         onDelete: ((UUID) throws -> Void)? = nil,
         onSave: @escaping (ConnectionProfile, String?, String?) throws -> Void) {
        _connection = State(initialValue: connection)
        _isExisting = State(initialValue: isExisting)
        let model = connection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        _isCustomTTSModel = State(initialValue: connection.provider.isSpeechSynthesis
            && !TTSModelCatalog.models(for: connection.provider).contains(model))
        self.isCallActive = isCallActive
        self.isConnectionLocked = isConnectionLocked
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var sharingConnection: ConnectionProfile {
        var value = connection
        if [.openAICompatible, .genericConnector, .whisperCompatible].contains(value.provider) {
            value.endpoint = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return value
    }

    private var currentSnapshot: ConnectionEditorSnapshot {
        ConnectionEditorSnapshot(connection: connection, endpoint: endpoint)
    }

    private var hasUnsavedChanges: Bool {
        guard let savedSnapshot else { return false }
        return currentSnapshot != savedSnapshot
            || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !apiSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SettingsList {
            Section {
                if !connection.provider.isSpeechRecognition {
                    SettingsField(title: connection.provider == .genericConnector ? String(localized: "配置名称") : String(localized: "预设名称")) { TextField("为这套连接起个名字", text: $connection.name).accessibilityLabel("名称") }
                        .disabled(isConnectionLocked || isCallActive)
                }
                if connection.provider == .openAICompatible || connection.provider == .genericConnector || connection.provider == .whisperCompatible {
                    SettingsField(title: String(localized: "服务地址")) {
                        TextField(connection.provider == .whisperCompatible ? "https://api.openai.com/v1" : connection.provider == .genericConnector ? String(localized: "连接端 HTTPS 地址") : String(localized: "完整 HTTPS chat/completions 地址"), text: $endpoint)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .disabled(isConnectionLocked || isCallActive)
                    if isConnectionLocked {
                        Text("修改已绑定的连接前，请先在后台来电中停用并完成设备解绑。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if connection.provider == .openAICompatible || connection.provider == .bailian || connection.provider == .whisperCompatible || connection.provider.isSpeechSynthesis {
                    if connection.provider.isSpeechSynthesis {
                        SettingsField(title: String(localized: "合成模型")) {
                            HStack(spacing: 8) {
                                TextField("选择或填写模型名称", text: $connection.model)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                Menu {
                                    ForEach(TTSModelCatalog.models(for: connection.provider), id: \.self) { model in
                                        Button {
                                            connection.model = model
                                            isCustomTTSModel = false
                                        } label: {
                                            if connection.model == model {
                                                Label(model, systemImage: "checkmark")
                                            } else {
                                                Text(model)
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 48, height: 44)
                                        .contentShape(Rectangle())
                                        .padding(.vertical, -11)
                                        .padding(.trailing, -12)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("选择官方模型")
                            }
                        }
                    } else {
                        SettingsField(title: String(localized: "模型标识")) {
                            TextField("填写模型名称", text: $connection.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                }
                if connection.provider == .xunfei {
                    SettingsField(title: String(localized: "讯飞 App ID")) { TextField("填写 App ID", text: $connection.applicationID).textInputAutocapitalization(.never).autocorrectionDisabled() }
                }
                if connection.provider.isSpeechSynthesis {
                    SettingsField(title: connection.provider == .fishAudio ? String(localized: "声音 ID（Reference ID）") : "Voice ID") {
                        TextField("填写声音 ID", text: $connection.voiceID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                if connection.provider == .whisperCompatible {
                    SettingsField(title: String(localized: "识别语言（可选）")) {
                        TextField("自动识别；可填 zh、en", text: Binding(get: { connection.language ?? "" }, set: { connection.language = $0 }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Text("支持兼容的基础地址或完整 audio/transcriptions 地址。每段语音上传到所填服务后返回文字，不在手机内置 Whisper 模型。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("说完一段后上传转写，不显示逐字字幕；语音打断会在转写返回后触发。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if connection.provider == .appleSpeech {
                    SettingsField(title: String(localized: "识别语言")) {
                        TextField("例如：zh-CN", text: Binding(get: { connection.language ?? "zh-CN" }, set: { connection.language = $0 }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Text("语音在本机转写。首次使用会检查并按需下载系统语言模型。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if connection.provider == .miniMax {
                    SettingsPickerRow(title: String(localized: "服务地区"), value: connection.region == "international" ? String(localized: "国际") : String(localized: "中国"), selection: Binding(get: { connection.region ?? "china" }, set: { connection.region = $0 })) {
                        Text("中国").tag("china")
                        Text("国际").tag("international")
                    }
                }
                if connection.provider == .bailian {
                    LabeledContent("服务地区", value: String(localized: "北京"))
                }
                if connection.provider != .appleSpeech {
                    SettingsCredentialField(title: connection.provider == .genericConnector ? String(localized: "手机访问令牌") : connection.provider == .whisperCompatible ? String(localized: "API Key（按服务要求填写）") : "API Key",
                                            connectionID: connection.id, text: $apiKey,
                                            isReadOnly: connection.provider == .genericConnector && isExisting,
                                            help: "凭据只留在系统钥匙串，不写入配置文件或通话记录。")
                    if connection.provider == .genericConnector && isExisting {
                        Text("访问令牌已保存，由 App 用于连接服务。这里仅供查看和复制；另一台手机连接同一服务时才需要填写。")
                            .font(.footnote).foregroundStyle(.secondary)
                        NavigationLink {
                            MCPOAuthAuthorizationSettings(connection: connection)
                        } label: {
                            SettingsActionLabel(title: String(localized: "MCP OAuth 授权"), symbol: "key")
                        }
                        NavigationLink {
                            ConnectorCurrentCallSettings(connection: connection, isCallActive: isCallActive)
                        } label: {
                            SettingsActionLabel(title: String(localized: "检查云端通话状态"), symbol: "phone")
                        }
                    }
                    if connection.provider == .xunfei {
                        SettingsCredentialField(title: "API Secret", connectionID: connection.id,
                                                field: .apiSecret, text: $apiSecret)
                    }
                    if connection.provider == .elevenLabs {
                        elevenLabsAdvancedConfiguration
                    }
                }
                if connection.provider.isSpeechSynthesis {
                    SettingsField(title: String(localized: "试听内容")) {
                        TextField("留空就读：你好，这是一次试听。", text: $speechTestText, axis: .vertical)
                            .lineLimit(1...4)
                    }
                    speechTestAction
                        .listRowSeparator(.hidden)
                }
            } header: { SettingsSectionHeading(number: connection.provider.isSpeechSynthesis ? "01" : nil, title: String(localized: "连接配置"), caption: "CONNECTION") }
            if connection.provider.isSpeechSynthesis {
                Section {
                    SettingsField(title: String(localized: "语音表达提示词"), help: "提示词跟着合成模型自动切换。改过以后按你写的来，点恢复默认换回当前模型那套；清空即关闭。\n独立模式每轮自动带上；后端／MCP 请复制到外部平台的提示词里。") {
                        TextEditor(text: Binding(get: { connection.effectiveExpressionPrompt }, set: { connection.expressionPrompt = $0 }))
                            .scrollContentBackground(.hidden).frame(minHeight: 120)
                            .accessibilityLabel("语音表达提示词")
                    }
                    HStack(spacing: 20) {
                        Spacer(minLength: 0)
                        Button {
                            UIPasteboard.general.string = connection.effectiveExpressionPrompt
                            didCopyExpression = true
                            expressionCopyTrigger = Date()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: didCopyExpression ? "checkmark" : "doc.on.doc")
                                Text("复制内容")
                            }
                        }
                        .preference(key: CopySuccessPreferenceKey.self, value: expressionCopyTrigger)
                        .task(id: expressionCopyTrigger) {
                            guard didCopyExpression else { return }
                            do { try await Task.sleep(for: .seconds(3)) } catch { return }
                            didCopyExpression = false
                        }
                        .onDisappear { didCopyExpression = false }
                        Button { connection.expressionPrompt = nil } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                Text("恢复默认")
                            }
                        }
                        Link(destination: expressionGuideURL) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right")
                                Text("官方指南")
                            }
                        }
                    }
                    .font(.caption)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .onChange(of: connection.effectiveExpressionPrompt) { _, _ in didCopyExpression = false }
                } header: { SettingsSectionHeading(number: "02", title: String(localized: "语音表达"), caption: "EXPRESSION") }
            }
            ConnectionDataSharingSection(connection: sharingConnection)
            if let errorMessage { Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            if isExisting, onDelete != nil {
                Section {
                    Button(role: .destructive) { isConfirmingDeletion = true } label: {
                        Text("删除连接").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                    .disabled(isCallActive)
                }
            }
        }
        .modifier(SettingsPageStyle(title: isExisting ? String(localized: "编辑连接") : String(localized: "添加连接"), subtitle: connection.provider.settingsDisplayName,
                                   symbol: connection.provider.isSpeechSynthesis ? "speaker.wave.2" : connection.provider.isSpeechRecognition ? "waveform" : "link",
                                   index: "CONNECTION", actionTitle: String(localized: "保存"), actionSymbol: "checkmark",
                                   actionDisabled: isConnectionLocked || isCallActive || !hasUnsavedChanges,
                                   actionConfirmed: actionConfirmed, actionFeedbackTrigger: actionFeedbackTrigger,
                                   onAction: { _ = save() },
                                   hasUnsavedChanges: hasUnsavedChanges,
                                   onSaveBeforeDismiss: { completion in if save() { completion() } }))
        .modifier(DeploymentHelpOverlay())
        .alert("删除这套连接配置？", isPresented: $isConfirmingDeletion) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                deleteConnection()
            }
            .disabled(isCallActive)
        } message: {
            Text("删除本机配置、访问凭据和关联选择，保留联系人、通话记录及云端数据。后台会尝试解除该服务的设备绑定；若服务不可达，远端绑定需另行清理。受影响的联系人需重新选择连接才能通话。")
        }
        .onAppear {
            guard savedSnapshot == nil else { return }
            let initialEndpoint = connection.endpoint?.absoluteString ?? ""
            endpoint = initialEndpoint
            savedSnapshot = ConnectionEditorSnapshot(connection: connection, endpoint: initialEndpoint)
        }
        .onDisappear { speechTest.cancel(deactivateAudio: !isCallActive) }
        .onChange(of: currentSnapshot) { _, _ in speechTest.cancel(deactivateAudio: !isCallActive) }
        .onChange(of: apiKey) { _, _ in speechTest.cancel(deactivateAudio: !isCallActive) }
        .onChange(of: apiSecret) { _, _ in speechTest.cancel(deactivateAudio: !isCallActive) }
        .onChange(of: isCallActive) { _, active in
            if active { speechTest.cancel(deactivateAudio: false) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { speechTest.cancel(deactivateAudio: !isCallActive) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            speechTest.cancel(deactivateAudio: !isCallActive)
        }
    }

    private func deleteConnection() {
        guard !isCallActive, let onDelete else { return }
        speechTest.cancel(deactivateAudio: !isCallActive)
        do {
            try onDelete(connection.id)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private var elevenLabsAdvancedConfiguration: some View {
        Group {
            Button {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    showsAdvancedConfiguration.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("高级参数")
                    Image(systemName: showsAdvancedConfiguration ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                }
                .font(.footnote)
                .foregroundStyle(Color.accentColor)
                .frame(minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsAdvancedConfiguration ? String(localized: "已展开") : String(localized: "已收起"))
            if showsAdvancedConfiguration {
                VStack(alignment: .leading, spacing: 16) {
                    elevenLabsSlider(title: String(localized: "稳定性"), value: $connection.elevenLabsStability, defaultValue: 0.5)
                    elevenLabsSlider(title: String(localized: "相似度"), value: $connection.elevenLabsSimilarityBoost, defaultValue: 0.75)
                }
            }
        }
        .disabled(isConnectionLocked || isCallActive)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
    }

    private func elevenLabsSlider(title: String, value: Binding<Double?>, defaultValue: Double) -> some View {
        let selection = Binding<Double>(get: {
            let current = value.wrappedValue ?? defaultValue
            return current.isFinite ? min(1, max(0, current)) : defaultValue
        }, set: { value.wrappedValue = $0 })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer(minLength: 0)
                Text(selection.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            Slider(value: selection, in: 0...1, step: 0.01) { Text(title) }
                .tint(.accentColor)
        }
    }

    private var speechTestAction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if speechTest.isRunning {
                    speechTest.cancel()
                } else {
                    speechTest.start(connection: sharingConnection, apiKey: apiKey, apiSecret: apiSecret, isCallActive: isCallActive, sampleText: speechTestText)
                }
            } label: {
                Label(speechTest.isRunning ? String(localized: "取消测试") : String(localized: "生成并试听"),
                      systemImage: speechTest.isRunning ? "stop" : "play")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(isCallActive)
            if speechTest.isRunning {
                ProgressView(speechTest.progress).font(.caption)
            }
            if let feedback = speechTest.feedback {
                Text(feedback.message).font(.caption)
                    .foregroundStyle(feedback.isFailure ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var expressionGuideURL: URL {
        switch connection.provider {
        case .fishAudio: URL(string: "https://docs.fish.audio/developer-guide/core-features/emotions")!
        case .miniMax: URL(string: "https://platform.minimax.io/docs/api-reference/speech-t2a-http")!
        default: URL(string: "https://elevenlabs.io/docs/overview/capabilities/text-to-speech/best-practices")!
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard !isConnectionLocked, !isCallActive else { return false }
        do {
            var next = connection
            next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
            next.model = next.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let needsAddress = next.provider == .openAICompatible || next.provider == .genericConnector || next.provider == .whisperCompatible
            let address = needsAddress ? endpoint.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if address.isEmpty {
                guard !needsAddress else { throw TincallError(message: String(localized: "请填写完整 HTTPS 地址")) }
                next.endpoint = nil
            } else {
                guard let url = URL(string: address), url.scheme == "https", url.host != nil,
                      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw TincallError(message: String(localized: "请填写无内嵌凭据或查询参数的 HTTPS 地址")) }
                next.endpoint = url
            }
            if next.provider == .openAICompatible || next.provider == .bailian || next.provider == .whisperCompatible || next.provider.isSpeechSynthesis,
               next.model.isEmpty { throw TincallError(message: String(localized: "请填写模型标识")) }
            if next.provider.isSpeechSynthesis, next.voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw TincallError(message: String(localized: "请填写 Voice ID"))
            }
            if next.provider == .xunfei, next.applicationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw TincallError(message: String(localized: "请填写讯飞 App ID")) }
            if next.provider == .whisperCompatible {
                let language = next.language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                guard language.isEmpty || (language.count == 2 && language.allSatisfy({ $0.isASCII && $0.isLetter })) else {
                    throw TincallError(message: String(localized: "识别语言请填写两位代码，如 zh、en，或留空自动识别"))
                }
                next.language = language.isEmpty ? nil : language
            }
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            let savedKey = next.provider == .genericConnector && isExisting ? nil : key.isEmpty ? nil : key
            try onSave(next, savedKey, next.provider == .xunfei && !secret.isEmpty ? secret : nil)
            connection = next
            endpoint = next.endpoint?.absoluteString ?? ""
            apiKey = ""
            apiSecret = ""
            isExisting = true
            savedSnapshot = ConnectionEditorSnapshot(connection: next, endpoint: endpoint)
            showSaveConfirmation()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private func showSaveConfirmation() {
        actionConfirmed = true
        actionFeedbackTrigger &+= 1
        let token = UUID()
        confirmationToken = token
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard confirmationToken == token else { return }
            actionConfirmed = false
        }
    }
}

extension ConnectionProvider {
    var settingsDisplayName: String { String(localized: String.LocalizationValue(displayName)) }

    var displayName: String {
        switch self {
        case .openAICompatible: "OpenAI 兼容"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .xunfei: "讯飞识别"
        case .elevenLabs: "ElevenLabs 语音"
        case .appleSpeech: "Apple 本机识别"
        case .bailian: "百炼识别"
        case .miniMax: "MiniMax 语音"
        case .whisperCompatible: "Whisper 兼容"
        case .fishAudio: "Fish Audio 语音"
        case .genericConnector: "通用连接端"
        }
    }
}
