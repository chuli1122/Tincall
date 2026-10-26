// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Intents

final class IntentHandler: INExtension {
    private let callHandler = SystemCallIntentHandler()

    override func handler(for intent: INIntent) -> Any {
        return callHandler
    }
}
