// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation
import Observation

/// Deployment revision is separate from the connector's `version` protocol field.
struct CloudServiceVersion: Decodable, Sendable {
    let server_version: Int?
    static let resourcePath = "supabase/functions/_shared/tincall/server-version.json"

    static func required(resources: CloudDeploymentResources? = nil) throws -> Int {
        let resources = try resources ?? CloudDeploymentResources.bundled()
        let version = try JSONDecoder().decode(Self.self, from: resources.read(resourcePath))
        guard let revision = version.server_version, revision > 0 else {
            throw TincallError(message: String(localized: "App 缺少有效的云端版本信息，请更新 App。"))
        }
        return revision
    }
}

@MainActor @Observable
final class CloudServiceVersionCheck {
    enum Status: Equatable {
        case unchecked, checking
        case current(Int)
        case updateRequired(Int?)
        case unavailable(String)
    }

    private(set) var status: Status = .unchecked
    @ObservationIgnored private let client: ExternalCallClient
    @ObservationIgnored private let resources: CloudDeploymentResources?
    @ObservationIgnored private var requestID = UUID()

    init(client: ExternalCallClient = ExternalCallClient(), resources: CloudDeploymentResources? = nil) {
        self.client = client
        self.resources = resources
    }

    func refresh(connection: ConnectionProfile) async {
        let requestID = UUID()
        self.requestID = requestID
        status = .checking
        let required: Int
        do {
            required = try CloudServiceVersion.required(resources: resources)
        } catch {
            status = .unavailable(String(localized: "无法读取 App 内的云端版本信息，请更新 App。"))
            return
        }
        do {
            let response: CloudServiceVersion = try await client.request(connection, path: ["capabilities"],
                method: "GET", body: Optional<Int>.none)
            try Task.checkCancellation()
            guard self.requestID == requestID else { return }
            if let revision = response.server_version, revision >= required {
                status = .current(revision)
            } else {
                status = .updateRequired(response.server_version)
            }
        } catch {
            guard self.requestID == requestID else { return }
            if Task.isCancelled {
                status = .unchecked
            } else {
                // Transport/authorization failures do not establish an outdated deployment.
                status = .unavailable(String(localized: "未能检查服务版本，请检查连接、访问令牌和服务状态后刷新。"))
            }
        }
    }
}
