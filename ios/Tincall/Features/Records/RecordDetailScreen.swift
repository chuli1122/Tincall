// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import UniformTypeIdentifiers

struct RecordDetailScreen: View {
    let recordID: UUID
    let store: CallRecordStore
    let isCallActive: Bool
    let onRequestSummary: ((UUID) -> Void)?
    let canRequestSummary: ((UUID) -> Bool)?
    let avatarData: Data?
    let onResumeCall: ((UUID) -> Void)?
    let summaryConnections: [ConnectionProfile]
    let onRequestSummaryUsing: ((UUID, UUID) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var playback = RecordPlayback()
    @State private var errorMessage: String?
    @State private var isConfirmingExport = false
    @State private var isExporting = false
    @State private var backup: CallBackupDocument?
    @State private var scrollOffset: CGFloat = 0
    @State private var didCopySummary = false
    @State private var summaryCopyReset: Task<Void, Never>?
    @State private var summaryCopyDate: Date?
    @State private var isEditingSummary = false
    @State private var summaryDraft = ""
    @State private var summaryEditError: String?
    @State private var isConfirmingDelete = false
    @State private var isChoosingSummaryModel = false
    @ScaledMetric(relativeTo: .title) private var titleFontSize = 28.0

    var body: some View {
        let navigation = navigationPresentation(recordContent)
        let export = exportPresentation(navigation)
        let deletion = deleteConfirmation(export)
        let summaryEditor = summaryEditorPresentation(deletion)
        return summaryModelPresentation(summaryEditor)
    }

    private var recordContent: some View {
        Group {
            if let record = store.records.first(where: { $0.id == recordID }) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        recordHeader(record)
                        if record.externalCallID != nil, record.endedAt == nil, let onResumeCall {
                            Button("恢复这通电话", systemImage: "arrow.clockwise") { onResumeCall(record.id) }
                                .font(.subheadline.weight(.medium))
                                .padding(.top, 20)
                                .disabled(isCallActive)
                        }
                        summary(record)
                            .padding(.top, 28)
                            .padding(.bottom, 30)
                        transcriptHeader(record)
                            .padding(.bottom, 8)
                        if isCallActive {
                            Text("通话中暂停重听，请先结束通话。")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                        }
                        if let error = errorMessage ?? playback.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.subheadline).foregroundStyle(.red)
                                .padding(.vertical, 12)
                        }
                        if record.messages.isEmpty {
                            Text("这通电话没有留下文字或图片消息。")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .padding(.vertical, 16)
                        }
                        ForEach(Array(record.messages.enumerated()), id: \.element.id) { index, message in
                            let progress = playback.currentMessageID == message.id ? playback.progress : 0
                            HStack(alignment: .top, spacing: 14) {
                                Text(String(format: "%02d", index + 1))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 18, alignment: .leading)
                                    .padding(.top, 17)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 8) {
                                    messageRow(message, record: record)
                                    if message.status == .failed {
                                        Text("本条回复失败，已保留收到的文字")
                                            .font(.caption2).foregroundStyle(.secondary)
                                            .padding(.bottom, 12)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.06))
                                    .scaleEffect(x: min(1, max(0, progress)), y: 1, anchor: .leading)
                                    .animation(playback.currentMessageID == message.id && playback.isPlaying ? .linear(duration: 0.1) : nil,
                                               value: progress)
                                    .allowsHitTesting(false)
                            }
                            rule(opacity: 0.12)
                        }
                        Button("删除本次通话记录", role: .destructive) { isConfirmingDelete = true }
                            .font(.footnote)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.top, 24)
                            .disabled(isCallActive || record.summaryStatus == .pending || record.summaryStatus == .generating || record.externalPendingControl != nil || record.externalPendingInput != nil)
                        NavigationLink {
                            RequestLogScreen(callID: record.id)
                        } label: {
                            Text("查看请求日志")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                    .font(.callout)
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, geometry.contentOffset.y + geometry.contentInsets.top)
                } action: { _, offset in
                    scrollOffset = offset
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .navigationTitle("Call notes")
                .navigationBarTitleDisplayMode(.inline)
                .task(id: record.audioAssets) {
                    do {
                        try await playback.prepare(audioClips(record))
                    } catch is CancellationError {
                        return
                    } catch {
                        errorMessage = String(localized: "保存的音频未能读取，请检查文件是否完整。")
                    }
                }
                .onChange(of: record.summary) { resetCopyFeedback() }
            } else {
                ContentUnavailableView("记录不存在", systemImage: "phone")
            }
        }
    }

    private func navigationPresentation<Content: View>(_ content: Content) -> some View {
        content
        .background {
            Color(.systemBackground).ignoresSafeArea()
        }
        .preference(key: RecordDetailVisibilityKey.self, value: true)
        .preference(key: CopySuccessPreferenceKey.self, value: summaryCopyDate)
        .modifier(CopySuccessFeedback())
        .tint(.accentColor)
        .onChange(of: isCallActive) { if isCallActive { playback.stop() } }
        .onDisappear {
            playback.stop()
            resetCopyFeedback()
        }
        .navigationBarBackButtonHidden()
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .principal) {
                Text("CALL NOTES")
                    .font(.system(size: 11, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                    .opacity(1 - min(1, scrollOffset / 60))
                    .accessibilityHidden(scrollOffset >= 60)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { isConfirmingExport = true } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("导出通话备份")
                .disabled(isCallActive)
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    private func exportPresentation<Content: View>(_ content: Content) -> some View {
        content
        .alert("导出通话备份", isPresented: $isConfirmingExport) {
            Button("选择位置并导出文件夹") {
                do {
                    let exported = try store.exportRecord(recordID)
                    backup = CallBackupDocument(manifest: exported.manifest, media: exported.media)
                    isExporting = true
                } catch { errorMessage = String(localized: "导出失败：\(error.localizedDescription)") }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(store.records.first(where: { $0.id == recordID })?.audioAssets.isEmpty == false
                 ? String(localized: "备份文件夹包含本次通话的聊天记录、摘要和已保存的音频。")
                 : String(localized: "备份文件夹包含本次通话的聊天记录和摘要。"))
        }
        .fileExporter(isPresented: $isExporting, document: backup, contentType: .folder, defaultFilename: "Tincall-\(recordID.uuidString)") { result in
            if case .failure(let error) = result { errorMessage = String(localized: "导出失败：\(error.localizedDescription)") }
            backup = nil
        }
    }

    private func deleteConfirmation<Content: View>(_ content: Content) -> some View {
        content
        .alert("删除这通电话？", isPresented: $isConfirmingDelete) {
            Button("删除", role: .destructive) {
                playback.stop()
                do { try store.delete(recordID: recordID); dismiss() }
                catch { errorMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("本机的文字、摘要和已保存音频会一起删除。已导出的备份与云端副本不受影响。") }
    }

    private func summaryEditorPresentation<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $isEditingSummary) {
            NavigationStack {
                Form {
                    Section("通话摘要") {
                        TextEditor(text: $summaryDraft).frame(minHeight: 240)
                    }
                    if let summaryEditError { Text(summaryEditError).foregroundStyle(.red) }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .navigationTitle("编辑摘要")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { isEditingSummary = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do {
                                try store.updateSummary(recordID: recordID, status: .completed, text: summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                                isEditingSummary = false
                            } catch { summaryEditError = error.localizedDescription }
                        }
                    }
                }
            }
        }
    }

    private func summaryModelPresentation<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $isChoosingSummaryModel) {
            NavigationStack {
                List {
                    Section {
                        ForEach(summaryConnections.filter { $0.provider.isLanguageModel }) { connection in
                            Button(connection.name) {
                                guard let record = store.records.first(where: { $0.id == recordID }),
                                      record.isFinished, hasSummaryContent(record),
                                      record.summaryStatus != .pending, record.summaryStatus != .generating else { return }
                                isChoosingSummaryModel = false
                                onRequestSummaryUsing?(recordID, connection.id)
                            }
                            .disabled(onRequestSummaryUsing == nil)
                        }
                        if !summaryConnections.contains(where: { $0.provider.isLanguageModel }) {
                            Text("还没有聊天模型预设，请先在设置 → API 设置中添加。")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("仅用于本次摘要，不会开启此联系人的自动摘要或更改默认模型。")
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .navigationTitle("选择摘要模型")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { isChoosingSummaryModel = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func recordHeader(_ record: CallRecord) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 22) {
                CallIdentityPortrait(name: record.roleName, data: avatarData, size: 66)
                    .padding(4)
                VStack(alignment: .leading, spacing: 8) {
                    Text("和 TA 的这通电话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(record.roleName)
                        .font(.system(size: titleFontSize, weight: .bold))
                        .tracking(-0.6)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    recordDate(record)
                    if record.endedAbnormally != true { Spacer(minLength: 12) }
                    recordDuration(record)
                }
                VStack(alignment: .leading, spacing: 6) {
                    recordDate(record)
                    recordDuration(record)
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            if record.endedAbnormally == true {
                Text("异常中断，已保留保存的通话内容。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func recordDate(_ record: CallRecord) -> some View {
        Text(record.startedAt, format: .dateTime.year().month().day().hour().minute())
    }

    @ViewBuilder
    private func recordDuration(_ record: CallRecord) -> some View {
        if record.endedAbnormally == true {
            HStack(spacing: 6) {
                Text("·")
                Text("异常中断")
            }
        } else {
            callDuration(record)
        }
    }

    private func transcriptHeader(_ record: CallRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("THE CONVERSATION")
                .font(.system(size: 9, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("对话记录").font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(String(format: "%02d", record.messages.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !record.audioAssets.isEmpty {
                    Button {
                        playback.toggle()
                    } label: {
                        Label(playback.isPlayingAll ? (playback.isPlaying ? String(localized: "暂停重听") : String(localized: "继续重听")) : String(localized: "重听全部"),
                              systemImage: playback.isPlayingAll && playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCallActive || playback.durations.isEmpty)
                }
            }
        }
    }

    private func rule(opacity: Double = 1) -> some View {
        Rectangle().fill(Color.primary.opacity(opacity)).frame(height: opacity == 1 ? 1 : 0.75)
            .accessibilityHidden(true)
    }

    private func audioClips(_ record: CallRecord) throws -> [RecordPlayback.Clip] {
        try record.messages.flatMap { message in
            try record.audioAssets.filter { $0.messageID == message.id }
                .sorted { $0.segmentIndex < $1.segmentIndex }
                .map {
                    RecordPlayback.Clip(messageID: message.id, url: try store.audioURL($0, recordID: record.id), duration: $0.duration)
                }
        }
    }

    private func messageRow(_ message: CallMessage, record: CallRecord) -> some View {
        let onToggle: (() -> Void)? = !isCallActive && playback.durations[message.id] != nil
            ? { playback.toggle(messageID: message.id) } : nil
        return CallTranscriptRow(speaker: message.role == .user ? String(localized: "我") : record.roleName,
                                 text: message.recordedText, isOutgoing: message.role == .user,
                                 isStreaming: message.status == .generating,
                                 textFont: .callout, detailFont: .caption2,
                                 isRecordStyle: true,
                                 timestamp: message.createdAt,
                                 audioDuration: playback.durations[message.id],
                                 playbackProgress: playback.currentMessageID == message.id ? playback.progress : 0,
                                 isAudioPlaying: playback.currentMessageID == message.id && playback.isPlaying,
                                 onToggleAudio: onToggle,
                                 images: message.images ?? [],
                                 imageURL: { try store.imageURL($0, recordID: record.id, messageID: message.id) })
    }

    private func summary(_ record: CallRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.65))
                        .frame(width: 24, height: 3)
                        .accessibilityHidden(true)
                    Text(summaryTitle(record.summaryStatus)).font(.headline)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 8)
                if record.summary.isEmpty {
                    summaryButton(record)
                } else if record.summaryStatus != .pending && record.summaryStatus != .generating {
                    Button {
                        summaryDraft = record.summary
                        summaryEditError = nil
                        isEditingSummary = true
                    } label: { Image(systemName: "square.and.pencil").frame(width: 32, height: 44) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("编辑摘要")
                        .disabled(isCallActive)
                }
                if !record.summary.isEmpty {
                    Button {
                        summaryCopyReset?.cancel()
                        UIPasteboard.general.string = record.summary
                        didCopySummary = true
                        summaryCopyDate = Date()
                        summaryCopyReset = Task { @MainActor in
                            do { try await Task.sleep(for: .seconds(3)) }
                            catch { return }
                            guard !Task.isCancelled else { return }
                            didCopySummary = false
                            summaryCopyReset = nil
                        }
                    } label: {
                        Group {
                            if didCopySummary {
                                Image(systemName: "checkmark").font(.callout)
                            } else {
                                Image(systemName: "doc.on.doc").font(.callout)
                            }
                        }
                        .frame(width: 32, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(didCopySummary ? String(localized: "摘要已复制") : String(localized: "复制摘要"))
                }
            }
            if !record.summary.isEmpty {
                Text(record.summary).lineSpacing(6).textSelection(.enabled)
            } else if !hasSummaryContent(record) {
                Text("没有可供生成摘要的通话内容。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !record.summary.isEmpty { summaryButton(record) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
    }

    private func summaryButton(_ record: CallRecord) -> some View {
        Button {
            if canRequestSummary?(record.id) != false, let onRequestSummary {
                onRequestSummary(record.id)
            } else {
                isChoosingSummaryModel = true
            }
        } label: {
            HStack(spacing: 6) {
                if record.summaryStatus == .pending || record.summaryStatus == .generating {
                    ProgressView().controlSize(.small)
                }
                Text(record.summary.isEmpty ? String(localized: "补生成摘要") : String(localized: "重新生成摘要"))
            }
            .font(.caption.weight(.medium))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .disabled(!hasSummaryContent(record) || !record.isFinished ||
                  record.summaryStatus == .pending || record.summaryStatus == .generating ||
                  (onRequestSummary == nil && onRequestSummaryUsing == nil))
    }

    private func hasSummaryContent(_ record: CallRecord) -> Bool {
        record.messages.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.images?.isEmpty == false }
    }

    private func resetCopyFeedback() {
        summaryCopyReset?.cancel()
        summaryCopyReset = nil
        didCopySummary = false
    }

    private func summaryTitle(_ status: SummaryStatus) -> String {
        switch status {
        case .notRequested: String(localized: "未生成摘要")
        case .pending: String(localized: "摘要待生成")
        case .generating: String(localized: "摘要生成中")
        case .completed: String(localized: "通话摘要")
        case .failed: String(localized: "摘要失败，原记录已保留")
        }
    }
}
