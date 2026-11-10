// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

private struct ModelPresetSnapshot: Equatable {
    let connection: ConnectionProfile
    let endpoint: String
    let temperature: String
    let topP: String
    let maxTokens: String
    let anthropicBudget: String
    let geminiBudget: String
}

struct APISettingsScreen: View {
    let store: LocalConfigurationStore
    let isCallActive: Bool
    let onSave: (ConnectionProfile, String?, String?) throws -> Void

    var body: some View {
        SettingsList {
            Section {
                ForEach(store.connections.filter { $0.provider.isLanguageModel }) { connection in
                    NavigationLink {
                        ModelPresetEditor(connection: connection, isExisting: true, onSave: onSave)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(connection.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text("\(connection.provider.settingsDisplayName) · \(connection.model)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    .disabled(isCallActive)
                }
                NavigationLink {
                    ModelPresetEditor(connection: ConnectionProfile(name: "", provider: .openAICompatible),
                                      isExisting: false, onSave: onSave)
                } label: {
                    SettingsActionLabel(title: String(localized: "添加 API 预设"), symbol: "plus", detail: String(localized: "连接一个模型，供聊天或摘要使用"))
                }
                .disabled(isCallActive)
            } header: { SettingsSectionHeading(title: String(localized: "我的预设"), caption: "\(store.connections.filter { $0.provider.isLanguageModel }.count) SAVED") }
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("聊天与摘要分别选择预设").font(.headline)
                    Text("先保存 API 预设，再到联系人里分别选择聊天模型和摘要模型。")
                        .font(.footnote).foregroundStyle(.secondary).lineSpacing(3)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { protocolBadges }
                        VStack(alignment: .leading, spacing: 6) { protocolBadges }
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                .listRowSeparator(.hidden)
                SettingsNote(title: String(localized: "其他服务怎么接入？"), text: String(localized: "DeepSeek、通义千问及其他兼容服务可选择 OpenAI 兼容，填写相应地址、API Key 与模型名称。"))
            }
        }
        .modifier(SettingsPageStyle(title: String(localized: "API 设置"), subtitle: String(localized: "聊天模型 · 摘要模型"), symbol: "slider.horizontal.3", index: "MODEL API"))
    }

    private var protocolBadges: some View {
        ForEach([String(localized: "OpenAI 兼容"), "Anthropic", "Gemini"], id: \.self) { name in
            Text(name).font(.caption2.weight(.medium))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
        }
    }
}

private struct ModelPresetEditor: View {
    private enum Parameter: Hashable {
        case temperature, topP, maxTokens, anthropicBudget
    }

    @State var connection: ConnectionProfile
    let isExisting: Bool
    let onSave: (ConnectionProfile, String?, String?) throws -> Void
    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var temperature = "1"
    @State private var topP = "1"
    @State private var maxTokens = ""
    @State private var anthropicBudget = "1024"
    @State private var geminiBudget = "-1"
    @State private var models: [String] = []
    @State private var isWorking = false
    @State private var operation: Task<Void, Never>?
    @State private var fetchFeedback: SettingsConnectionFeedback?
    @State private var testFeedback: SettingsConnectionFeedback?
    @State private var isFetchingModels = false
    @State private var errorMessage: String?
    @State private var savedSnapshot: ModelPresetSnapshot?
    @State private var hasSaved = false
    @State private var actionConfirmed = false
    @State private var actionFeedbackTrigger = 0
    @State private var confirmationToken = UUID()
    @FocusState private var focusedParameter: Parameter?

    private var editingExisting: Bool { isExisting || hasSaved }

    private var sharingConnection: ConnectionProfile {
        var value = connection
        value.endpoint = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
        return value
    }

    private var currentSnapshot: ModelPresetSnapshot {
        ModelPresetSnapshot(connection: connection, endpoint: endpoint, temperature: temperature, topP: topP,
                            maxTokens: maxTokens, anthropicBudget: anthropicBudget, geminiBudget: geminiBudget)
    }

    private var hasUnsavedChanges: Bool {
        guard let savedSnapshot else { return false }
        return currentSnapshot != savedSnapshot || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SettingsList {
            Section {
                SettingsField(title: String(localized: "连接名称")) {
                    SettingsTextField(placeholder: String(localized: "例如：日常聊天"), text: $connection.name)
                        .accessibilityLabel("连接名称")
                }
            } header: { SettingsSectionHeading(number: "01", title: String(localized: "连接信息"), caption: "CONNECTION") }
            Section {
                SettingsPickerRow(title: String(localized: "API 协议"), value: connection.provider.settingsDisplayName, selection: $connection.provider) {
                    Text("OpenAI 兼容").tag(ConnectionProvider.openAICompatible)
                    Text("Anthropic").tag(ConnectionProvider.anthropic)
                    Text("Gemini").tag(ConnectionProvider.gemini)
                }
                .disabled(editingExisting)
                SettingsField(title: String(localized: "API 地址")) {
                    TextField(defaultEndpoint(connection.provider), text: $endpoint)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("API 地址")
                }
                SettingsCredentialField(title: "API Key", connectionID: connection.id, text: $apiKey)
            } header: { SettingsSectionHeading(number: "02", title: String(localized: "服务连接"), caption: "SERVICE") } footer: {
                Text("支持基础地址或完整接口。密钥只留在系统钥匙串，不进入备份。")
                .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                SettingsField(title: String(localized: "模型名称")) {
                    TextField("手动填写，或从服务拉取", text: $connection.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("模型名称")
                }
                if !models.isEmpty {
                    SettingsPickerRow(title: String(localized: "已拉取的模型"), value: connection.model.isEmpty ? String(localized: "请选择") : connection.model, selection: $connection.model) {
                        if !models.contains(connection.model) {
                            Text(connection.model.isEmpty ? String(localized: "请选择") : connection.model).tag(connection.model)
                        }
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    modelAction(String(localized: "拉取模型"), symbol: "arrow.clockwise", fetchModels: true)
                    modelAction(String(localized: "测试连接"), symbol: "bolt", fetchModels: false)
                }
                .listRowSeparator(.hidden)
            } header: { SettingsSectionHeading(number: "03", title: String(localized: "选择模型"), caption: "MODEL") } footer: {
                Text("测试会发送简短请求，使用供应商额度；开启思考时也会使用所选思考配置。")
                .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                thinkingControls
            } header: { SettingsSectionHeading(number: "04", title: String(localized: "思考设置"), caption: "THINKING") } footer: {
                Text(thinkingDescription)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle("自定义温度", isOn: Binding(get: { connection.temperature != nil }, set: { connection.temperature = $0 ? 1 : nil }))
                if connection.temperature != nil {
                    parameterField(String(localized: "温度"), value: $temperature, field: .temperature,
                                   placeholder: connection.provider == .anthropic ? "0–1" : "0–2")
                }
                Toggle("自定义 Top P", isOn: Binding(get: { connection.topP != nil }, set: { connection.topP = $0 ? 1 : nil }))
                if connection.topP != nil { parameterField("Top P", value: $topP, field: .topP, placeholder: "0–1") }
                parameterField(String(localized: "最大输出 tokens"), value: $maxTokens, field: .maxTokens,
                               keyboard: .numberPad,
                               placeholder: connection.provider == .anthropic ? String(localized: "默认 4096") : String(localized: "由服务决定"))
            } header: { SettingsSectionHeading(number: "05", title: String(localized: "请求参数"), caption: "OPTIONAL") } footer: {
                Text((connection.provider == .anthropic ? String(localized: "留空时 Tincall 发送 4096，包含思考和回答的预算。") : String(localized: "留空时不指定输出上限，由所用服务决定。")) + String(localized: "关闭的参数不发送；建议只调整温度或 Top P 其中一项。摘要使用联系人里的单独输出上限。"))
                .font(.footnote).foregroundStyle(.secondary)
            }
            ConnectionDataSharingSection(connection: sharingConnection)
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
        }
        .disabled(isWorking)
        .modifier(SettingsPageStyle(title: editingExisting ? String(localized: "编辑 API 预设") : String(localized: "添加 API 预设"),
                                   subtitle: String(localized: "服务地址、API 密钥与模型参数"), symbol: "slider.horizontal.3", index: "MODEL API",
                                   actionTitle: String(localized: "保存"), actionSymbol: "checkmark",
                                   actionDisabled: isWorking || !hasUnsavedChanges,
                                   actionConfirmed: actionConfirmed, actionFeedbackTrigger: actionFeedbackTrigger,
                                   onAction: { _ = save() },
                                   dismissDisabled: isWorking,
                                   hasUnsavedChanges: hasUnsavedChanges,
                                   onSaveBeforeDismiss: { completion in if save() { completion() } }))
        .onAppear {
            guard savedSnapshot == nil else { return }
            let initialEndpoint = connection.endpoint?.absoluteString ?? defaultEndpoint(connection.provider)
            let initialTemperature = connection.temperature.map { String($0) } ?? "1"
            let initialTopP = connection.topP.map { String($0) } ?? "1"
            let initialMaxTokens = connection.maxOutputTokens.map { String($0) } ?? ""
            let initialAnthropicBudget = connection.anthropicThinkingBudget.map(String.init) ?? "1024"
            let initialGeminiBudget = connection.geminiThinkingBudget.map(String.init) ?? "-1"
            endpoint = initialEndpoint
            temperature = initialTemperature
            topP = initialTopP
            maxTokens = initialMaxTokens
            anthropicBudget = initialAnthropicBudget
            geminiBudget = initialGeminiBudget
            if savedSnapshot == nil {
                savedSnapshot = ModelPresetSnapshot(connection: connection, endpoint: initialEndpoint,
                                                    temperature: initialTemperature, topP: initialTopP,
                                                    maxTokens: initialMaxTokens, anthropicBudget: initialAnthropicBudget,
                                                    geminiBudget: initialGeminiBudget)
            }
        }
        .onChange(of: connection.provider) { old, new in
            if endpoint.isEmpty || endpoint == defaultEndpoint(old) { endpoint = defaultEndpoint(new) }
            models = []
            connection.model = ""
            connection.openAIReasoningEffort = nil
            connection.anthropicThinkingMode = nil
            connection.anthropicThinkingBudget = nil
            connection.anthropicEffort = nil
            connection.geminiThinkingLevel = nil
            connection.geminiThinkingBudget = nil
            fetchFeedback = nil
            testFeedback = nil
            errorMessage = nil
        }
        .onDisappear { operation?.cancel() }
    }

    @ViewBuilder private var thinkingControls: some View {
        switch connection.provider {
        case .openAICompatible:
            SettingsPickerRow(title: String(localized: "思考强度"), value: connection.openAIReasoningEffort.map { effortName($0.rawValue) } ?? String(localized: "模型默认"), selection: $connection.openAIReasoningEffort) {
                Text("模型默认").tag(nil as OpenAIReasoningEffort?)
                ForEach(OpenAIReasoningEffort.allCases, id: \.self) { effort in
                    Text(effortName(effort.rawValue)).tag(Optional(effort))
                }
            }
        case .anthropic:
            SettingsPickerRow(title: String(localized: "思考模式"), value: anthropicModeName, selection: Binding(get: { connection.anthropicThinkingMode }, set: { mode in
                connection.anthropicThinkingMode = mode
                connection.anthropicThinkingBudget = mode == .manual ? 1024 : nil
                connection.anthropicEffort = nil
                anthropicBudget = "1024"
            })) {
                Text("模型默认").tag(nil as AnthropicThinkingMode?)
                Text("关闭").tag(Optional(AnthropicThinkingMode.off))
                Text("自适应思考").tag(Optional(AnthropicThinkingMode.adaptive))
                Text("指定思考预算").tag(Optional(AnthropicThinkingMode.manual))
            }
            if connection.anthropicThinkingMode == .adaptive {
                SettingsPickerRow(title: String(localized: "思考强度"), value: connection.anthropicEffort.map { effortName($0.rawValue) } ?? String(localized: "模型默认"), selection: $connection.anthropicEffort) {
                    Text("模型默认").tag(nil as AnthropicEffort?)
                    ForEach(AnthropicEffort.allCases, id: \.self) { effort in
                        Text(effortName(effort.rawValue)).tag(Optional(effort))
                    }
                }
            }
            if connection.anthropicThinkingMode == .manual {
                parameterField(String(localized: "思考预算 tokens"), value: $anthropicBudget, field: .anthropicBudget,
                               keyboard: .numberPad, placeholder: String(localized: "至少 1024"))
            }
        case .gemini:
            SettingsPickerRow(title: String(localized: "思考设置方式"), value: connection.geminiThinkingLevel != nil ? String(localized: "按强度") : connection.geminiThinkingBudget != nil ? String(localized: "按预算") : String(localized: "模型默认"), selection: Binding(get: {
                connection.geminiThinkingLevel != nil ? "level" : connection.geminiThinkingBudget != nil ? "budget" : "default"
            }, set: { mode in
                connection.geminiThinkingLevel = mode == "level" ? .low : nil
                connection.geminiThinkingBudget = mode == "budget" ? -1 : nil
                geminiBudget = "-1"
            })) {
                Text("模型默认").tag("default")
                Text("按强度").tag("level")
                Text("按预算").tag("budget")
            }
            if connection.geminiThinkingLevel != nil {
                SettingsPickerRow(title: String(localized: "思考强度"), value: connection.geminiThinkingLevel.map { effortName($0.rawValue) } ?? String(localized: "模型默认"), selection: $connection.geminiThinkingLevel) {
                    ForEach(GeminiThinkingLevel.allCases.filter { $0 != .minimal }, id: \.self) { level in
                        Text(effortName(level.rawValue)).tag(Optional(level))
                    }
                    if connection.geminiThinkingLevel == .minimal {
                        Text("minimal · 当前多轮通话不支持").tag(Optional(GeminiThinkingLevel.minimal))
                    }
                }
            }
            if connection.geminiThinkingBudget != nil {
                SettingsField(title: String(localized: "思考预算 tokens")) {
                    TextField("-1 为动态预算，0 为关闭", text: $geminiBudget)
                        .keyboardType(.numbersAndPunctuation)
                }
            }
        default: EmptyView()
        }
    }

    private var anthropicModeName: String {
        switch connection.anthropicThinkingMode {
        case .off: String(localized: "关闭")
        case .adaptive: String(localized: "自适应思考")
        case .manual: String(localized: "指定思考预算")
        case nil: String(localized: "模型默认")
        }
    }

    private var thinkingDescription: String {
        switch connection.provider {
        case .openAICompatible:
            String(localized: "模型默认不发送思考参数。其他选项要求服务支持 reasoning_effort；各模型可用强度不同。强度越高通常等待越久，通话可先试低。")
        case .anthropic:
            String(localized: "按模型选择自适应思考或指定预算。手动预算至少 1024，且须小于本次输出上限。")
        case .gemini:
            String(localized: "Gemini 3 系列优先使用强度，2.5 系列使用预算。-1 为动态预算；0 仅在支持关闭思考的模型上可用。强度与预算不能同时发送。")
        default: ""
        }
    }

    private func effortName(_ value: String) -> String {
        switch value {
        case "none": String(localized: "关闭 · none")
        case "minimal": String(localized: "最低 · minimal")
        case "low": String(localized: "低 · low")
        case "medium": String(localized: "中 · medium")
        case "high": String(localized: "高 · high")
        case "xhigh": String(localized: "更高 · xhigh")
        case "max": String(localized: "最高 · max")
        default: value
        }
    }

    private func modelAction(_ title: String, symbol: String, fetchModels: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { perform(fetchModels: fetchModels) } label: {
                Label(title, systemImage: symbol).font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            if isWorking && isFetchingModels == fetchModels {
                ProgressView("正在连接…").font(.caption)
            }
            if let feedback = fetchModels ? fetchFeedback : testFeedback {
                Text(feedback.message).font(.caption)
                    .foregroundStyle(feedback.isFailure ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func parameterField(_ title: String, value: Binding<String>, field: Parameter,
                                keyboard: UIKeyboardType = .decimalPad, placeholder: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: value)
                .keyboardType(keyboard).multilineTextAlignment(.trailing)
                .frame(maxWidth: 150).accessibilityLabel(title)
                .focused($focusedParameter, equals: field)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { focusedParameter = field })
    }

    private func defaultEndpoint(_ provider: ConnectionProvider) -> String {
        switch provider {
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        default: "https://api.openai.com/v1"
        }
    }

    private func draft(requiresModel: Bool) throws -> ConnectionProfile {
        var next = connection
        next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
        next.model = next.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw TincallError(message: String(localized: "请填写不带凭据或查询参数的 HTTPS 地址。"))
        }
        next.endpoint = url
        if requiresModel, next.model.isEmpty { throw TincallError(message: String(localized: "请输入或选择模型名称。")) }
        if connection.temperature != nil {
            let limit = connection.provider == .anthropic ? 1.0 : 2.0
            guard let value = Double(temperature), value.isFinite, (0...limit).contains(value) else {
                throw TincallError(message: String(localized: "温度需为 0–\(Int(limit)) 之间的数字。"))
            }
            next.temperature = value
        }
        if connection.topP != nil {
            guard let value = Double(topP), value.isFinite, (0...1).contains(value) else {
                throw TincallError(message: String(localized: "Top P 需为 0–1 之间的数字。"))
            }
            next.topP = value
        }
        let maximum = maxTokens.trimmingCharacters(in: .whitespacesAndNewlines)
        if maximum.isEmpty { next.maxOutputTokens = nil }
        else {
            guard let value = Int(maximum), value > 0 else { throw TincallError(message: String(localized: "最大输出需为正整数，或留空使用默认值。")) }
            next.maxOutputTokens = value
        }
        if next.anthropicThinkingMode == .manual {
            guard let value = Int(anthropicBudget.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw TincallError(message: String(localized: "请填写整数思考预算"))
            }
            next.anthropicThinkingBudget = value
        }
        if next.geminiThinkingBudget != nil {
            guard let value = Int(geminiBudget.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw TincallError(message: String(localized: "请填写整数思考预算，或用 -1 自动调整"))
            }
            next.geminiThinkingBudget = value
        }
        try ModelRequestCodec.validateParameters(next)
        return next
    }

    @discardableResult
    private func save() -> Bool {
        do {
            let next = try draft(requiresModel: true)
            guard !next.name.isEmpty else { throw TincallError(message: String(localized: "请填写预设名称。")) }
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try onSave(next, key.isEmpty ? nil : key, nil)
            let savedEndpoint = next.endpoint?.absoluteString ?? defaultEndpoint(next.provider)
            let savedTemperature = next.temperature.map { String($0) } ?? "1"
            let savedTopP = next.topP.map { String($0) } ?? "1"
            let savedMaxTokens = next.maxOutputTokens.map { String($0) } ?? ""
            let savedAnthropicBudget = next.anthropicThinkingBudget.map(String.init) ?? "1024"
            let savedGeminiBudget = next.geminiThinkingBudget.map(String.init) ?? "-1"
            connection = next
            endpoint = savedEndpoint
            temperature = savedTemperature
            topP = savedTopP
            maxTokens = savedMaxTokens
            anthropicBudget = savedAnthropicBudget
            geminiBudget = savedGeminiBudget
            apiKey = ""
            savedSnapshot = ModelPresetSnapshot(connection: next, endpoint: savedEndpoint,
                                                temperature: savedTemperature, topP: savedTopP,
                                                maxTokens: savedMaxTokens, anthropicBudget: savedAnthropicBudget,
                                                geminiBudget: savedGeminiBudget)
            hasSaved = true
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

    private func perform(fetchModels: Bool) {
        isFetchingModels = fetchModels
        setFeedback(nil, fetchModels: fetchModels)
        do {
            let next = try draft(requiresModel: !fetchModels)
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            isWorking = true
            errorMessage = nil
            operation = Task { @MainActor in
                defer { isWorking = false }
                do {
                    let client = ChatCompletionClient()
                    if fetchModels {
                        let fetched = try await client.fetchModels(connection: next, apiKey: key.isEmpty ? nil : key)
                        try Task.checkCancellation()
                        models = fetched
                        setFeedback(SettingsConnectionFeedback(message: String(localized: "已拉取 \(fetched.count) 个模型")), fetchModels: true)
                    } else {
                        _ = try await client.testConnection(connection: next, apiKey: key.isEmpty ? nil : key)
                        try Task.checkCancellation()
                        setFeedback(SettingsConnectionFeedback(message: String(localized: "连接正常")), fetchModels: false)
                    }
                } catch {
                    if !Task.isCancelled {
                        setFeedback(SettingsConnectionFeedback(error: error), fetchModels: fetchModels)
                    }
                }
            }
        } catch { setFeedback(SettingsConnectionFeedback(error: error), fetchModels: fetchModels) }
    }

    private func setFeedback(_ feedback: SettingsConnectionFeedback?, fetchModels: Bool) {
        if fetchModels { fetchFeedback = feedback }
        else { testFeedback = feedback }
    }
}

struct SettingsConnectionFeedback {
    let message: String
    var isFailure = false

    init(message: String) { self.message = message }

    init(error: Error) {
        isFailure = true
        let detail = error.localizedDescription
        let networkCode = (error as NSError).code
        if detail.contains("HTTP 401") {
            message = String(localized: "密钥不对或已失效，请重新填写")
        } else if detail.contains("HTTP 403") {
            message = String(localized: "没有访问权限，请检查密钥和模型权限")
        } else if detail.contains("HTTP 429") {
            message = String(localized: "请求太频繁或额度不足，请稍后重试或检查余额")
        } else if detail.contains("HTTP 404") || detail.contains("HTTP 405") {
            message = String(localized: "地址或模型不对，请检查 API 地址和模型名称")
        } else if detail.contains("HTTP 5") {
            message = String(localized: "服务暂时不可用，请稍后重试")
        } else if networkCode == NSURLErrorTimedOut || detail.contains("（-1001）") {
            message = String(localized: "连接超时，请检查网络后重试")
        } else if [NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorBadURL, NSURLErrorUnsupportedURL].contains(networkCode)
                    || ["（-1003）", "（-1004）", "（-1000）", "（-1002）"].contains(where: detail.contains) {
            message = String(localized: "无法连接这个地址，请检查 API 地址和网络")
        } else if networkCode == NSURLErrorNotConnectedToInternet || detail.contains("（-1009）") {
            message = String(localized: "网络未连接，请联网后重试")
        } else if networkCode == NSURLErrorSecureConnectionFailed || detail.contains("（-1200）") || detail.contains("（-1202）") {
            message = String(localized: "无法建立安全连接，请检查地址与服务证书")
        } else {
            message = detail
        }
    }
}
