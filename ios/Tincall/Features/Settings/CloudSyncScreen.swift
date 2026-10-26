// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

struct CloudSyncScreen: View {
    let configuration: LocalConfigurationStore
    let sync: CloudSyncStore?
    let records: CallRecordStore?
    let syncLoadingError: String?
    var isCallActive = false
    var incomingController: IncomingCallController? = nil
    let onSaveConnection: (ConnectionProfile, String?, String?) throws -> Void
    let onDeleteConnection: (UUID) throws -> Void
    @State private var versionRefreshAttempt = 0

    private var lockedConnectionIDs: Set<UUID> {
        guard let incomingController, incomingController.isEnabled || incomingController.needsDeviceRemoval else { return [] }
        return incomingController.connectionIDs
    }

    var body: some View {
        SettingsList {
            serviceConnections
            cloudFeatures
            cloudSetup
            Section {
                Text("连接云端后，可按需设置同步、MCP、后台来电或定时来电。手动发起独立模式通话不需要配置云端；使用定时来电仍需连接云端。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { SettingsSectionHeading(title: String(localized: "连接后去哪里设置"), caption: "NEXT") }
        }
        .modifier(SettingsPageStyle(title: String(localized: "Tincall 云端"), subtitle: String(localized: "部署与连接服务，管理地址和访问令牌"), symbol: "icloud", index: "CONNECTION & CLOUD"))
    }

    private var cloudSetup: some View {
        Section {
            NavigationLink {
                CloudSetupDestination { deploymentGuide() }
            } label: {
                SettingsActionLabel(title: String(localized: "部署或更新服务"), symbol: "icloud",
                                    detail: String(localized: "首次部署，或更新通过这台手机部署的服务"))
            }
            NavigationLink {
                CloudSetupDestination { deploymentGuide(existing: true) }
            } label: {
                SettingsActionLabel(title: String(localized: "连接已有服务"), symbol: "link",
                                    detail: String(localized: "连接通过电脑或服务器部署的 Tincall 服务"))
            }
        } header: { SettingsSectionHeading(title: String(localized: "服务连接"), caption: "CONNECTIONS") }
    }

    private var serviceConnections: some View {
        Section {
            if !configuration.connections.contains(where: { $0.provider == .genericConnector }) {
                Text("还没有保存的服务连接。部署完成或检查已有服务成功后，会显示在这里。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(configuration.connections.filter { $0.provider == .genericConnector }) { profile in
                    NavigationLink {
                        ConnectionEditor(connection: profile, isCallActive: isCallActive,
                                         isConnectionLocked: lockedConnectionIDs.contains(profile.id),
                                         onDelete: onDeleteConnection) { updated, key, secret in
                            if sync?.selectedConnectionID == updated.id {
                                guard sync?.isBusy != true else {
                                    throw TincallError(message: String(localized: "云端正在同步，稍后再保存连接修改。"))
                                }
                                try sync?.select(updated.id)
                            }
                            try onSaveConnection(updated, key, secret)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            Text(verbatim: profile.endpoint?.absoluteString ?? String(localized: "尚未填写地址"))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            CloudServiceVersionStatus(connection: profile, refreshAttempt: versionRefreshAttempt)
                        }
                    }
                }
                Button("刷新服务版本", systemImage: "arrow.clockwise") {
                    versionRefreshAttempt += 1
                }
            }
        } header: { SettingsSectionHeading(title: String(localized: "已保存的服务"), caption: "SAVED SERVICES") } footer: {
            Text("同一服务可用于同步、MCP 和来电，各项功能分别开启。点服务名称可修改地址与令牌。")
                .font(.footnote).foregroundStyle(.secondary)
            if let notice = incomingController?.connectionRemovalNotice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func deploymentGuide(existing: Bool = false) -> some View {
        CloudDeploymentGuide(connectExisting: existing, nextSteps: {
            cloudFeatures.syncLink
            cloudFeatures.incomingLink
        }) { profile, token in
            // Check the common service contract without requiring backup permissions or reading records.
            let client = ExternalCallClient()
            _ = try await client.contactDirectory(connection: profile, tokenOverride: token)
            try await client.synchronizeMCPContactModes(connection: profile, roles: configuration.roles, tokenOverride: token)
            try onSaveConnection(profile, token, nil)
            if let incomingController, incomingController.isEnabled {
                await incomingController.restore(with: configuration.connections)
            }
        }
    }

    private var cloudFeatures: CloudFeatureSettingsSection {
        CloudFeatureSettingsSection(configuration: configuration, records: records, sync: sync,
                                    syncLoadingError: syncLoadingError, incomingController: incomingController,
                                    isCallActive: isCallActive)
    }

}

/// Keep the setup graph out of the list row's initial construction.
private struct CloudSetupDestination<Content: View>: View {
    let content: () -> Content

    var body: some View { content() }
}
