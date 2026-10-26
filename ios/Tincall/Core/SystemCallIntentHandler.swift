// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Intents

/// Continue in the foreground, where the existing call flow checks the role,
/// connection, consent and current call state before placing a call.
final class SystemCallIntentHandler: NSObject, INStartCallIntentHandling, INStartAudioCallIntentHandling {
    /// An unspecified capability can use our only supported call type. Keep
    /// explicit video requests unsupported at resolution and app continuation.
    static func supportsAudioCall(_ capability: INCallCapability) -> Bool {
        capability == .unknown || capability == .audioCall
    }

    static func supportsRequest(_ intent: INStartCallIntent) -> Bool {
        guard supportsAudioCall(intent.callCapability),
              intent.destinationType != .emergency, intent.destinationType != .voicemail,
              (intent.contacts?.count ?? 0) <= 1 else { return false }
        if let filter = intent.callRecordFilter {
            guard supportsAudioCall(filter.callCapability), (filter.participants?.count ?? 0) <= 1 else { return false }
        }
        if let record = intent.callRecordToCallBack {
            guard supportsAudioCall(record.callCapability), (record.participants?.count ?? 0) <= 1 else { return false }
            return record.participants?.count == 1 || UUID(uuidString: record.identifier) != nil
        }
        return intent.contacts?.count == 1 || intent.callRecordFilter?.participants?.count == 1
    }

    func resolveCallCapability(for intent: INStartCallIntent,
                               with completion: @escaping (INStartCallCallCapabilityResolutionResult) -> Void) {
        if Self.supportsAudioCall(intent.callCapability) {
            completion(.success(with: .audioCall))
        } else {
            completion(.unsupported(forReason: .videoCallUnsupported))
        }
    }

    func resolveContacts(for intent: INStartCallIntent,
                         with completion: @escaping ([INStartCallContactResolutionResult]) -> Void) {
        if Self.supportsRequest(intent), intent.contacts?.isEmpty != false, intent.callRecordToCallBack != nil {
            completion([.notRequired()])
            return
        }
        let contacts = intent.contacts?.isEmpty == false ? intent.contacts : intent.callRecordFilter?.participants
        guard Self.supportsRequest(intent), let contacts, contacts.count == 1, let person = contacts.first else {
            completion([.unsupported()])
            return
        }
        completion([.success(with: person)])
    }

    func resolveCallRecordToCallBack(for intent: INStartCallIntent,
                                     with completion: @escaping (INCallRecordResolutionResult) -> Void) {
        guard let record = intent.callRecordToCallBack else { completion(.notRequired()); return }
        completion(Self.supportsRequest(intent) ? .success(with: record) : .unsupported())
    }

    func confirm(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        completion(INStartCallIntentResponse(code: Self.supportsRequest(intent)
                                             ? .ready : .failure, userActivity: nil))
    }

    func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        guard Self.supportsRequest(intent) else {
            completion(INStartCallIntentResponse(code: .failure, userActivity: nil))
            return
        }
        completion(INStartCallIntentResponse(code: .continueInApp,
                                            userActivity: NSUserActivity(activityType: "INStartCallIntent")))
    }

    func handle(intent: INStartAudioCallIntent, completion: @escaping (INStartAudioCallIntentResponse) -> Void) {
        guard intent.contacts?.count == 1 else {
            completion(INStartAudioCallIntentResponse(code: .failure, userActivity: nil))
            return
        }
        completion(INStartAudioCallIntentResponse(code: .continueInApp,
                                                 userActivity: NSUserActivity(activityType: "INStartAudioCallIntent")))
    }

    func resolveContacts(for intent: INStartAudioCallIntent,
                         with completion: @escaping ([INPersonResolutionResult]) -> Void) {
        guard let contacts = intent.contacts, contacts.count == 1, let person = contacts.first else {
            completion([.unsupported()])
            return
        }
        completion([.success(with: person)])
    }

    func confirm(intent: INStartAudioCallIntent, completion: @escaping (INStartAudioCallIntentResponse) -> Void) {
        completion(INStartAudioCallIntentResponse(code: intent.contacts?.count == 1 ? .ready : .failure,
                                                 userActivity: nil))
    }
}
