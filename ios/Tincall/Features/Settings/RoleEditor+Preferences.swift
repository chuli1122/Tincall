// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import Contacts
import ContactsUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

extension RoleEditor {
    var promptCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(role.systemPrompt.count) 字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { isImportingPrompt = true } label: {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(.tint)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("导入文本文件")
                Button { isShowingPromptEditor = true } label: {
                    Image(systemName: "arrow.down.left.and.arrow.up.right")
                        .foregroundStyle(.tint)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("展开编辑对话设定")
            }
            .buttonStyle(.plain)
            promptInput.frame(height: 180)
        }
        .padding(12)
        .background(Color.settingsSurface(), in: RoundedRectangle(cornerRadius: 4))
    }

    var promptInput: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $role.systemPrompt)
                .font(.subheadline)
                .scrollContentBackground(.hidden)
                .scrollEdgeEffectHidden(!isShowingPromptEditor, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectHidden(true, for: .bottom)
                .accessibilityLabel("对话设定")
            if role.systemPrompt.isEmpty {
                Text("填写对方的设定、你的信息、双方关系和对话要求……")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
    }

    func importPrompt(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let limit = 1_048_576
            let data = try file.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { throw TincallError(message: String(localized: "请选择不超过 1 MB 的文本文件。")) }
            guard let text = String(data: data, encoding: .utf8) else {
                throw TincallError(message: String(localized: "请选择 UTF-8 编码的 TXT 或 Markdown 文件。"))
            }
            role.systemPrompt = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            errorMessage = nil
        } catch {
            if (error as NSError).code == CocoaError.userCancelled.rawValue { return }
            errorMessage = String(localized: "提示词未导入：\(error.localizedDescription)")
        }
    }

    var voiceCard: some View {
        card {
            HStack {
                Text("TA的声音")
                Spacer()
                Menu {
                    Picker(String(localized: "TA的声音"), selection: Binding(get: { role.ttsConnectionID }, set: { id in
                        guard id != role.ttsConnectionID else { return }
                        role.ttsConnectionID = id
                        role.voiceID = ""
                    })) {
                        Text("请选择预设").tag(nil as UUID?)
                        ForEach(store.connections.filter { $0.provider.isSpeechSynthesis }) { Text($0.name).tag(Optional($0.id)) }
                    }
                } label: {
                    presetMenuLabel(store.connections.first(where: { $0.id == role.ttsConnectionID })?.name ?? String(localized: "请选择预设"))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("TA的声音")
                .accessibilityValue(store.connections.first(where: { $0.id == role.ttsConnectionID })?.name ?? String(localized: "请选择预设"))
            }
        }
    }

    func presetMenuLabel(_ name: String) -> some View {
        SettingsSelectionLabel(value: name)
        .frame(minHeight: 31)
        .contentShape(Rectangle())
    }

    var backgroundAndSummaryCard: some View {
        card {
            HStack {
                Text("通话背景")
                Spacer()
                Menu {
                    Button {
                        selectedBackground = nil
                        isLoadingBackground = false
                        role.callBackgroundData = nil
                    } label: {
                        Label("跟随主题默认", systemImage: role.callBackgroundData == nil ? "checkmark" : "paintpalette")
                    }
                    Button("从相册选择", systemImage: "photo") { isShowingBackgroundPicker = true }
                } label: {
                    HStack(spacing: 6) {
                        Group {
                            if let data = role.callBackgroundData, let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                Image(systemName: "photo").foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 48, height: 36)
                        .background(Color.primary.opacity(0.04))
                        .clipped()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(role.callBackgroundData == nil ? String(localized: "选择通话背景") : String(localized: "更换通话背景"))
                .photosPicker(isPresented: $isShowingBackgroundPicker, selection: $selectedBackground, matching: .images)
            }
            if isLoadingBackground { ProgressView("正在处理通话背景…") }
            Divider()
            HStack(spacing: 6) {
                Text("通话摘要模型")
                if role.summaryConnectionID != nil {
                    NavigationLink {
                        RoleSummarySettings(role: role, isExisting: store.roles.contains(where: { $0.id == role.id }),
                                            connection: store.connections.first { $0.id == role.summaryConnectionID },
                                            records: records?.records ?? [], userName: store.userProfile.name,
                                            hasUnsavedModelSelection: store.roles.first(where: { $0.id == role.id }).map { $0.summaryConnectionID != role.summaryConnectionID } ?? false,
                                            onSave: saveSummaryPreferences)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 32, height: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("摘要提示词与长度")
                }
                Spacer(minLength: 0)
                Menu {
                    Picker(String(localized: "通话摘要模型"), selection: $role.summaryConnectionID) {
                        Text("关闭").tag(nil as UUID?)
                        ForEach(store.connections.filter { $0.provider.isLanguageModel }) { Text($0.name).tag(Optional($0.id)) }
                    }
                } label: {
                    presetMenuLabel(summaryPresetName)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("通话摘要模型")
                .accessibilityValue(summaryPresetName)
            }
        }
    }

    private var summaryPresetName: String {
        guard let id = role.summaryConnectionID else { return String(localized: "关闭") }
        return store.connections.first(where: { $0.id == id })?.name ?? String(localized: "未配置")
    }

    private func saveSummaryPreferences(prompt: String, targetLength: Int?) throws {
        if var saved = store.roles.first(where: { $0.id == role.id }) {
            saved.summaryConnectionID = role.summaryConnectionID
            saved.summaryPrompt = prompt
            saved.summaryMaxCharacters = targetLength
            try store.saveRole(saved)
            savedRole.summaryConnectionID = saved.summaryConnectionID
            savedRole.summaryPrompt = saved.summaryPrompt
            savedRole.summaryMaxCharacters = saved.summaryMaxCharacters
        }
        role.summaryPrompt = prompt
        role.summaryMaxCharacters = targetLength
    }
}
