// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import BackgroundTasks
import Foundation

/// Free Supabase projects pause after about a week without activity. When iOS grants a
/// background refresh, read each one-click Supabase service once (a database read) and ask
/// for the next refresh. iOS decides the actual timing; this is best effort, not a guarantee.
@MainActor
enum CloudKeepAlive {
    static let identifier = "com.tincall.app.keepalive"

    /// Must run before launch finishes.
    static func register() {
        // Main queue: under Swift 6 this closure is main-actor isolated and checked at runtime.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
                handle(task)
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        // Replacing a pending request is fine; failures (e.g. background refresh off) leave the foreground path.
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task { @MainActor in
            let connections = TincallRuntime.shared.configuration?.connections ?? []
            let client = ExternalCallClient()
            for connection in connections where isSupabaseService(connection) && DataSharingConsent.isAllowed(connection) {
                guard !Task.isCancelled else { break }
                // /capabilities authenticates the phone token and reads the database.
                _ = try? await client.request(connection, path: ["capabilities"], method: "GET", body: Optional<Int>.none) as CloudServiceVersion
            }
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        // iOS calls this on its own queue.
        task.expirationHandler = { @Sendable in work.cancel() }
    }

    private static func isSupabaseService(_ connection: ConnectionProfile) -> Bool {
        guard connection.provider == .genericConnector, let url = connection.endpoint else { return false }
        return url.host?.lowercased().hasSuffix(".supabase.co") == true
    }
}
