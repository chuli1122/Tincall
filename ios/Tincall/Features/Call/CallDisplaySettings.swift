// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

private struct CallTextScaleKey: EnvironmentKey {
    static let defaultValue = 1.0
}

extension EnvironmentValues {
    var callTextScale: Double {
        get { self[CallTextScaleKey.self] }
        set { self[CallTextScaleKey.self] = newValue }
    }
}

struct CallDisplaySettings: View {
    @Binding var showsCaptions: Bool
    @Binding var showsSelfAvatar: Bool
    @Binding var textScale: Double
    @Binding var backgroundMaskOpacity: Double
    let presentation: CallPresentation
    let onSwitchPresentation: () -> Void
    let speechInterruptionEnabled: Bool
    let onSetSpeechInterruptionEnabled: ((Bool) -> Void)?
    var speechRecognitionConnections: [ConnectionProfile] = []
    var speechRecognitionConnectionID: UUID? = nil
    var pendingSpeechRecognitionConnectionID: UUID? = nil
    var isSwitchingSpeechRecognition = false
    var speechRecognitionError: String? = nil
    var onSelectSpeechRecognition: ((ConnectionProfile) -> Void)? = nil
    var originalAudioInputEnabled = false
    var pendingOriginalAudioInputEnabled: Bool? = nil
    var supportsOriginalAudioInput = false
    var onSetOriginalAudioInput: ((Bool) -> Void)? = nil
    @Environment(\.callPalette) private var palette
    @AppStorage(CaptionFontStore.selectionKey) private var captionFontName = ""
    @AppStorage("call.voiceMessageSentSound") private var voiceMessageSentSound = true
    @State private var fonts = CaptionFontStore.shared
    private var usesOriginalAudio: Bool { pendingOriginalAudioInputEnabled ?? originalAudioInputEnabled }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("语音消息发送音效", isOn: $voiceMessageSentSound)
                    Toggle("允许说话打断", isOn: Binding(
                        get: { speechInterruptionEnabled },
                        set: { onSetSpeechInterruptionEnabled?($0) }))
                        .disabled(onSetSpeechInterruptionEnabled == nil)
                } header: {
                    Text("通话")
                } footer: {
                    Text("开启说话打断后，对方回复期间仍保持收音。检测到持续约 0.3 秒的人声并识别出文字时，将中断当前回复。")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                }
                .listRowBackground(palette.primaryText.opacity(0.04))

                if !speechRecognitionConnections.isEmpty {
                    Section {
                        CallSettingsMenuRow(title: String(localized: "识别服务"),
                            options: usesOriginalAudio
                                ? [(id: (pendingSpeechRecognitionConnectionID ?? speechRecognitionConnectionID)?.uuidString ?? "",
                                    title: String(localized: "Apple 本机识别"))]
                                : speechRecognitionConnections.map { (id: $0.id.uuidString, title: $0.name) },
                            selection: Binding(
                                get: { (pendingSpeechRecognitionConnectionID ?? speechRecognitionConnectionID)?.uuidString ?? "" },
                                set: { id in
                                    if let connection = speechRecognitionConnections.first(where: { $0.id.uuidString == id }) {
                                        onSelectSpeechRecognition?(connection)
                                    }
                                }))
                            .disabled(isSwitchingSpeechRecognition || usesOriginalAudio || onSelectSpeechRecognition == nil)
                        CallSettingsMenuRow(title: String(localized: "发送内容"),
                            options: [(id: "text", title: String(localized: "识别文字")),
                                      (id: "audio", title: String(localized: "原声输入"))],
                            selection: Binding(get: { usesOriginalAudio ? "audio" : "text" },
                                               set: { onSetOriginalAudioInput?($0 == "audio") }),
                            disabledIDs: supportsOriginalAudioInput ? [] : ["audio"])
                            .disabled(isSwitchingSpeechRecognition || onSetOriginalAudioInput == nil)
                        if isSwitchingSpeechRecognition {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在切换识别服务…")
                            }.font(.footnote).foregroundStyle(palette.secondaryText)
                        } else if pendingSpeechRecognitionConnectionID != nil {
                            Text("本句识别结束后切换")
                                .font(.footnote).foregroundStyle(palette.secondaryText)
                        }
                        if let speechRecognitionError {
                            Text(speechRecognitionError).font(.footnote).foregroundStyle(.red)
                        }
                    } header: {
                        Text("语音输入")
                    } footer: {
                        if usesOriginalAudio {
                            Text("请确认所选模型及连接服务支持音频输入。本机识别用于字幕和文字记录；本轮发送原声，历史使用识别文字。发送录音不等于保存录音，仅对本次通话生效。")
                        } else {
                            Text("识别服务切换成功后会保存为默认设置，后续通话继续使用，不影响对方语音播放。原声输入支持 Gemini 和 OpenAI 兼容模型直连。")
                        }
                    }
                    .listRowBackground(palette.primaryText.opacity(0.04))
                }
                Section {
                    Button(action: onSwitchPresentation) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(presentation == .voice ? String(localized: "切换到文字视图") : String(localized: "切换到通话视图"))
                                Text("也可左右滑动通话内容切换")
                                    .font(.caption)
                                    .foregroundStyle(palette.secondaryText)
                                    .accessibilityHidden(true)
                            }
                            Spacer()
                            Image(systemName: presentation == .voice ? "text.bubble" : "phone")
                        }
                    }
                    .accessibilityHint("可左右滑动内容区域切换视图")
                    Toggle("显示我的头像", isOn: $showsSelfAvatar)
                    Toggle("通话字幕", isOn: $showsCaptions)
                } header: {
                    Text("显示")
                }
                .listRowBackground(palette.primaryText.opacity(0.04))

                Section {
                    CallSettingsMenuRow(title: String(localized: "通话字体"),
                        options: [(id: "", title: String(localized: "系统默认"))]
                            + fonts.fonts.map { (id: $0.id, title: $0.title) },
                        selection: $captionFontName)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("文字大小")
                            Spacer()
                            Text(textScale, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().foregroundStyle(palette.secondaryText)
                        }
                        Slider(value: Binding(
                            get: { textScale * 100 },
                            set: { textScale = $0 / 100 }
                        ), in: 90...115, step: 1) {
                            Text("文字大小")
                        } minimumValueLabel: {
                            Text("小").font(.caption)
                        } maximumValueLabel: {
                            Text("大").font(.caption)
                        }
                        .accessibilityValue(textScale.formatted(.percent.precision(.fractionLength(0))))
                        Text("慢慢说，我在听。")
                            .font(Font(fonts.font(named: captionFontName, size: 15 * textScale)))
                            .foregroundStyle(palette.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("字体用于通话字幕、文字视图正文和输入框；可在设置 → 显示与字体中导入。")
                        .foregroundStyle(palette.secondaryText)
                }
                .listRowBackground(palette.primaryText.opacity(0.04))

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("背景蒙版")
                            Spacer()
                            Text(backgroundMaskOpacity, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().foregroundStyle(palette.secondaryText)
                        }
                        Slider(value: Binding(
                            get: { backgroundMaskOpacity },
                            set: { backgroundMaskOpacity = ($0 * 100).rounded() / 100 }
                        ), in: 0...0.6) {
                            Text("背景蒙版")
                        }
                        .accessibilityValue(backgroundMaskOpacity.formatted(.percent.precision(.fractionLength(0))))
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("在背景图上叠加一层随背景明暗变化的遮罩：浅色背景叠加白色，深色背景叠加深色，用于提高文字清晰度。")
                        .foregroundStyle(palette.secondaryText)
                }
                .listRowBackground(palette.primaryText.opacity(0.04))

            }
            .formStyle(.grouped)
            .listSectionSpacing(20)
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("通话内设置")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(palette.accent)
        .background { CallStatusBarStyleController(clearsPresentationBackground: true) }
        .environment(\.colorScheme, palette.colorScheme)
        .toolbarColorScheme(palette.colorScheme, for: .navigationBar)
    }
}

/// Keeps native menu hit targets aligned with the other form rows.
private struct CallSettingsMenuRow: View {
    let title: String
    let options: [(id: String, title: String)]
    @Binding var selection: String
    var disabledIDs: Set<String> = []
    @Environment(\.callPalette) private var palette

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(options.first(where: { $0.id == selection })?.title ?? "")
                .lineLimit(1)
                .foregroundStyle(palette.secondaryText)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
        }
        .foregroundStyle(palette.primaryText)
        .frame(maxWidth: .infinity, minHeight: 52)
        .padding(.horizontal, 20)
        .allowsHitTesting(false)
        .overlay {
            CallSettingsMenu(title: title, options: options, selection: $selection, disabledIDs: disabledIDs)
        }
        .listRowInsets(EdgeInsets())
    }
}

/// A single native button owns the entire row, including its padding and empty space.
private struct CallSettingsMenu: UIViewRepresentable {
    let title: String
    let options: [(id: String, title: String)]
    @Binding var selection: String
    var disabledIDs: Set<String>

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.accessibilityLabel = title
        button.isEnabled = context.environment.isEnabled
        button.accessibilityValue = options.first(where: { $0.id == selection })?.title
        // Live call updates must not replace a menu while a finger is opening it.
        let current = button.menu?.children.compactMap { $0 as? UIAction } ?? []
        guard current.map({ $0.identifier.rawValue }) != options.map(\.id)
                || current.map(\.title) != options.map(\.title)
                || current.first(where: { $0.state == .on })?.identifier.rawValue != selection
                || Set(current.filter { $0.attributes.contains(.disabled) }.map { $0.identifier.rawValue }) != disabledIDs else { return }
        button.menu = UIMenu(children: options.map { option in
            UIAction(title: option.title, identifier: UIAction.Identifier(option.id),
                     attributes: disabledIDs.contains(option.id) ? .disabled : [],
                     state: selection == option.id ? .on : .off) { _ in
                selection = option.id
            }
        })
    }
}
