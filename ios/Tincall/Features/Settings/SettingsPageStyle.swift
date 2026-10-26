// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import ImageIO
import UIKit

extension Color {
    /// Use the adaptive lavender accent for both appearances, with visible dark-mode fills.
    static func settingsSurface(lightOpacity: Double = 0.045) -> Color {
        Color(uiColor: UIColor { traits in
            let accent = (UIColor(named: "AccentColor") ?? UIColor(red: 148 / 255, green: 115 / 255, blue: 181 / 255, alpha: 1))
                .resolvedColor(with: traits)
            if traits.userInterfaceStyle == .dark {
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                accent.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                let strength = min(0.4, max(0.36, lightOpacity * 3))
                return UIColor(red: red * strength, green: green * strength, blue: blue * strength, alpha: 1)
            }
            return accent.withAlphaComponent(lightOpacity)
        })
    }
}

/// Apply row backgrounds to the list's content; a modifier on List itself does not style its cells.
struct SettingsList<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        List {
            content.listRowBackground(colorScheme == .dark ? Color.clear : nil)
        }
    }
}

struct CopySuccessPreferenceKey: PreferenceKey {
    static let defaultValue: Date? = nil

    static func reduce(value: inout Date?, nextValue: () -> Date?) {
        if let next = nextValue() { value = max(value ?? next, next) }
    }
}

struct CopySuccessFeedback: ViewModifier {
    @State private var lastCopy: Date?
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(CopySuccessPreferenceKey.self) { date in
                guard let date, date > (lastCopy ?? .distantPast) else { return }
                lastCopy = date
                isVisible = true
            }
            .overlay(alignment: .bottom) {
                if isVisible {
                    Label("复制成功", systemImage: "checkmark")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                        .padding(.bottom, 80)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isVisible)
            .task(id: lastCopy) {
                guard lastCopy != nil else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                isVisible = false
            }
            .onDisappear { isVisible = false }
    }
}

/// Shared page furniture; individual screens keep ownership of their controls and actions.
struct SettingsPageStyle: ViewModifier {
    let title: String
    let subtitle: String
    let symbol: String
    let index: String
    var actionTitle: String? = nil
    var actionSymbol: String? = nil
    var actionDisabled = false
    var actionConfirmed = false
    var actionFeedbackTrigger = 0
    var onAction: (() -> Void)? = nil
    var isModal = false
    var dismissDisabled = false
    var sectionSpacing: CGFloat = 18
    var hasUnsavedChanges = false
    var onSaveBeforeDismiss: ((@escaping () -> Void) -> Void)? = nil
    @State private var showsUnsavedChanges = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var titleSize = 30.0

    func body(content: Content) -> some View {
        content.listStyle(.insetGrouped)
            .font(.subheadline)
            .contentMargins(.top, 12, for: .scrollContent)
            .contentMargins(.bottom, 24, for: .scrollContent)
            .listSectionSpacing(sectionSpacing)
            .environment(\.defaultMinListRowHeight, 48)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .padding(.horizontal, 0)
            .safeAreaBar(edge: .top, spacing: 0) { header }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(Color(.systemBackground))
            .tint(Color.accentColor)
            .toolbar(.hidden, for: .navigationBar)
            .environment(\.navigationDockClearance, 0)
            .preference(key: SettingsSubpageVisibilityKey.self, value: true)
            .background {
                if onSaveBeforeDismiss != nil && !isModal {
                    SettingsBackGestureGuard(isBlocked: dismissDisabled, hasUnsavedChanges: hasUnsavedChanges,
                                             onAttempt: requestDismiss)
                }
            }
            .alert("要保存更改吗？", isPresented: $showsUnsavedChanges) {
                Button("保存") {
                    onSaveBeforeDismiss? { dismiss() }
                }.disabled(actionDisabled)
                Button("放弃更改", role: .destructive) { dismiss() }
                Button("取消", role: .cancel) { }
            } message: { Text("此页面有尚未保存的更改。") }
            .modifier(CopySuccessFeedback())
    }

    private func requestDismiss() {
        guard !dismissDisabled else { return }
        if hasUnsavedChanges { showsUnsavedChanges = true }
        else { dismiss() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: requestDismiss) {
                    Image(systemName: isModal ? "xmark" : "arrow.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(colorScheme == .dark ? Color.accentColor : Color.secondary)
                        .frame(width: 34, height: 34)
                        .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.75))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isModal ? String(localized: "取消") : String(localized: "返回"))
                .disabled(dismissDisabled)
                Text("TINCALL / \(index)")
                    .font(.system(.caption2, design: .monospaced))
                    .tracking(1).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let actionTitle, let actionSymbol, let onAction {
                    if actionConfirmed {
                        Text("已保存")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                    Button(action: onAction) {
                        if actionSymbol == "checkmark" && !isModal {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(actionDisabled ? Color.secondary : (colorScheme == .dark ? Color.accentColor : Color(.systemBackground)))
                                .frame(width: 34, height: 34)
                                .background(actionDisabled || colorScheme == .dark ? Color.clear : Color.accentColor)
                                .overlay(Rectangle().strokeBorder(Color.primary.opacity(actionDisabled || colorScheme == .dark ? 0.25 : 0), lineWidth: 0.75))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        } else {
                            Image(systemName: actionConfirmed && actionSymbol == "checkmark" ? "checkmark.circle.fill" : actionSymbol)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(colorScheme == .dark ? Color.accentColor : Color(.systemBackground))
                                .frame(width: colorScheme == .dark ? 34 : 32, height: colorScheme == .dark ? 34 : 32)
                                .background(colorScheme == .dark ? Color.clear : Color.accentColor)
                                .overlay {
                                    if colorScheme == .dark {
                                        Rectangle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.75)
                                    }
                                }
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(actionTitle)
                    .disabled(actionDisabled)
                    .opacity(actionDisabled && !(actionSymbol == "checkmark" && !isModal) ? 0.4 : 1)
                }
            }
            .padding(.leading, -5)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: actionConfirmed)
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: titleSize, weight: .bold))
                        .tracking(-0.9).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                ZStack {
                    Rectangle().strokeBorder(Color.primary.opacity(0.55), lineWidth: 0.75)
                        .frame(width: 43, height: 43).rotationEffect(.degrees(10))
                    Rectangle().fill(Color.settingsSurface(lightOpacity: 0.16)).frame(width: 43, height: 43)
                    Image(systemName: symbol).font(.system(size: 21, weight: .light))
                }
                .frame(width: 52, height: 58)
                .rotationEffect(.degrees(-3))
                .accessibilityHidden(true)
            }
            .padding(.top, 15).padding(.bottom, 21)
            Rectangle().fill(Color.primary).frame(height: 1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 24).padding(.top, 5)
        .sensoryFeedback(.success, trigger: actionFeedbackTrigger)
    }
}

struct SettingsSectionHeading: View {
    let number: String?
    let title: String
    var caption: String = ""

    init(number: String? = nil, title: String, caption: String = "") {
        self.number = number
        self.title = title
        self.caption = caption
    }

    var body: some View {
        HStack(spacing: 10) {
            if let number, !number.isEmpty {
                Text(number).font(.system(.caption2, design: .monospaced))
                    .frame(width: 26, height: 26)
                    .background(Color.settingsSurface(lightOpacity: 0.12))
            } else {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 18)
            }
            Text(title).font(.headline)
            Spacer(minLength: 0)
            if !caption.isEmpty {
                Text(caption).font(.system(.caption2, design: .monospaced))
                    .tracking(0.5).foregroundStyle(.secondary)
            }
        }
        .textCase(nil).foregroundStyle(.primary)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SettingsField<Content: View>: View {
    let title: String
    var help: LocalizedStringResource? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if let help {
                    DeploymentHelpButton(title: "\(title)说明", detail: help, systemImage: "info.circle")
                }
            }
            content
                .font(.subheadline)
                .accessibilityLabel(title)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Color.settingsSurface(lightOpacity: 0.055), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75))
        }
        .padding(.vertical, 5)
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        .listRowSeparator(.hidden)
    }
}

/// Use an explicit menu label so the selected value follows the form's type scale.
struct SettingsPickerRow<Selection: Hashable, Options: View>: View {
    let title: String
    let value: String
    @Binding var selection: Selection
    @ViewBuilder var options: Options

    var body: some View {
        HStack(spacing: 16) {
            Text(title).font(.subheadline).foregroundStyle(.primary)
            Spacer(minLength: 0)
            Menu {
                Picker(title, selection: $selection) { options }
            } label: {
                SettingsSelectionLabel(value: value)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(value)
        }
        .frame(minHeight: 44)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
}

struct SettingsSelectionLabel: View {
    let value: String
    @ScaledMetric(relativeTo: .subheadline) private var valueSize = 14.0

    var body: some View {
        HStack(spacing: 6) {
            Text(value).font(.system(size: valueSize))
                .lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
    }
}

struct SettingsCredentialField: View {
    let title: String
    let connectionID: UUID
    var field: CredentialField = .apiKey
    @Binding var text: String
    var isReadOnly = false
    var help: LocalizedStringResource? = nil
    @State private var prompt = String(localized: "正在读取保存状态…")

    var body: some View {
        Group {
            if isReadOnly {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(title).font(.caption).foregroundStyle(.secondary)
                        if let help {
                            DeploymentHelpButton(title: "\(title)说明", detail: help, systemImage: "info.circle")
                        }
                    }
                    input.font(.subheadline)
                }
                .padding(.vertical, 5)
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                .listRowSeparator(.hidden)
            } else {
                SettingsField(title: title, help: help) { input }
            }
        }
        .task(id: connectionID) {
            do {
                if let date = try CredentialStore().savedAt(connectionID: connectionID, field: field) {
                    prompt = String(localized: "密钥已保存 · \(date.formatted(date: .numeric, time: .shortened))")
                } else {
                    prompt = String(localized: "尚未配置，输入\(title)")
                }
            } catch {
                prompt = String(localized: "保存状态读取失败，请重新打开页面")
            }
        }
    }

    private var input: some View {
        SettingsSecretInput(prompt: prompt, text: $text, isReadOnly: isReadOnly) {
            try CredentialStore().read(connectionID: connectionID, field: field)
        }
        .accessibilityHint(isReadOnly ? String(localized: "仅供查看和复制，不可修改") : String(localized: "留空保存会保留原来的密钥和保存时间"))
    }
}

struct SettingsActionLabel: View {
    let title: String
    var symbol: String? = nil
    var detail: String? = nil
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 18, weight: .regular))
                    .frame(width: 38, height: 38)
                    .background(Color.settingsSurface(lightOpacity: 0.12), in: RoundedRectangle(cornerRadius: 3))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.accentColor).padding(.vertical, 8)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.4)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }
}

struct SettingsNote: View {
    let title: String
    let text: String

    var body: some View {
        DisclosureGroup {
            Text(text).font(.footnote).foregroundStyle(.secondary)
                .lineSpacing(3).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
        } label: {
            Label(title, systemImage: "info.circle")
                .font(.caption).foregroundStyle(Color.accentColor)
        }
        .tint(.accentColor)
        .padding(12)
        .background(Color.settingsSurface(), in: RoundedRectangle(cornerRadius: 4))
        .listRowSeparator(.hidden)
    }
}

struct SettingsSubpageVisibilityKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

func makeSettingsImageThumbnail(_ data: Data, maxPixelSize: Int) throws -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
          ] as CFDictionary),
          let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else {
        throw TincallError(message: String(localized: "无法解码图片，请选择有效图片。"))
    }
    return jpeg
}

/// Saved credentials are loaded only after the user explicitly reveals them.
struct SettingsSecretInput: View {
    let prompt: String
    @Binding var text: String
    var isReadOnly = false
    var readSavedValue: (() throws -> String?)? = nil
    @State private var isRevealed = false
    @State private var revealedSavedValue: String?
    @State private var readFailed = false
    @State private var copied = false
    @State private var copyFeedbackTrigger: Date?

    private var visibleText: Binding<String> {
        Binding(get: { text.isEmpty ? revealedSavedValue ?? "" : text }, set: {
            revealedSavedValue = nil
            text = $0
        })
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isReadOnly {
                    Text(isRevealed ? revealedSavedValue ?? prompt : prompt)
                        .foregroundStyle(isRevealed ? .primary : .secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if isRevealed {
                    TextField("", text: visibleText, prompt: Text(prompt), axis: .vertical)
                } else {
                    SecureField("", text: $text, prompt: Text(prompt))
                }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .privacySensitive()
            Button {
                if isRevealed {
                    isRevealed = false
                    revealedSavedValue = nil
                } else {
                    do {
                        if text.isEmpty { revealedSavedValue = try readSavedValue?() }
                        isRevealed = true
                    } catch { readFailed = true }
                }
            } label: {
                Image(systemName: isRevealed ? "eye" : "eye.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 22)
                    .contentShape(Rectangle().inset(by: -11))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isRevealed ? String(localized: "隐藏密钥") : String(localized: "显示密钥"))
            if isReadOnly {
                Button {
                    do {
                        guard let value = try readSavedValue?(), !value.isEmpty else {
                            readFailed = true
                            return
                        }
                        UIPasteboard.general.setItems([["public.utf8-plain-text": value]],
                                                     options: [.expirationDate: Date().addingTimeInterval(300)])
                        copied = true
                        copyFeedbackTrigger = Date()
                    } catch { readFailed = true }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 22)
                        .contentShape(Rectangle().inset(by: -11))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? String(localized: "已复制访问令牌") : String(localized: "复制访问令牌"))
                .preference(key: CopySuccessPreferenceKey.self, value: copyFeedbackTrigger)
                .task(id: copyFeedbackTrigger) {
                    guard copied else { return }
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    copied = false
                }
            }
        }
        .onChange(of: text) { revealedSavedValue = nil }
        .onDisappear { isRevealed = false; revealedSavedValue = nil; copied = false }
        .alert("无法读取密钥", isPresented: $readFailed) {
            Button("好", role: .cancel) { }
        } message: { Text("钥匙串读取失败，请重新打开页面后重试。") }
    }
}

/// Covers both the edge swipe and iOS 26's content swipe, restoring UIKit's delegates on exit.
private struct SettingsBackGestureGuard: UIViewControllerRepresentable {
    let isBlocked: Bool
    let hasUnsavedChanges: Bool
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isBlocked = isBlocked
        controller.hasUnsavedChanges = hasUnsavedChanges
        controller.onAttempt = onAttempt
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var isBlocked = false
        var hasUnsavedChanges = false
        var onAttempt: (() -> Void)?
        private var gestures: [(UIGestureRecognizer, UIGestureRecognizerDelegate?)] = []

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let navigationController, gestures.isEmpty else { return }
            for gesture in [navigationController.interactivePopGestureRecognizer,
                            navigationController.interactiveContentPopGestureRecognizer].compactMap({ $0 }) {
                gestures.append((gesture, gesture.delegate))
                gesture.delegate = self
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            restoreGestures()
            super.viewWillDisappear(animated)
        }

        private func restoreGestures() {
            for (gesture, delegate) in gestures where gesture.delegate === self {
                gesture.delegate = delegate
            }
            gestures.removeAll()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard !isBlocked, let navigationController,
                  navigationController.viewControllers.count > 1,
                  navigationController.transitionCoordinator == nil else { return false }
            if hasUnsavedChanges {
                onAttempt?()
                return false
            }
            return true
        }
    }
}
