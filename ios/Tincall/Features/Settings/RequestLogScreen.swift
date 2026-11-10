// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import UIKit

struct RequestLogScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var store: RequestLogStore = .shared
    @State private var selectedCallID: UUID?
    @State private var category: RequestLogCategory = .all
    @State private var failuresOnly = false
    @State private var exportFile: RequestLogExportFile?
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var isExporting = false

    @State private var loadedEntries: [RequestLogEntry] = []
    @State private var visibleLimit = 100
    @State private var loadError: String?
    @State private var configuringExport = false
    @State private var exportCallID: UUID?
    @State private var exportCategory: RequestLogCategory = .all
    @State private var exportFailuresOnly = false
    @State private var exportLimit = 0
    @State private var pendingExport: [RequestLogEntry]?

    init(store: RequestLogStore = .shared, callID: UUID? = nil) {
        self.store = store
        _selectedCallID = State(initialValue: callID)
    }

    private var calls: [RequestLogCall] {
        var result = store.calls
        #if DEBUG
        result += RequestLogExamples.shared.store?.calls ?? []
        #endif
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    private var selectedCallTitle: String {
        guard let selectedCallID else { return String(localized: "全部") }
        guard let call = calls.first(where: { $0.id == selectedCallID }) else { return String(localized: "本次通话") }
        return callTitle(call)
    }

    private func callTitle(_ call: RequestLogCall) -> String {
        call.startedAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second())
    }

    private func matching(_ category: RequestLogCategory, failuresOnly: Bool, callID: UUID?) -> [RequestLogEntry] {
        var result = store.matching(category: category, failuresOnly: failuresOnly, callID: callID)
        #if DEBUG
        result += RequestLogExamples.shared.store?.matching(category: category, failuresOnly: failuresOnly, callID: callID) ?? []
        #endif
        return result.sorted { $0.time == $1.time ? $0.id.uuidString < $1.id.uuidString : $0.time > $1.time }
    }

    private var entries: [RequestLogEntry] { matching(category, failuresOnly: failuresOnly, callID: selectedCallID) }
    private var exportEntries: [RequestLogEntry] { matching(exportCategory, failuresOnly: exportFailuresOnly, callID: exportCallID) }

    private func load(_ selection: [RequestLogEntry]) throws -> [RequestLogEntry] {
        #if DEBUG
        if let examples = RequestLogExamples.shared.store {
            let exampleIDs = Set(examples.entries.map(\.id))
            let values = try store.load(selection.filter { !exampleIDs.contains($0.id) })
                + examples.load(selection.filter { exampleIDs.contains($0.id) })
            let byID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
            return selection.compactMap { byID[$0.id] }
        }
        #endif
        return try store.load(selection)
    }

    private func reload(reset: Bool = false) {
        if reset { visibleLimit = 100; loadedEntries = [] }
        do {
            loadedEntries = try load(Array(entries.prefix(visibleLimit)))
            loadError = nil
        } catch {
            loadError = String(localized: "无法读取日志正文（\((error as NSError).code)），请重试。")
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let issue = store.storageIssue {
                    Text(issue).font(.caption).foregroundStyle(.red)
                }
                ZStack(alignment: .topLeading) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(loadedEntries) { entry in
                            RequestLogCard(entry: entry)
                        }
                        if let loadError {
                            Text(loadError).font(.caption).foregroundStyle(.red)
                            Button("重试") { reload() }
                        } else if !loadedEntries.isEmpty && loadedEntries.count < entries.count {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
                                .id(loadedEntries.last?.id)
                                .onAppear { visibleLimit += 100; reload() }
                        }
                        if entries.isEmpty {
                            Text(failuresOnly ? String(localized: "没有符合条件的失败请求") : (selectedCallID == nil ? String(localized: "暂无请求日志") : String(localized: "这通电话暂无请求日志")))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        }
                    }
                    .id("\(selectedCallID?.uuidString ?? "all")-\(category.rawValue)-\(failuresOnly)")
                    .transition(.opacity)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: category)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: failuresOnly)
            }
            .padding(.horizontal, 24)
        }
        // Filters stay under the page header instead of scrolling away with the cards.
        .safeAreaBar(edge: .top, spacing: 0) {
            filters.padding(.horizontal, 24)
        }
        .modifier(SettingsPageStyle(title: String(localized: "请求日志"), subtitle: String(localized: "仅存本机 · 最近 7 天"),
                                    symbol: "list.bullet.rectangle", index: "REQUEST LOGS",
                                    actionTitle: String(localized: "导出"), actionSymbol: "square.and.arrow.up", actionDisabled: entries.isEmpty || isExporting, onAction: configureExport))
        .overlay {
            if isExporting {
                ProgressView("正在导出")
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear { reload(reset: true) }
        .onChange(of: category) { reload(reset: true) }
        .onChange(of: failuresOnly) { reload(reset: true) }
        .onChange(of: selectedCallID) { reload(reset: true) }
        .onChange(of: store.revision) { reload() }
        .sheet(isPresented: $configuringExport, onDismiss: finishExportConfiguration) { exportOptions }
        .sheet(item: $exportFile, onDismiss: removeExportFile) { file in
            RequestLogShareSheet(url: file.url)
        }
        .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private func configureExport() {
        guard !isExporting else { return }
        exportCallID = selectedCallID
        exportCategory = category
        exportFailuresOnly = failuresOnly
        exportLimit = 0
        configuringExport = true
    }

    private var exportOptions: some View {
        NavigationStack {
            Form {
                Picker("通话", selection: $exportCallID) {
                    Text("全部").tag(nil as UUID?)
                    if let exportCallID, !calls.contains(where: { $0.id == exportCallID }) {
                        Text("本次通话").tag(Optional(exportCallID))
                    }
                    ForEach(calls) { call in
                        Text(callTitle(call)).tag(Optional(call.id))
                    }
                }
                Picker("请求类型", selection: $exportCategory) {
                    ForEach(RequestLogCategory.allCases) { Text($0.title).tag($0) }
                }
                Toggle("只看失败", isOn: $exportFailuresOnly)
                Picker("导出数量", selection: $exportLimit) {
                    Text("全部").tag(0)
                    ForEach([500, 300, 100, 50], id: \.self) { count in
                        Text("最新 \(count) 条").tag(count)
                    }
                }
                .disabled(exportCallID != nil)
                if exportEntries.isEmpty {
                    Text("没有可导出的请求").foregroundStyle(.secondary)
                }
                Section {
                    Text("导出完整原始请求正文，包含模型参数与图片数据，鉴权信息已脱敏。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("导出请求日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { configuringExport = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导出") {
                        let selected = exportEntries
                        pendingExport = exportCallID != nil || exportLimit == 0 ? selected : Array(selected.prefix(exportLimit))
                        configuringExport = false
                    }
                    .disabled(exportEntries.isEmpty)
                }
            }
        }
        .onChange(of: exportCallID) { if exportCallID != nil { exportLimit = 0 } }
        .presentationDetents([.medium, .large])
    }

    private func finishExportConfiguration() {
        guard let selection = pendingExport else { return }
        pendingExport = nil
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(String(localized: "Tincall-请求日志") + "-\(UUID()).txt")
            do {
                try Data().write(to: url, options: [.atomic, .completeFileProtection])
                let file = try FileHandle(forWritingTo: url)
                do {
                    for (index, metadata) in selection.enumerated() {
                        try Task.checkCancellation()
                        let entry = try load([metadata])[0]
                        try RequestLogText.writeExportEntry(entry, to: file, isFirst: index == 0)
                        if index.isMultiple(of: 20) { await Task.yield() }
                    }
                    try file.write(contentsOf: Data("\n".utf8))
                    try file.close()
                } catch {
                    try? file.close()
                    throw error
                }
                exportURL = url
                exportFile = RequestLogExportFile(url: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                exportError = String(localized: "无法生成日志文件（\((error as NSError).code)），请重试。")
            }
        }
    }

    private func removeExportFile() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        exportURL = nil
    }

    private var filters: some View {
        HStack(spacing: 8) {
            callMenu
                .padding(.trailing, 12)
            categoryMenu
            Spacer(minLength: 0)
            failureFilter
        }
        .padding(.bottom, 2)
    }

    private var callMenu: some View {
        Menu {
            Picker("按通话筛选", selection: $selectedCallID) {
                Text("全部").tag(nil as UUID?)
                if let selectedCallID, !calls.contains(where: { $0.id == selectedCallID }) {
                    Text("本次通话").tag(Optional(selectedCallID))
                }
                ForEach(calls) { call in
                    Text(callTitle(call)).tag(Optional(call.id))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("通话：\(selectedCallTitle)")
                    .font(.footnote.weight(.medium))
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .accessibilityLabel("按通话筛选").accessibilityValue(selectedCallTitle)
    }

    private var categoryMenu: some View {
        Menu {
            Picker(String(localized: "请求类型"), selection: $category) {
                ForEach(RequestLogCategory.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text("类型：\(category == .all ? String(localized: "全部") : category.title)")
                    .font(.footnote.weight(.medium))
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .accessibilityLabel("请求类型").accessibilityValue(category.title)
    }

    private var failureFilter: some View {
        Button { failuresOnly.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: failuresOnly ? "checkmark.square.fill" : "square")
                    .foregroundStyle(failuresOnly ? Color.accentColor : Color.secondary)
                Text("只看失败")
            }
                .font(.caption).fixedSize().frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(failuresOnly ? Color.primary : Color.secondary)
        .accessibilityValue(failuresOnly ? String(localized: "已开启") : String(localized: "已关闭"))
    }
}

private struct RequestLogExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct RequestLogShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A request stays in one card. Expanding reveals its input and diagnostics in place.
private struct RequestLogCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: RequestLogEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleExpansion) {
                header
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "\(entry.title)，\(entry.identity)，\(entry.statusText)"))
            .accessibilityValue(isExpanded ? String(localized: "已展开") : String(localized: "已收起"))
            .accessibilityHint(String(localized: "显示或收起请求详情"))

            if entry.outcome == .failed {
                Text(entry.failureReason)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            if isExpanded {
                Divider().padding(.vertical, 12)
                contents
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
    }

    private func toggleExpansion() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            isExpanded.toggle()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(entry.statusText).font(.caption).fixedSize()
                    .foregroundStyle(entry.outcome == .failed ? Color.red : Color.secondary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            if !entry.identity.isEmpty {
                Text(entry.identity).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(entry.metadata).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isExpanded {
                RequestLogTextBlock(title: entry.isModel ? String(localized: "输入") : String(localized: "请求"), text: entry.requestText,
                                    omittedTurnCount: entry.category == .chat ? entry.omittedTurnCount ?? 0 : 0,
                                    conversationOffset: entry.requestConversationOffset)
                if entry.isModel {
                    if let reasoning = entry.reasoningText, !reasoning.isEmpty {
                        RequestLogTextBlock(title: String(localized: "思考"), text: reasoning)
                    } else if entry.outcome == .succeeded {
                        Text("服务商未返回思考").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            RequestLogTextBlock(title: entry.outputTitle, text: entry.responseText)
            if isExpanded {
                RequestLogTextBlock(title: String(localized: "服务端错误"), text: entry.serverErrorText)
            }
        }
    }
}

private struct RequestLogTextBlock: View {
    let title: String
    let text: String?
    var omittedTurnCount = 0
    var conversationOffset: Int? = nil
    @State private var didCopy = false
    @State private var copyFeedbackTrigger: Date?

    var body: some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        UIPasteboard.general.string = text
                        didCopy = true
                        copyFeedbackTrigger = Date()
                    } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.caption).foregroundStyle(didCopy ? Color.accentColor : Color.secondary)
                            .frame(width: 44, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(didCopy ? String(localized: "\(title)已复制") : String(localized: "复制\(title)"))
                    .preference(key: CopySuccessPreferenceKey.self, value: copyFeedbackTrigger)
                    .task(id: copyFeedbackTrigger) {
                        guard didCopy else { return }
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        didCopy = false
                    }
                    .onDisappear { didCopy = false }
                }
                if omittedTurnCount > 0 {
                    let offset = min(text.count, max(0, conversationOffset ?? 0))
                    let start = text.index(text.startIndex, offsetBy: offset)
                    if offset > 0 { contentText(String(text[..<start])) }
                    Text("上下文已满 · 本通前 \(omittedTurnCount) 轮未放入这次请求")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    contentText(String(text[start...]))
                } else {
                    contentText(text)
                }
            }
            .onChange(of: text) { didCopy = false }
        }
    }

    private func contentText(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.primary)
            .lineSpacing(3).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension RequestLogEntry {
    var isModel: Bool { category == .chat || category == .summary }

    var title: String {
        if step == .summary, category == .connection { return String(localized: "回传通话摘要") }
        return category == .connection ? (step == .model ? String(localized: "提交对话") : step.displayName) : category.title
    }

    var identity: String {
        let provider = service == .openAI ? String(localized: "OpenAI 兼容") : String(localized: String.LocalizationValue(service.rawValue))
        var parts = [provider]
        for value in [displayModelName, displayConnectionName] {
            if let name = value?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty, name != title, !parts.contains(name) {
                parts.append(name)
            }
        }
        if provider == title || displayConnectionName?.localizedStandardContains(provider) == true {
            parts.removeFirst()
        }
        return parts.joined(separator: " · ")
    }

    var metadata: String {
        let date = Calendar.current.isDateInToday(time)
            ? time.formatted(.dateTime.hour().minute().second())
            : time.formatted(.dateTime.year().month().day().hour().minute().second())
        var parts = [date]
        if let duration { parts.append(String(format: String(localized: "%.2f 秒"), duration)) }
        if let httpStatus { parts.append("HTTP \(httpStatus)") }
        if let errorCode, outcome == .failed { parts.append(errorCode) }
        return parts.joined(separator: " · ")
    }

    var outputTitle: String {
        switch category {
        case .stt: String(localized: "识别结果")
        case .tts: String(localized: "合成结果")
        case .chat, .summary: String(localized: "输出")
        default: String(localized: "结果")
        }
    }

    var failureReason: String {
        switch httpStatus ?? 0 {
        case 400: return String(localized: "请求参数不合适，请检查连接设置")
        case 401, 403: return String(localized: "密钥无效或没有权限")
        case 404: return String(localized: "地址或模型名不对")
        case 429: return String(localized: "请求太频繁或额度用完了")
        case 500...599: return String(localized: "服务商暂时不可用")
        default:
            switch errorCode {
            case "network_-1001", "timeout": return String(localized: "网络超时")
            case "network_-1009": return String(localized: "没有网络")
            case "network_-1003", "network_-1004": return String(localized: "连不上服务器")
            case "process_ended": return String(localized: "App 上次结束时请求尚未完成")
            case "InvalidApiKey", "Unauthorized", "Forbidden", "unauthorized", "forbidden", "invalid_api_key":
                return String(localized: "密钥无效或没有权限")
            case "rate_limit_exceeded", "quota_exceeded", "insufficient_quota", "Throttling":
                return String(localized: "请求太频繁或额度用完了")
            case "voice_not_found": return String(localized: "找不到配置的声音，请检查 Voice ID")
            case "invalid_response": return String(localized: "无法读取服务商返回的内容")
            default: return String(localized: "请求失败")
            }
        }
    }

    var statusText: String {
        switch outcome {
        case .pending: String(localized: "请求中")
        case .succeeded: String(localized: "成功")
        case .failed: String(localized: "失败")
        case .cancelled: errorCode == "call_hang_up" ? String(localized: "挂断时中止") : String(localized: "已取消")
        }
    }
}
