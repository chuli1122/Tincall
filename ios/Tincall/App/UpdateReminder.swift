// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation
import Observation

/// One launch-time reminder: a newer app release first, otherwise an outdated cloud service.
/// Each version is announced once, whether the person updates or chooses later.
@MainActor @Observable
final class UpdateReminder {
    enum Notice: Equatable {
        case app(version: String, notes: String?, url: URL)
        case cloud(connectionName: String)
    }

    private(set) var notice: Notice?
    @ObservationIgnored private var pendingKey: (key: String, value: String)?
    @ObservationIgnored private var hasChecked = false
    @ObservationIgnored private let defaults = UserDefaults.standard

    func check(connections: [ConnectionProfile]) async {
        guard !hasChecked else { return }
        hasChecked = true
        if let release = await latestRelease(), Self.isNewer(release.version, than: Self.installedVersion),
           defaults.string(forKey: "tincall.updateReminder.app") != release.version {
            present(.app(version: release.version, notes: release.notes, url: release.url),
                    key: "tincall.updateReminder.app", value: release.version)
            return
        }
        guard let required = try? CloudServiceVersion.required() else { return }
        for connection in connections where connection.provider == .genericConnector && DataSharingConsent.isAllowed(connection) {
            let key = "tincall.updateReminder.cloud.\(connection.id.uuidString)"
            guard defaults.string(forKey: key) != String(required) else { continue }
            let check = CloudServiceVersionCheck()
            await check.refresh(connection: connection)
            if case .updateRequired = check.status {
                present(.cloud(connectionName: connection.name), key: key, value: String(required))
                return
            }
        }
    }

    func dismiss() {
        if let pendingKey { defaults.set(pendingKey.value, forKey: pendingKey.key) }
        pendingKey = nil
        notice = nil
    }

    private func present(_ notice: Notice, key: String, value: String) {
        pendingKey = (key, value)
        self.notice = notice
    }

    private struct Release { let version: String; let notes: String?; let url: URL }

    /// Store builds follow the App Store; self-signed builds follow the public GitHub release.
    private func latestRelease() async -> Release? {
        #if TINCALL_APP_STORE
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "bundleId", value: Bundle.main.bundleIdentifier ?? "com.tincall.app")]
            + (Locale.current.region.map { [URLQueryItem(name: "country", value: $0.identifier.lowercased())] } ?? [])
        struct Lookup: Decodable {
            struct Result: Decodable { let version: String; let releaseNotes: String?; let trackViewUrl: URL }
            let results: [Result]
        }
        guard let url = components.url, let lookup: Lookup = await fetch(url), let result = lookup.results.first else { return nil }
        return Release(version: result.version, notes: result.releaseNotes, url: result.trackViewUrl)
        #else
        struct Latest: Decodable { let tag_name: String; let html_url: URL }
        guard let latest: Latest = await fetch(URL(string: "https://api.github.com/repos/chuli1122/Tincall/releases/latest")!) else { return nil }
        // Tags look like v1.0.1 or v1.0-build13.
        let version = latest.tag_name.drop { $0 == "v" }.split(separator: "-").first.map(String.init) ?? ""
        return version.isEmpty ? nil : Release(version: version, notes: nil, url: latest.html_url)
        #endif
    }

    private func fetch<Value: Decodable>(_ url: URL) async -> Value? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // A reminder is optional: an offline or failed check simply shows nothing.
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = installed.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}
