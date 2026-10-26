// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import UIKit

struct CallPageVisibilityKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

enum CallPresentation: String, CaseIterable {
    case voice = "通话"
    case text = "文字"
}

struct CallScreen<Transcript: View>: View {
    let name: String
    let statusTitle: String
    let statusDetail: String
    let isConfigured: Bool
    let isCallActive: Bool
    let canStart: Bool
    let canSend: Bool
    let microphoneAvailable: Bool
    let isMuted: Bool
    let canInterrupt: Bool
    let errorMessage: String?
    let onRetrySaving: (() -> Void)?
    let onConfigure: (() -> Void)?
    let onStart: () -> Void
    let onToggleMute: () -> Void
    let onTextInputActiveChange: (Bool) -> Void
    let onInterrupt: () -> Void
    let onHangUp: () -> Void
    let onSend: (String) -> Bool
    var onSendImages: ((String, [Data]) -> Bool)? = nil
    var onClose: (() -> Void)? = nil
    var isSpeakerEnabled = false
    var onToggleSpeaker: (() -> Void)? = nil
    var backgroundData: Data? = nil
    var avatarData: Data? = nil
    var userAvatarData: Data? = nil
    var userDisplayName: String = String(localized: "我")
    var startedAt: Date? = nil
    var endedAt: Date? = nil
    var isCallEnded = false
    var onReconnect: (() -> Void)? = nil
    var onShowRecords: (() -> Void)? = nil
    var onPreview: (() -> Void)? = nil
    var textStatusTitle: String? = nil
    var textStatusDetail: String? = nil
    var isPreview = false
    var assistantSpeaking = false
    var userSpeaking = false
    var animatesStatus = false
    var captionText = ""
    var captionSpeaker = ""
    var awaitingSpeechTranscript = false
    var speechInterruptionEnabled = true
    var speechInterruptionAvailability: SpeechInterruptionAvailability = .unavailable
    var onSetSpeechInterruptionEnabled: ((Bool) -> Void)? = nil
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
    @Binding var draft: String
    @ViewBuilder let transcript: () -> Transcript

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentation = CallPresentation.voice
    @AppStorage("call.showsSelfAvatar") private var showsSelfAvatar = false
    @AppStorage("call.showsCaptions") private var showsCaptions = true
    @AppStorage("call.textScale") private var textScale = 1.0
    @AppStorage(CaptionFontStore.selectionKey) private var captionFontName = ""
    @State private var captionFonts = CaptionFontStore.shared
    @AppStorage("call.backgroundMaskOpacity") private var backgroundMaskOpacity = 0.08
    @State private var backgroundAppearance = CallBackgroundAppearance(data: nil)
    @State private var showsOptions = false
    #if DEBUG
    @State private var previewSettingsDetent: PresentationDetent = .medium
    #endif
    @State private var pendingAction: (() -> Void)?
    @State private var muteFeedback = 0
    @State private var speakerFeedback = 0
    @State private var interruptFeedback = 0
    @State private var composerState = CallTextComposer.State()
    @FocusState private var inputFocused: Bool

    var body: some View {
        // Observe transcript data while the avatar view is visible too.
        let transcriptContent = transcript()
        VStack(spacing: 0) {
            if isAwaitingConfiguration { configurationPrompt }
            Group {
                if presentation == .voice {
                    voiceContent
                        .id(reduceMotion ? "voice-\(showsSelfAvatar)-\(showsCaptions)" : "voice")
                        .animation(displayAnimation, value: showsSelfAvatar)
                        .animation(displayAnimation, value: showsCaptions)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 0) {
                        transcriptContent
                            .environment(\.callTextScale, textScale)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture().onEnded { collapseComposer() })
                    }
                    .transition(.asymmetric(insertion: .opacity, removal: reduceMotion
                        ? .opacity : .opacity.combined(with: .offset(x: 32))))
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(presentationSwipe)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .top, spacing: 0) {
            GlassEffectContainer(spacing: 6) { topBar }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlassEffectContainer(spacing: 6) { bottomControls }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: presentation)
        .background { CallBackgroundView(image: backgroundAppearance.image, maskOpacity: backgroundMaskOpacity) }
        .background { CallStatusBarStyleController() }
        .foregroundStyle(palette.primaryText)
        .environment(\.callPalette, palette)
        .environment(\.colorScheme, palette.colorScheme)
        .toolbarColorScheme(palette.colorScheme, for: .navigationBar)
        .tint(palette.primaryText)
        .onChange(of: backgroundData, initial: true) {
            backgroundAppearance = CallBackgroundAppearance(data: backgroundData)
        }
        .preference(key: CallPageVisibilityKey.self, value: true)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.impact(weight: .light), trigger: muteFeedback)
        .sensoryFeedback(.impact(weight: .light), trigger: speakerFeedback)
        .sensoryFeedback(.impact(weight: .medium), trigger: interruptFeedback)
        .task(id: CallTextInputRequest.shared.startedAt) {
            guard !isPreview, isCallActive, let requestedAt = CallTextInputRequest.shared.startedAt,
                  requestedAt == startedAt else { return }
            CallTextInputRequest.shared.startedAt = nil
            if showsOptions {
                openAfterOptions(openTextComposer)
            } else {
                openTextComposer()
            }
        }
        .task(id: CallTextInputRequest.shared.previewRequestedAt) {
            guard isPreview, let requestedAt = CallTextInputRequest.shared.previewRequestedAt,
                  requestedAt == startedAt else { return }
            CallTextInputRequest.shared.previewRequestedAt = nil
            guard isCallActive else { return }
            if showsOptions {
                openAfterOptions(openTextComposer)
            } else {
                openTextComposer()
            }
        }
        .onChange(of: isCallActive) {
            inputFocused = false
            if isCallActive, !isPreview { presentation = .voice }
        }
        .onChange(of: microphoneAvailable) { if !microphoneAvailable { inputFocused = false } }
        .onChange(of: isCallEnded) {
            if isCallEnded {
                pendingAction = nil
                showsOptions = false
            }
        }
        .onChange(of: inputFocused) {
            composerState.focusChanged(inputFocused)
            onTextInputActiveChange(inputFocused && isCallActive)
        }
        .onDisappear { onTextInputActiveChange(false) }
        .onChange(of: presentation) { inputFocused = false }
        #if DEBUG
        .task {
            guard isPreview else { return }
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-TincallPreviewSettingsLarge") {
                previewSettingsDetent = .medium
                showsOptions = true
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                withAnimation { previewSettingsDetent = .large }
            } else if arguments.contains("-TincallPreviewSettingsMedium") {
                previewSettingsDetent = .medium
                showsOptions = true
            }
        }
        #endif
        .sheet(isPresented: $showsOptions, onDismiss: {
            let action = pendingAction
            pendingAction = nil
            action?()
        }) {
            CallDisplaySettings(showsCaptions: $showsCaptions, showsSelfAvatar: $showsSelfAvatar, textScale: $textScale,
                backgroundMaskOpacity: $backgroundMaskOpacity,
                presentation: presentation,
                onSwitchPresentation: {
                    showsOptions = false
                    changePresentation(presentation == .voice ? .text : .voice)
                },
                speechInterruptionEnabled: speechInterruptionEnabled,
                onSetSpeechInterruptionEnabled: onSetSpeechInterruptionEnabled,
                speechRecognitionConnections: speechRecognitionConnections,
                speechRecognitionConnectionID: speechRecognitionConnectionID,
                pendingSpeechRecognitionConnectionID: pendingSpeechRecognitionConnectionID,
                isSwitchingSpeechRecognition: isSwitchingSpeechRecognition,
                speechRecognitionError: speechRecognitionError,
                onSelectSpeechRecognition: onSelectSpeechRecognition,
                originalAudioInputEnabled: originalAudioInputEnabled,
                pendingOriginalAudioInputEnabled: pendingOriginalAudioInputEnabled,
                supportsOriginalAudioInput: supportsOriginalAudioInput,
                onSetOriginalAudioInput: onSetOriginalAudioInput)
                #if DEBUG
                .presentationDetents([.medium, .large], selection: $previewSettingsDetent)
                #else
                .presentationDetents([.medium, .large])
                #endif
                .environment(\.callPalette, palette)
                .preferredColorScheme(palette.colorScheme)
                .presentationBackground {
                    Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
                }
                .presentationDragIndicator(.visible)
        }
    }

    private var displayName: String { name.isEmpty ? "Tincall" : name }
    private var isAwaitingConfiguration: Bool { !isCallActive && !isCallEnded && !isConfigured }
    private var palette: CallPalette { backgroundAppearance.palette }
    private var displayAnimation: Animation { .easeInOut(duration: 0.3) }
    private var avatarTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity)
    }

    private var topBar: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Button { inputFocused = false; close() } label: {
                    Image(systemName: "chevron.down").frame(width: 44, height: 44)
                        .modifier(CallControlSurface(tint: nil))
                }
                .accessibilityLabel(isCallActive ? String(localized: "收起通话页面") : String(localized: "返回"))
                HStack(spacing: -14) {
                    if presentation == .text {
                        CallRoundPortrait(name: displayName, data: avatarData, color: CallNight.lavender,
                                          size: 58, isSpeaking: false)
                            .fixedSize()
                            .zIndex(0)
                    }
                    if presentation == .text, showsSelfAvatar {
                        CallRoundPortrait(name: userDisplayName, data: userAvatarData, color: CallNight.rose,
                                          size: 58, isSpeaking: false)
                            .fixedSize()
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95, anchor: .center)))
                            .zIndex(1)
                    } else if presentation == .voice {
                        Text(displayName).font(CallNight.font(18, weight: .semibold)).lineLimit(1)
                            .frame(height: 44)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 58, alignment: .top)
                Button { inputFocused = false; showsOptions = true } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        .modifier(CallControlSurface(tint: nil))
                }
                .accessibilityLabel("通话内设置")
                .disabled(isCallEnded)
                .opacity(isCallEnded ? 0 : 1)
            }
            headerMetadata
                .frame(maxWidth: .infinity)
                .frame(height: 16)
        }
        .font(.system(size: 18, weight: .medium))
        .buttonStyle(.plain)
        .foregroundStyle(palette.primaryText)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .animation(reduceMotion ? nil : displayAnimation, value: showsSelfAvatar)
    }

    private var presentationSwipe: some Gesture {
        DragGesture(minimumDistance: 32)
            .onEnded { value in
                // Leave the screen edge to navigation and vertical movement to the transcript.
                guard value.startLocation.x > 24,
                      abs(value.translation.width) > 80,
                      abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                if value.translation.width < 0, presentation == .voice {
                    changePresentation(.text)
                } else if value.translation.width > 0, presentation == .text {
                    changePresentation(.voice)
                }
            }
    }

    private func changePresentation(_ value: CallPresentation) {
        composerState.resetExpansion()
        inputFocused = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { presentation = value }
    }

    private func openTextComposer() {
        guard isCallActive else { return }
        changePresentation(.text)
        composerState.requestFocus()
    }

    private func collapseComposer() {
        if composerState.collapse() { inputFocused = false }
    }

    private func resumeComposerAfterPicker() {
        guard isCallActive, presentation == .text else { return }
        composerState.requestFocus()
    }

    private func hangUp() {
        // Send feedback before the hangup removes this view from the hierarchy.
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        inputFocused = false
        onHangUp()
        close()
    }

    private func close() {
        if let onClose { onClose() }
        else { dismiss() }
    }

    private func toggleMute() {
        muteFeedback += 1
        onToggleMute()
    }

    private func toggleSpeaker() {
        guard let onToggleSpeaker else { return }
        speakerFeedback += 1
        onToggleSpeaker()
    }

    private func interrupt() {
        guard canInterrupt else { return }
        interruptFeedback += 1
        onInterrupt()
    }

    private var voiceContent: some View {
        ViewThatFits(in: .vertical) {
            voiceLayout(spacious: true)
            ScrollView { voiceLayout(spacious: false) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func voiceLayout(spacious: Bool) -> some View {
        let maximumCaptionContentHeight = CallRollingCaption.maximumHeight(font:
            captionFonts.font(named: captionFontName, size: 18 * textScale))
            + ceil(UIFont.systemFont(ofSize: 11).lineHeight) + 8
        return VStack(spacing: 0) {
            if spacious { Spacer(minLength: 18) }
            ZStack(alignment: .bottomTrailing) {
                CallRoundPortrait(name: displayName, data: avatarData, color: CallNight.lavender,
                                  size: 164, isSpeaking: assistantSpeaking)
                if showsSelfAvatar {
                    CallRoundPortrait(name: userDisplayName, data: userAvatarData, color: CallNight.rose,
                                      size: 72, isSpeaking: userSpeaking)
                        .offset(x: 24)
                        .transition(avatarTransition)
                        .zIndex(1)
                }
            }
            .frame(width: 204, height: 190)
            .offset(x: showsSelfAvatar ? -12 : 0, y: -4)
            .padding(.top, 18)
            statusLine.padding(.top, 18).offset(y: -4)
            if showsCaptions {
                VStack(spacing: 8) {
                    Text(captionSpeaker.isEmpty ? " " : captionSpeaker).font(CallNight.font(11))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .opacity(captionText.isEmpty && !awaitingSpeechTranscript ? 0 : 1)
                        .accessibilityHidden(captionText.isEmpty && !awaitingSpeechTranscript)
                    if awaitingSpeechTranscript && captionText.isEmpty {
                        CallTranscriptDots()
                            .font(Font(captionFonts.font(named: captionFontName, size: 18 * textScale)))
                            .foregroundStyle(palette.secondaryText)
                    } else {
                        CallRollingCaption(text: captionText.isEmpty
                            ? (isCallActive || isCallEnded ? " " : String(localized: "准备好时，再开始这一通电话。"))
                            : captionText, fontSize: 18 * textScale)
                            .foregroundStyle(captionText.isEmpty ? palette.secondaryText : palette.primaryText)
                    }
                }
                .visualEffect { content, geometry in
                    let spareHeight = maximumCaptionContentHeight - geometry.size.height
                    return content.offset(y: spareHeight > 1 ? -min(8, spareHeight / 2) : 0)
                }
                .frame(height: captionBlockHeight(lines: 5), alignment: .center)
                .padding(.horizontal, 32)
                .padding(.top, 22)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            }
            if !isAwaitingConfiguration && !showsCaptions {
                // Keep the no-caption spacing; visible captions can use this room.
                Color.clear.frame(height: 14).padding(.top, 12)
            }
            if spacious { Spacer(minLength: 18) }
        }
        // Move the expanded block down without increasing its fitting height;
        // extra padding would unnecessarily select the compact scroll layout.
        .offset(y: 24 + (spacious && showsCaptions ? captionExpansionInset / 2 : 0))
        .padding(.bottom, spacious && !showsCaptions ? 24 : 0)
    }

    private func captionBlockHeight(lines: Int) -> CGFloat {
        max(140, CallRollingCaption.maximumHeight(font:
            captionFonts.font(named: captionFontName, size: 18 * textScale), lines: lines) + 26)
    }

    private var captionExpansionInset: CGFloat {
        max(0, captionBlockHeight(lines: 5) - captionBlockHeight(lines: 3) - (isAwaitingConfiguration ? 0 : 26))
    }

    private var configurationPrompt: some View {
        VStack(spacing: 4) {
            notices
            if let onConfigure {
                Button("完成通话配置", systemImage: "slider.horizontal.3", action: onConfigure)
                    .frame(minHeight: 44)
            }
        }
        .font(CallNight.font(12))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusLine: some View {
        HStack(spacing: 7) {
            Circle().fill(isCallActive ? CallNight.lavender : CallNight.rose).frame(width: 5, height: 5)
            Text(isConfigured ? statusTitle : String(localized: "尚未配置"))
                .font(CallNight.font(12, weight: .medium)).foregroundStyle(palette.secondaryText)
            if animatesStatus {
                TimelineView(.periodic(from: .now, by: 0.45)) { context in
                    Text(reduceMotion ? "..." : String(repeating: ".", count: Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 3 + 1))
                        .font(CallNight.font(12, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 14, alignment: .leading)
                }
                .padding(.leading, -7)
                .accessibilityHidden(true)
            }
        }
        .overlay {
            GeometryReader { geometry in
                if isCallActive && assistantSpeaking && canInterrupt && !speechInterruptionEnabled {
                    Button(action: interrupt) {
                        Text("打断").font(CallNight.font(12, weight: .medium))
                            .foregroundStyle(palette.primaryText)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .glassEffect(.regular.interactive(), in: Capsule())
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .fixedSize()
                    .buttonStyle(.plain)
                    .accessibilityLabel("打断当前回复")
                    .offset(x: geometry.size.width + 10, y: (geometry.size.height - 44) / 2)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var headerMetadata: some View {
        HStack(spacing: 4) {
            if presentation == .text, isPreview {
                Text("预览")
                Text("·")
            }
            timer.fixedSize()
            if presentation == .text, let title = isConfigured ? textStatusTitle : String(localized: "尚未配置") {
                Text("·")
                Text(title).lineLimit(1)
            }
        }
        .font(CallNight.font(11))
        .foregroundStyle(palette.secondaryText)
    }

    private var notices: some View {
        let detail = presentation == .text ? (textStatusDetail ?? statusDetail) : statusDetail
        return VStack(spacing: 4) {
            if !detail.isEmpty {
                Text(detail).font(CallNight.font(11)).foregroundStyle(palette.secondaryText)
            }
            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage).font(CallNight.font(12)).foregroundStyle(CallNight.rose)
            }
            if let onRetrySaving {
                Button("重试保存", systemImage: "arrow.clockwise", action: onRetrySaving).frame(minHeight: 44)
            }
            if let onReconnect {
                Button("恢复通话连接", systemImage: "arrow.clockwise", action: onReconnect).frame(minHeight: 44)
            }
            if errorMessage == nil, isConfigured, !isCallActive, !isCallEnded, let onPreview {
                Button("预览通话页面", action: onPreview).frame(minHeight: 44)
            }
        }
        .font(CallNight.font(12))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }

    @ViewBuilder private var timer: some View {
        if let startedAt, isCallActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in elapsedTime(from: startedAt, to: context.date) }
        } else if let startedAt, let endedAt {
            elapsedTime(from: startedAt, to: endedAt)
        } else if isCallActive {
            Text("00:00").monospacedDigit()
        } else {
            Text("TINCALL").tracking(2)
        }
    }

    private func elapsedTime(from start: Date, to end: Date) -> some View {
        let seconds = Int(max(0, end.timeIntervalSince(start)))
        let value = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
        return Text(value).monospacedDigit()
            .accessibilityLabel("通话时长 \(seconds / 60) 分 \(seconds % 60) 秒")
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            if !isAwaitingConfiguration && presentation == .text { notices }
            if isCallActive {
                if presentation == .text {
                    CallTextComposer(state: composerState, draft: $draft, inputFocused: $inputFocused,
                        isCallActive: isCallActive, isConfigured: isConfigured, canSend: canSend,
                        microphoneAvailable: microphoneAvailable, isMuted: isMuted, isPreview: isPreview,
                        textScale: textScale, onSend: onSend, onSendImages: onSendImages,
                        onToggleMute: toggleMute, onHangUp: hangUp, onPickerDismiss: resumeComposerAfterPicker)
                } else {
                    HStack(alignment: .lastTextBaseline, spacing: 34) {
                        controlButton(symbol: isMuted ? "mic.slash.fill" : "mic.fill",
                                      title: isMuted ? String(localized: "开麦") : String(localized: "关麦"), color: nil,
                                      isSelected: isMuted,
                                      action: toggleMute)
                            .disabled(!microphoneAvailable)
                            .accessibilityLabel(isMuted ? String(localized: "开启麦克风") : String(localized: "关闭麦克风"))
                            .accessibilityValue(microphoneAvailable ? (isMuted ? String(localized: "已关闭") : String(localized: "已打开")) : String(localized: "麦克风不可用"))
                        controlButton(symbol: "phone.down.fill", title: "挂断", color: Color(red: 0.87, green: 0.25, blue: 0.33),
                                      size: 68, action: hangUp)
                            .accessibilityLabel("挂断通话")
                        controlButton(symbol: isSpeakerEnabled ? "speaker.wave.2.fill" : "speaker.fill",
                                      title: "扬声器", color: nil,
                                      isSelected: isSpeakerEnabled,
                                      isEnabled: onToggleSpeaker != nil, action: toggleSpeaker)
                            .accessibilityLabel(isSpeakerEnabled ? String(localized: "切换到听筒") : String(localized: "切换到扬声器"))
                            .accessibilityValue(isSpeakerEnabled ? String(localized: "已打开") : String(localized: "已关闭"))
                    }
                    .transition(.opacity)
                }
            } else if isCallEnded {
                CallRoundButton(systemImage: "xmark", title: String(localized: "退出通话")) { close() }
            } else if isConfigured {
                CallRoundButton(systemImage: "phone.fill", title: "开始通话", action: onStart).disabled(!canStart)
            } else {
                if errorMessage == nil, let onPreview {
                    controlButton(symbol: "phone", title: "预览通话页面", color: CallNight.lavender,
                                  size: 68, action: onPreview)
                }
            }
        }
        .font(CallNight.font(12))
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if presentation == .voice, !isAwaitingConfiguration,
               !statusDetail.isEmpty || errorMessage?.isEmpty == false || onRetrySaving != nil || onReconnect != nil
                || (errorMessage == nil && isConfigured && !isCallActive && !isCallEnded && onPreview != nil) {
                ScrollView {
                    notices.frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom, for: .alignment)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: 72)
                .offset(y: -72)
            }
        }
    }

    private func controlButton(symbol: String, title: String, color: Color?, size: CGFloat = 56, isSelected: Bool = false, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            guard isEnabled else { return }
            inputFocused = false
            action()
        } label: {
            VStack(spacing: 7) {
                let icon = Image(systemName: symbol).font(.system(size: 20 * size / 56, weight: .medium))
                    .foregroundStyle((color != nil ? .white : (isSelected ? (palette.isLight ? .white : CallNight.background) : palette.primaryText)).opacity(isEnabled ? 1 : 0.35))
                    // The speaker symbols have different wave extents; the
                    // replacement effect makes the icon jump while the
                    // selected background is fading. A short opacity
                    // transition keeps both states visually aligned.
                    .contentTransition(.opacity)
                    .frame(width: size, height: size)
                Group {
                    if isEnabled {
                        icon
                            .background(isSelected ? (palette.isLight ? palette.accent : .white) :
                                (scenePhase == .active ? .clear : (color ?? .clear)), in: Circle())
                            .glassEffect(isSelected ? .identity : .regular.tint(color).interactive(), in: Circle())
                            .glassEffectTransition(.identity)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isSelected)
                    } else {
                        icon.background(palette.primaryText.opacity(0.06), in: Circle())
                    }
                }
                .frame(width: 68, height: 68)
                Text(title).font(CallNight.font(11))
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Button(title, action: action).disabled(!isEnabled)
        }
    }

    private func openAfterOptions(_ action: @escaping () -> Void) {
        pendingAction = action
        showsOptions = false
    }
}
