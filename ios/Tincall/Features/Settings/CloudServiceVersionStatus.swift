// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

struct CloudServiceVersionStatus: View {
    let connection: ConnectionProfile
    let refreshAttempt: Int
    @State private var check = CloudServiceVersionCheck()

    private struct CheckInput: Equatable {
        let connection: ConnectionProfile
        let refreshAttempt: Int
    }

    var body: some View {
        Group {
            switch check.status {
            case .unchecked, .checking:
                Text("正在检查服务版本…").foregroundStyle(.secondary)
            case .current(let revision):
                Text("服务版本 \(String(revision))").foregroundStyle(.secondary)
            case .updateRequired:
                Text("服务版本过旧，请重新部署。可在下方选择「部署或更新服务」；手动部署的服务请在原电脑或服务器更新。")
                    .foregroundStyle(.orange)
            case .unavailable(let message):
                Text(message).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: CheckInput(connection: connection, refreshAttempt: refreshAttempt)) {
            await check.refresh(connection: connection)
        }
    }
}
