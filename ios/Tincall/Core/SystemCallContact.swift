// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import CallKit
import Intents

/// The same identity is used for incoming caller matching and system contact actions.
enum SystemCallContact {
    /// The default calling app also receives telephone URLs, without an Intents interaction.
    static func intent(for url: URL) -> INStartCallIntent? {
        guard url.scheme?.lowercased() == "tel",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil else { return nil }
        // Contacts can deliver tel://number with contact-card metadata instead of an Intent.
        // Only the selected number identifies the recipient; metadata never changes the route.
        let metadata = components.queryItems ?? []
        guard metadata.allSatisfy({ ["handleType", "contactIdentifier", "originatingUI"].contains($0.name) && $0.value != nil }),
              Set(metadata.map(\.name)).count == metadata.count,
              metadata.first(where: { $0.name == "handleType" }).map({ $0.value == "phoneNumber" }) ?? true else { return nil }
        let address: String
        if let host = components.host {
            guard components.path.isEmpty else { return nil }
            address = host
        } else { address = components.path }
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept telephone formatting, never extension/control codes or arbitrary text.
        guard value.allSatisfy({ "0123456789+ ()-.".contains($0) }) else { return nil }
        let number = normalizedPhone(value)
        guard !number.isEmpty, number.contains(where: \.isNumber),
              !number.dropFirst().contains("+") else { return nil }
        let person = INPerson(personHandle: INPersonHandle(value: number, type: .phoneNumber),
                              nameComponents: nil, displayName: nil, image: nil,
                              contactIdentifier: nil, customIdentifier: nil)
        return INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown,
                                 destinationType: .normal, contacts: [person], callCapability: .audioCall)
    }

    /// Retained only to replace the addresses installed by the first development build.
    static func legacyPhoneNumber(for roleID: UUID) -> String {
        let decimal = String(UInt128(roleID.uuidString.replacingOccurrences(of: "-", with: ""), radix: 16)!)
        return "000" + String(repeating: "0", count: 39 - decimal.count) + decimal
    }

    static func newPhoneNumber(excluding used: Set<String>) -> String {
        var number: String
        repeat { number = "000" + String(Int.random(in: 100_000_000...999_999_999)) } while used.contains(number)
        return number
    }

    /// Addresses written during the email experiment; kept only for cleanup and old Recents.
    static func previousEmailAddresses(for roleID: UUID, number: String?) -> [String] {
        let compactID = roleID.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        var addresses = [roleID.uuidString.lowercased() + "@tincall.invalid", "tc\(compactID)@tc.invalid"]
        if let number {
            let digits = normalizedPhone(number)
            if (8...12).contains(digits.count) { addresses.append("tc\(digits)@tc.invalid") }
        }
        return addresses
    }

    private static func isCallNumber(_ value: String) -> Bool {
        value.hasPrefix("000") && (value.count == 12 || value.count == 42)
    }

    static func handle(for role: CallRole?) -> CXHandle {
        if let contact = role?.linkedContact {
            if let number = role?.systemCallPhoneNumber {
                if contact.phoneNumbers?.contains(where: { normalizedPhone($0) == number }) == true {
                    return CXHandle(type: .phoneNumber, value: number)
                }
            }
            if let phone = contact.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !phone.isEmpty {
                return CXHandle(type: .phoneNumber, value: phone)
            }
            if let email = contact.emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
                return CXHandle(type: .emailAddress, value: email)
            }
        }
        return CXHandle(type: .generic, value: role?.id.uuidString ?? "Tincall")
    }

    static func person(for role: CallRole) -> INPerson {
        let handle = handle(for: role)
        let type: INPersonHandleType = switch handle.type {
        case .phoneNumber: .phoneNumber
        case .emailAddress: .emailAddress
        default: .unknown
        }
        return INPerson(personHandle: INPersonHandle(value: handle.value, type: type), nameComponents: nil,
                        displayName: role.displayName, image: role.displayAvatarData.map { INImage(imageData: $0) },
                        contactIdentifier: role.linkedContact?.identifier, customIdentifier: role.id.uuidString)
    }

    static func role(for activity: NSUserActivity, roles: [CallRole]) throws -> CallRole {
        try role(for: activity.interaction?.intent, roles: roles)
    }

    static func role(for intent: INIntent?, roles: [CallRole], records: [CallRecord] = []) throws -> CallRole {
        let contacts: [INPerson]?
        if let intent = intent as? INStartCallIntent, SystemCallIntentHandler.supportsRequest(intent) {
            if let callback = intent.callRecordToCallBack {
                var candidates: [CallRole] = []
                if let id = UUID(uuidString: callback.identifier), let record = records.first(where: { $0.id == id }) {
                    guard let role = roles.first(where: { $0.id == record.roleID }) else { throw unavailable() }
                    candidates.append(role)
                }
                // A callback may carry only participants, or only our saved call ID.
                // If both identities are present they must agree; never guess by name.
                for person in (callback.participants ?? []) + (intent.contacts ?? []) + (intent.callRecordFilter?.participants ?? []) {
                    candidates.append(try role(for: person, roles: roles))
                }
                guard let role = candidates.first, candidates.allSatisfy({ $0.id == role.id }) else { throw unavailable() }
                return role
            }
            let people = (intent.contacts ?? []) + (intent.callRecordFilter?.participants ?? [])
            let candidates = try people.map { try role(for: $0, roles: roles) }
            guard let role = candidates.first, candidates.allSatisfy({ $0.id == role.id }) else { throw unavailable() }
            return role
        } else if let intent = intent as? INStartAudioCallIntent {
            contacts = intent.contacts
        } else {
            throw unavailable()
        }
        guard let contacts, contacts.count == 1, let person = contacts.first else { throw unavailable() }
        return try role(for: person, roles: roles)
    }

    static func role(for person: INPerson, roles: [CallRole]) throws -> CallRole {
        let matches: [CallRole]
        if let customID = person.customIdentifier, !customID.isEmpty {
            // An explicit stale app identity must never dial a different role with the same number.
            matches = roles.filter { $0.id.uuidString.caseInsensitiveCompare(customID) == .orderedSame }
        } else if let handle = person.personHandle, handle.type == .emailAddress,
                  let value = handle.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  value.lowercased().hasSuffix("@tc.invalid") || value.lowercased().hasSuffix("@tincall.invalid") {
            matches = roles.filter { role in
                guard let linked = role.linkedContact,
                      previousEmailAddresses(for: role.id, number: role.systemCallPhoneNumber).contains(where: {
                          $0.caseInsensitiveCompare(value) == .orderedSame
                      }) else { return false }
                return person.contactIdentifier.map { $0.isEmpty || $0 == linked.identifier } ?? true
            }
        } else if let handle = person.personHandle, handle.type == .phoneNumber,
                  let value = handle.value, isCallNumber(normalizedPhone(value)) {
            // Resolve the selected Tincall number before a shared system contact ID.
            // An obsolete Tincall number must not fall back to a different role.
            matches = roles.filter { role in
                guard let linked = role.linkedContact,
                      normalizedPhone(value) == role.systemCallPhoneNumber
                        || normalizedPhone(value) == legacyPhoneNumber(for: role.id) else { return false }
                return person.contactIdentifier.map { $0.isEmpty || $0 == linked.identifier } ?? true
            }
        } else if let contactID = person.contactIdentifier, !contactID.isEmpty {
            matches = roles.filter { $0.linkedContact?.identifier == contactID }
        } else if let handle = person.personHandle, let value = handle.value, !value.isEmpty {
            matches = roles.filter { role in
                switch handle.type {
                case .phoneNumber:
                    let incoming = normalizedPhone(value)
                    let phones = role.linkedContact?.phoneNumbers ?? role.linkedContact?.phoneNumber.map { [$0] } ?? []
                    return !incoming.isEmpty && phones.contains { normalizedPhone($0) == incoming }
                case .emailAddress:
                    return role.linkedContact?.emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare(value.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                default:
                    return role.id.uuidString.caseInsensitiveCompare(value) == .orderedSame
                }
            }
        } else { matches = [] }
        guard matches.count == 1, let role = matches.first else { throw unavailable() }
        return role
    }

    static func donateCall(role: CallRole, callID: UUID, incoming: Bool) {
        let intent = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown,
                                       destinationType: .normal, contacts: [person(for: role)], callCapability: .audioCall)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.identifier = callID.uuidString
        interaction.direction = incoming ? .incoming : .outgoing
        interaction.donate { error in
            if let error {
                // Do not log the contact, donated intent, or localized error description.
                NSLog("system_call_contact_donation_failed domain=%@ code=%ld", (error as NSError).domain, (error as NSError).code)
            }
        }
    }

    /// Used only after the person explicitly chooses the system-phone fallback.
    static func telephonyURL(for activity: NSUserActivity) -> URL? {
        telephonyURL(for: activity.interaction?.intent)
    }

    static func telephonyURL(for intent: INIntent?) -> URL? {
        let contacts: [INPerson]?
        if let intent = intent as? INStartCallIntent, SystemCallIntentHandler.supportsRequest(intent),
           intent.callRecordToCallBack == nil, intent.callRecordFilter == nil { contacts = intent.contacts }
        else if let intent = intent as? INStartAudioCallIntent { contacts = intent.contacts }
        else { return nil }
        guard let contacts, contacts.count == 1, let handle = contacts.first?.personHandle,
              handle.type == .phoneNumber, let value = handle.value else { return nil }
        let number = normalizedPhone(value)
        guard !number.isEmpty, number.count <= 16, !isCallNumber(number) else { return nil }
        var url = URLComponents()
        url.scheme = "telephony"
        url.path = number
        return url.url
    }

    private static func normalizedPhone(_ value: String) -> String {
        String(value.filter { $0.isNumber || $0 == "+" })
    }

    private static func unavailable() -> TincallError {
        TincallError(message: String(localized: "无法确定要拨打的 Tincall 联系人，请在 App 中选择。"))
    }
}
