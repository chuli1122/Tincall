// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

// Source-build access and entitlement boundaries. StoreKit transactions need an XCTest host.
@main struct CallAccessMain {
    @MainActor static func main() async throws {
        try await CallAccessStoreChecks.run()
    }
}
