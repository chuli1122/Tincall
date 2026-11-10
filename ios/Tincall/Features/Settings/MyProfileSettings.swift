// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import AVFoundation
import PhotosUI
import SwiftUI

struct MyProfileSettings: View {
    @Environment(\.scenePhase) private var scenePhase
    let store: LocalConfigurationStore
    let isCallActive: Bool
    let onSaveConnection: (ConnectionProfile, String?, String?) throws -> Void
    let onDeleteConnection: (UUID) throws -> Void
    @State private var profile: LocalUserProfile
    @State private var savedProfile: LocalUserProfile
    @State private var photo: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    @State private var errorMessage: String?
    @State private var actionConfirmed = false
    @State private var actionFeedbackTrigger = 0
    @State private var confirmationToken = UUID()
    @State private var speechTest = SpeechConnectionProbe()

    init(store: LocalConfigurationStore, isCallActive: Bool,
         onSaveConnection: @escaping (ConnectionProfile, String?, String?) throws -> Void,
         onDeleteConnection: @escaping (UUID) throws -> Void) {
        self.store = store
        self.isCallActive = isCallActive
        self.onSaveConnection = onSaveConnection
        self.onDeleteConnection = onDeleteConnection
        _profile = State(initialValue: store.userProfile)
        _savedProfile = State(initialValue: store.userProfile)
    }

    var body: some View {
        SettingsList {
            Section {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 9) {
                        PhotosPicker(selection: $photo, matching: .images) {
                            CallIdentityPortrait(name: profile.name, data: profile.avatarData, size: 64)
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 10, weight: .medium))
                                        .frame(width: 23, height: 23)
                                        .background(Color(.systemBackground), in: Circle())
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.75))
                                        .offset(x: 6, y: 6)
                                }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(profile.avatarData == nil ? String(localized: "选择头像") : String(localized: "更换头像"))
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Text("我的名字").font(.caption).foregroundStyle(.secondary)
                        SettingsTextField(placeholder: String(localized: "我"), text: $profile.name, textStyle: .title3, weight: .medium)
                            .accessibilityLabel("我的名字")
                            .padding(.bottom, 9)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Color.primary.opacity(0.22)).frame(height: 0.75)
                            }
                        Text("在所有通话中使用")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 14)
                .listRowSeparator(.hidden)
                if isLoadingPhoto {
                    ProgressView("正在处理图片").font(.caption)
                }
            } header: {
                SettingsSectionHeading(number: "01", title: String(localized: "显示资料"), caption: "PROFILE")
            }
            speechRecognitionSection
        }
        .modifier(SettingsPageStyle(title: String(localized: "我的设置"), subtitle: String(localized: "头像、名字与语音识别"), symbol: "person.wave.2", index: "FOR YOU",
                                   actionTitle: String(localized: "保存"), actionSymbol: "checkmark",
                                   actionDisabled: isLoadingPhoto || !hasUnsavedChanges,
                                   actionConfirmed: actionConfirmed, actionFeedbackTrigger: actionFeedbackTrigger,
                                   onAction: { _ = save() },
                                   dismissDisabled: isLoadingPhoto,
                                   hasUnsavedChanges: hasUnsavedChanges,
                                   onSaveBeforeDismiss: { completion in if save() { completion() } }))
        .alert("未能保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .task(id: photo) {
            guard let selection = photo else { isLoadingPhoto = false; return }
            isLoadingPhoto = true
            defer { if photo == selection { isLoadingPhoto = false } }
            do {
                guard let data = try await selection.loadTransferable(type: Data.self) else {
                    throw TincallError(message: String(localized: "未能读取图片，请重试。"))
                }
                let thumbnail = try makeSettingsImageThumbnail(data, maxPixelSize: 512)
                try Task.checkCancellation()
                guard photo == selection else { return }
                profile.avatarData = thumbnail
                errorMessage = nil
            } catch is CancellationError { }
            catch { if photo == selection { errorMessage = error.localizedDescription } }
        }
    }

    private var speechRecognitionSection: some View {
        let current = store.connections.first { $0.id == store.defaultSTTConnectionID }
        return Section {
            SettingsPickerRow(title: String(localized: "识别服务"), value: current?.provider.settingsDisplayName ?? String(localized: "未配置"), selection: Binding(get: { current?.provider }, set: { provider in
                do { try store.selectSTTProvider(provider) }
                catch { errorMessage = error.localizedDescription }
            })) {
                Text("未配置").tag(nil as ConnectionProvider?)
                Text("Apple 本机识别").tag(Optional(ConnectionProvider.appleSpeech))
                Text("讯飞").tag(Optional(ConnectionProvider.xunfei))
                Text("百炼").tag(Optional(ConnectionProvider.bailian))
                Text("Whisper 兼容").tag(Optional(ConnectionProvider.whisperCompatible))
            }
            .disabled(isCallActive)
            if let current {
                if current.provider == .appleSpeech {
                    SettingsField(title: String(localized: "识别语言")) {
                        TextField("例如：zh-CN", text: Binding(get: { current.language ?? "zh-CN" }, set: { language in
                            var next = current
                            next.language = language
                            do { try store.saveConnection(next) }
                            catch { errorMessage = error.localizedDescription }
                        }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(isCallActive)
                    }
                    AppleSpeechReadiness(language: current.language ?? "zh-CN")
                } else {
                    NavigationLink {
                        ConnectionEditor(connection: current, isCallActive: isCallActive,
                                         onDelete: onDeleteConnection, onSave: onSaveConnection)
                    } label: {
                        SettingsActionLabel(title: String(localized: "配置\(current.provider.settingsDisplayName)"), symbol: "slider.horizontal.3",
                                            detail: String(localized: "账户凭据与识别参数"))
                    }
                    .disabled(isCallActive)
                }
            }
            NavigationLink {
                SpeechRecognitionCorrectionSettings(store: store)
            } label: {
                SettingsActionLabel(title: String(localized: "高频错词修正"), symbol: "text.badge.checkmark",
                                    detail: store.speechRecognitionCorrections.isEmpty ? String(localized: "把常识别错的词自动改回来") : String(localized: "已保存 \(store.speechRecognitionCorrections.count) 条规则"))
            }
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if speechTest.isRecording {
                        speechTest.finishRecording()
                    } else if speechTest.isRunning {
                        speechTest.cancel()
                    } else if let current {
                        speechTest.corrections = store.speechRecognitionCorrections
                        speechTest.start(connection: current, apiKey: "", apiSecret: "", isCallActive: isCallActive)
                    }
                } label: {
                    SettingsActionLabel(title: speechTest.isRecording ? String(localized: "停止录音") : speechTest.isRunning ? String(localized: "取消测试") : String(localized: "识别测试"),
                                        symbol: speechTest.isRunning ? "stop" : "mic",
                                        detail: String(localized: "录一句，看转出来的字"))
                }
                .buttonStyle(.plain)
                .disabled(isCallActive || current == nil)
                if speechTest.isRunning {
                    ProgressView(speechTest.progress).font(.caption)
                }
                if let feedback = speechTest.feedback {
                    Text(feedback.message).font(.caption)
                        .foregroundStyle(feedback.isFailure ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            SettingsSectionHeading(number: "02", title: String(localized: "语音识别"), caption: "STT")
        } footer: {
            Text(isCallActive ? String(localized: "通话结束后可更换识别服务。") : String(localized: "所有通话共用，选择后自动保存。切换服务会保留原配置。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onDisappear { speechTest.cancel(deactivateAudio: !isCallActive) }
        .onChange(of: current) { _, _ in speechTest.cancel(deactivateAudio: !isCallActive) }
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

    @discardableResult
    private func save() -> Bool {
        do {
            var next = profile
            next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if next.name.isEmpty { next.name = String(localized: "我") }
            try store.saveUserProfile(next)
            profile = next
            savedProfile = next
            showSaveConfirmation()
            return true
        }
        catch { errorMessage = error.localizedDescription; return false }
    }

    private var hasUnsavedChanges: Bool { profile != savedProfile }

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

private struct SpeechRecognitionCorrectionSettings: View {
    let store: LocalConfigurationStore
    @State private var rules: [SpeechRecognitionCorrection]
    @State private var editingRuleIDs: Set<UUID> = []
    @State private var errorMessage: String?

    init(store: LocalConfigurationStore) {
        self.store = store
        _rules = State(initialValue: store.speechRecognitionCorrections)
    }

    var body: some View {
        SettingsList {
            ForEach($rules) { $rule in
                Group {
                    if editingRuleIDs.contains(rule.id) {
                        ruleEditor($rule)
                    } else {
                        savedRuleCard(rule)
                    }
                }
                // The list has 8 pt outer padding; another 16 pt matches the header's 24 pt edge.
                .containerRelativeFrame(.horizontal) { width, _ in max(0, width - 32) }
                .frame(maxWidth: .infinity)
            }
            .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Button {
                let rule = SpeechRecognitionCorrection()
                rules.append(rule)
                editingRuleIDs.insert(rule.id)
            } label: {
                Label("添加词条", systemImage: "plus")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)

            Text("保存后自动修正通话字幕、发送文字和新记录。")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 12, trailing: 24))
                .listRowSeparator(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
        }
        .modifier(SettingsPageStyle(title: String(localized: "高频错词修正"), subtitle: String(localized: "识别结果中的名字与词语替换"), symbol: "text.badge.checkmark", index: "CORRECTIONS"))
        .alert("未能更新规则", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func savedRuleCard(_ rule: SpeechRecognitionCorrection) -> some View {
        Button { editingRuleIDs.insert(rule.id) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("识别到").font(.caption2).foregroundStyle(.secondary)
                    Text(rule.source).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 7) {
                    Text("修正为").font(.caption2).foregroundStyle(.secondary)
                    Text(rule.replacement).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 16)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("识别到\(rule.source)，修正为\(rule.replacement)")
        .accessibilityHint("轻点编辑词条")
    }

    private func ruleEditor(_ rule: Binding<SpeechRecognitionCorrection>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsField(title: String(localized: "识别到")) {
                SettingsTextField(placeholder: String(localized: "输入识别错的词"), text: rule.source, plain: true)
            }
            SettingsField(title: String(localized: "修正为")) {
                SettingsTextField(placeholder: String(localized: "输入正确的词"), text: rule.replacement, plain: true)
            }
            HStack(spacing: 20) {
                if store.speechRecognitionCorrections.contains(where: { $0.id == rule.wrappedValue.id }) {
                    Button("删除", role: .destructive) { delete(rule.wrappedValue.id) }
                        .frame(minHeight: 44)
                }
                Spacer()
                Button("取消") { cancelEditing(rule.wrappedValue.id) }
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 44)
                Button { save(rule.wrappedValue) } label: {
                    Text("保存").fontWeight(.semibold)
                        .padding(.horizontal, 18).frame(height: 34)
                        .foregroundStyle(Color(.systemBackground))
                        .background(Color.primary, in: RoundedRectangle(cornerRadius: 4))
                        .frame(minHeight: 44)
                }
            }
            .font(.caption).buttonStyle(.borderless)
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.75))
    }

    private func cancelEditing(_ id: UUID) {
        if let index = rules.firstIndex(where: { $0.id == id }),
           let saved = store.speechRecognitionCorrections.first(where: { $0.id == id }) {
            rules[index] = saved
        } else {
            rules.removeAll { $0.id == id }
        }
        editingRuleIDs.remove(id)
    }

    private func save(_ rule: SpeechRecognitionCorrection) {
        do {
            try store.saveSpeechRecognitionCorrection(rule)
            if let index = rules.firstIndex(where: { $0.id == rule.id }),
               let saved = store.speechRecognitionCorrections.first(where: { $0.id == rule.id }) {
                rules[index] = saved
            }
            editingRuleIDs.remove(rule.id)
        }
        catch { errorMessage = error.localizedDescription }
    }

    private func delete(_ id: UUID) {
        do {
            try store.deleteSpeechRecognitionCorrection(id)
            rules.removeAll { $0.id == id }
            editingRuleIDs.remove(id)
        }
        catch { errorMessage = error.localizedDescription }
    }
}
