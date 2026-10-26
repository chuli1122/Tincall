// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

struct DataSharingAgreementRow: View {
    @Binding var isOn: Bool

    private var agreement: AttributedString {
        var policy = AttributedString(String(localized: "隐私政策"))
        policy.link = DataSharingConsent.privacyURL
        return AttributedString(String(localized: "已阅读")) + policy
            + AttributedString(String(localized: "，同意上述数据发送。"))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button { isOn.toggle() } label: {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("同意上述数据发送")
            .accessibilityValue(isOn ? String(localized: "已勾选") : String(localized: "未勾选"))
            Text(agreement)
                .font(.footnote).foregroundStyle(.secondary)
                .frame(minHeight: 44, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .tint(.accentColor)
        }
        .padding(.trailing, 24)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct ConnectionDataSharingSection: View {
    let connection: ConnectionProfile
    @State private var allowed = false

    var body: some View {
        if connection.provider != .appleSpeech {
            Section {
                LabeledContent("接收方") {
                    Text(verbatim: DataSharingConsent.recipient(connection)).textSelection(.enabled)
                }
                DisclosureGroup("发送的数据") {
                    Text(DataSharingConsent.disclosure(connection))
                        .font(.footnote).foregroundStyle(.secondary)
                    if connection.provider == .genericConnector {
                        Text("关闭授权后，仍可向原服务发送设备解绑请求，以停用后台来电。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                DataSharingAgreementRow(isOn: Binding(get: { allowed }, set: {
                    DataSharingConsent.setAllowed($0, for: connection)
                    allowed = DataSharingConsent.isAllowed(connection)
                }))
                .disabled(!DataSharingConsent.canAuthorize(connection))
            } header: { SettingsSectionHeading(title: String(localized: "数据发送授权"), caption: "PRIVACY") }
            .onAppear { allowed = DataSharingConsent.isAllowed(connection) }
            .onChange(of: DataSharingConsent.destination(connection)) { _, _ in
                allowed = DataSharingConsent.isAllowed(connection)
            }
        }
    }
}

struct ConnectionDataSharingReview: View {
    let connections: [ConnectionProfile]
    @Environment(\.dismiss) private var dismiss
    @State private var allowed = false

    private var readyConnections: [ConnectionProfile] { connections.filter { DataSharingConsent.canAuthorize($0) } }

    private var disclosures: [String] {
        readyConnections.reduce(into: []) { result, connection in
            let disclosure = DataSharingConsent.disclosure(connection)
            if !result.contains(disclosure) { result.append(disclosure) }
        }
    }

    var body: some View {
        SettingsList {
            Section {
                Text("确认下列服务后，可在底部统一授权。之后仍可在各连接设置中单独关闭。")
            }
            Section {
                ForEach(connections) { connection in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connection.name).font(.subheadline.weight(.medium))
                        Text(verbatim: DataSharingConsent.recipient(connection))
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !DataSharingConsent.canAuthorize(connection) {
                            Text("地址未配置完整，本次不会授权；完善连接后可单独确认。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { SettingsSectionHeading(title: String(localized: "接收方"), caption: "SERVICES") }
            if !readyConnections.isEmpty {
                Section {
                    DisclosureGroup("发送的数据") {
                        ForEach(disclosures, id: \.self) { disclosure in
                            Text(disclosure).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .modifier(SettingsPageStyle(title: String(localized: "确认服务数据发送"),
            subtitle: String(localized: "继续使用已有连接前，请确认授权"), symbol: "hand.raised", index: "PRIVACY", isModal: true))
        .safeAreaBar(edge: .bottom, spacing: 0) { actions }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if !readyConnections.isEmpty {
                DataSharingAgreementRow(isOn: $allowed)
            }
            HStack(spacing: 12) {
                if !readyConnections.isEmpty {
                    Button { finish(allowSharing: false) } label: {
                        Text("暂不授权")
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(.primary)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                }
                Button { finish(allowSharing: allowed) } label: {
                    Text(readyConnections.isEmpty ? String(localized: "完成") : String(localized: "同意并继续"))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(allowed || readyConnections.isEmpty ? Color.white : Color.secondary)
                        .background(allowed || readyConnections.isEmpty ? Color.accentColor : Color.settingsSurface(lightOpacity: 0.12),
                                    in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
                }
                .disabled(!readyConnections.isEmpty && !allowed)
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider() }
    }

    private func finish(allowSharing: Bool) {
        for connection in connections {
            DataSharingConsent.setAllowed(allowSharing && DataSharingConsent.canAuthorize(connection), for: connection)
        }
        dismiss()
    }
}
