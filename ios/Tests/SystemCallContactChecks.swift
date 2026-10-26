// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import CallKit
import Contacts
import Intents

@main struct SystemCallContactChecks {
    static func person(customID: String? = nil, contactID: String? = nil, value: String? = nil,
                       type: INPersonHandleType = .unknown) -> INPerson {
        INPerson(personHandle: INPersonHandle(value: value, type: type), nameComponents: nil,
                 displayName: "Synthetic", image: nil, contactIdentifier: contactID, customIdentifier: customID)
    }

    static func intent(_ contacts: [INPerson], capability: INCallCapability = .audioCall) -> INStartCallIntent {
        INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown,
                          destinationType: .normal, contacts: contacts, callCapability: capability)
    }

    static func rejects(_ operation: () throws -> CallRole) {
        do { _ = try operation(); preconditionFailure("An unknown or ambiguous system contact must not start a call") }
        catch is TincallError { }
        catch { preconditionFailure("Unexpected failure: \(type(of: error))") }
    }

    static func expect(_ role: CallRole, id: UUID) { precondition(role.id == id) }

    static func main() async throws {
        if CommandLine.arguments.contains("--store") {
            let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.txt")
            do {
                try await checkContactStore()
                try "PASS: real Contacts save/readback preserves existing phone and email, migrates the legacy number to one short Tincall number, and repeats without duplicates".write(to: output, atomically: true, encoding: .utf8)
            } catch {
                try "FAIL: \(type(of: error)) \((error as NSError).domain) \((error as NSError).code)".write(to: output, atomically: true, encoding: .utf8)
            }
            return
        }
        var linked = CallRole(name: "")
        let callNumber = SystemCallContact.newPhoneNumber(excluding: [])
        linked.systemCallPhoneNumber = callNumber
        precondition(callNumber.count == 12 && callNumber.hasPrefix("000") && callNumber.allSatisfy(\.isNumber))
        linked.linkedContact = LinkedContact(identifier: "synthetic-contact", name: "Linked caller",
                                             phoneNumber: "+1 (202) 555-0123", phoneNumbers: ["+1 (202) 555-0123", callNumber],
                                             emailAddress: "fixture@example.invalid")
        let other = CallRole(name: "Synthetic")
        let roles = [linked, other]
        let telephoneURL = URL(string: "tel:" + callNumber)!
        guard let telephoneIntent = SystemCallContact.intent(for: telephoneURL) else {
            preconditionFailure("Default calling telephone URLs must reach the call flow without an Intents interaction")
        }
        try expect(SystemCallContact.role(for: telephoneIntent, roles: roles), id: linked.id)
        let contactCardURL = URL(string: "tel://" + callNumber + "?handleType=phoneNumber&contactIdentifier=synthetic-contact&originatingUI=contactCard")!
        try expect(SystemCallContact.role(for: SystemCallContact.intent(for: contactCardURL), roles: roles), id: linked.id)
        try expect(SystemCallContact.role(for: SystemCallContact.intent(for: URL(string: "tel://" + callNumber)!), roles: roles), id: linked.id)
        let formattedURL = URL(string: "tel:+1%20(202)%20555-0123")!
        try expect(SystemCallContact.role(for: SystemCallContact.intent(for: formattedURL), roles: roles), id: linked.id)
        for invalid in ["tincall://call", "tel:", "tel:abc123", "tel:123;456", "tel:123%23", "tel:123?x=1", "tel:12+34",
                        "tel://user@123", "tel://123:456", "tel://123/456", "tel://123#456",
                        "tel://123?handleType=emailAddress", "tel://123?handleType=phoneNumber&handleType=emailAddress"] {
            precondition(SystemCallContact.intent(for: URL(string: invalid)!) == nil)
        }
        let donated = SystemCallContact.person(for: linked)
        precondition(donated.displayName == "Linked caller" && donated.contactIdentifier == "synthetic-contact")
        precondition(donated.customIdentifier == linked.id.uuidString && donated.personHandle?.type == .phoneNumber)
        precondition(donated.personHandle?.value == callNumber)
        try expect(SystemCallContact.role(for: intent([donated]), roles: roles), id: linked.id)
        for email in SystemCallContact.previousEmailAddresses(for: linked.id, number: callNumber) {
            try expect(SystemCallContact.role(for: intent([person(value: email, type: .emailAddress)]), roles: roles), id: linked.id)
        }
        try expect(SystemCallContact.role(for: intent([person(contactID: "synthetic-contact")]), roles: roles), id: linked.id)
        try expect(SystemCallContact.role(for: intent([person(value: "+12025550123", type: .phoneNumber)]), roles: roles), id: linked.id)
        try expect(SystemCallContact.role(for: intent([person(value: "FIXTURE@EXAMPLE.INVALID", type: .emailAddress)]), roles: roles), id: linked.id)
        try expect(SystemCallContact.role(for: INStartAudioCallIntent(destinationType: .normal, contacts: [donated]), roles: roles), id: linked.id)

        var noNumber = linked
        noNumber.linkedContact?.phoneNumber = nil
        noNumber.linkedContact?.emailAddress = nil
        noNumber.linkedContact?.phoneNumbers = [callNumber]
        let noNumberPerson = SystemCallContact.person(for: noNumber)
        precondition(noNumberPerson.contactIdentifier == "synthetic-contact")
        precondition(noNumberPerson.personHandle?.value == callNumber)
        try expect(SystemCallContact.role(for: intent([noNumberPerson]), roles: [noNumber]), id: linked.id)

        var manual = linked
        manual.name = "Manual caller"
        manual.syncSystemContactDetails = false
        precondition(SystemCallContact.person(for: manual).displayName == "Manual caller")
        precondition(SystemCallContact.person(for: manual).contactIdentifier == "synthetic-contact")

        var duplicate = linked
        duplicate.id = UUID()
        let duplicateNumber = SystemCallContact.newPhoneNumber(excluding: [callNumber])
        duplicate.systemCallPhoneNumber = duplicateNumber
        precondition(duplicateNumber != callNumber)
        rejects { try SystemCallContact.role(for: intent([person(contactID: "synthetic-contact")]), roles: [linked, duplicate]) }
        rejects { try SystemCallContact.role(for: intent([person(value: "+12025550123", type: .phoneNumber)]), roles: [linked, duplicate]) }
        try expect(SystemCallContact.role(for: intent([donated]), roles: [linked, duplicate]), id: linked.id)
        try expect(SystemCallContact.role(for: intent([person(contactID: "synthetic-contact", value: callNumber, type: .phoneNumber)]), roles: [linked, duplicate]), id: linked.id)
        try expect(SystemCallContact.role(for: intent([person(contactID: "synthetic-contact", value: duplicateNumber, type: .phoneNumber)]), roles: [linked, duplicate]), id: duplicate.id)
        rejects { try SystemCallContact.role(for: intent([person(contactID: "synthetic-contact", value: SystemCallContact.newPhoneNumber(excluding: [callNumber, duplicateNumber]), type: .phoneNumber)]), roles: roles) }
        rejects { try SystemCallContact.role(for: intent([person(contactID: "different-contact", value: callNumber, type: .phoneNumber)]), roles: roles) }
        var unlinked = linked
        unlinked.unlinkContact()
        rejects { try SystemCallContact.role(for: intent([person(value: callNumber, type: .phoneNumber)]), roles: [unlinked]) }
        rejects { try SystemCallContact.role(for: intent([person(customID: UUID().uuidString, contactID: "synthetic-contact")]), roles: roles) }
        rejects { try SystemCallContact.role(for: intent([person(contactID: "deleted", value: "+12025550123", type: .phoneNumber)]), roles: roles) }
        rejects { try SystemCallContact.role(for: intent([person()]), roles: roles) }
        rejects { try SystemCallContact.role(for: intent([person(value: "5550123", type: .phoneNumber)]), roles: roles) }
        rejects { try SystemCallContact.role(for: intent([donated], capability: .videoCall), roles: roles) }
        rejects { try SystemCallContact.role(for: intent([donated, SystemCallContact.person(for: other)]), roles: roles) }
        rejects { try SystemCallContact.role(for: intent([]), roles: roles) }
        let normalPhone = intent([person(value: "+12025550199", type: .phoneNumber)])
        precondition(SystemCallContact.telephonyURL(for: normalPhone)?.scheme == "telephony")
        precondition(SystemCallContact.telephonyURL(for: normalPhone)?.path == "+12025550199")
        for refused in [intent([donated]), intent([donated], capability: .videoCall),
                        intent([donated, donated]), intent([person(value: "fixture@example.invalid", type: .emailAddress)]),
                        intent([person(value: SystemCallContact.legacyPhoneNumber(for: linked.id), type: .phoneNumber)])] {
            precondition(SystemCallContact.telephonyURL(for: refused) == nil)
        }
        let handler = SystemCallIntentHandler()
        let callbackRecord = INCallRecord(__identifier: UUID().uuidString, dateCreated: Date(), callRecordType: .outgoing,
                                          callCapability: .audioCall, callDuration: 12, unseen: false,
                                          participants: [donated], numberOfCalls: 1, isCallerIdBlocked: false)
        let callback = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: callbackRecord,
                                         audioRoute: .unknown, destinationType: .callBack, contacts: nil,
                                         callCapability: .unknown)
        handler.confirm(intent: callback) {
            precondition($0.code == .ready, "A Recents callback must not require a separate contacts array")
        }
        handler.handle(intent: callback) { precondition($0.code == .continueInApp) }
        try expect(SystemCallContact.role(for: callback, roles: roles), id: linked.id)
        precondition(SystemCallContact.telephonyURL(for: callback) == nil)
        func callbackIntent(_ participants: [INPerson]?, id: String = UUID().uuidString,
                            capability: INCallCapability = .audioCall, contacts: [INPerson]? = nil) -> INStartCallIntent {
            let record = INCallRecord(__identifier: id, dateCreated: Date(), callRecordType: .outgoing,
                                      callCapability: capability, callDuration: 12, unseen: false,
                                      participants: participants, numberOfCalls: 1, isCallerIdBlocked: false)
            return INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: record, audioRoute: .unknown,
                                     destinationType: .callBack, contacts: contacts, callCapability: .unknown)
        }
        let saved = CallRecord(roleID: linked.id, roleName: linked.displayName)
        let identifierCallback = callbackIntent(nil, id: saved.id.uuidString)
        handler.handle(intent: identifierCallback) { precondition($0.code == .continueInApp) }
        try expect(SystemCallContact.role(for: identifierCallback, roles: roles, records: [saved]), id: linked.id)
        rejects { try SystemCallContact.role(for: identifierCallback, roles: roles) }
        rejects { try SystemCallContact.role(for: identifierCallback, roles: [other], records: [saved]) }
        let conflict = callbackIntent([donated], contacts: [SystemCallContact.person(for: other)])
        rejects { try SystemCallContact.role(for: conflict, roles: roles) }
        let filtered = INStartCallIntent(callRecordFilter: INCallRecordFilter(participants: [donated], callTypes: .outgoing,
                                                                            callCapability: .audioCall),
                                         callRecordToCallBack: nil, audioRoute: .unknown, destinationType: .redial,
                                         contacts: nil, callCapability: .unknown)
        handler.confirm(intent: filtered) { precondition($0.code == .ready) }
        try expect(SystemCallContact.role(for: filtered, roles: roles), id: linked.id)
        for invalid in [callbackIntent([donated], capability: .videoCall), callbackIntent([donated, donated]),
                        callbackIntent(nil, id: "unknown")] {
            handler.confirm(intent: invalid) { precondition($0.code == .failure) }
            handler.handle(intent: invalid) { precondition($0.code == .failure) }
            rejects { try SystemCallContact.role(for: invalid, roles: roles) }
        }
        // System callers can leave capability unspecified. An audio-only app
        // must resolve that request to audio rather than reject the recipient.
        let unspecifiedCall = intent([donated], capability: .unknown)
        handler.confirm(intent: unspecifiedCall) {
            precondition($0.code == .ready, "An unspecified call capability must use Tincall's supported audio call")
        }
        handler.handle(intent: unspecifiedCall) { precondition($0.code == .continueInApp) }
        try expect(SystemCallContact.role(for: unspecifiedCall, roles: roles), id: linked.id)
        precondition(SystemCallContact.telephonyURL(for: unspecifiedCall) == nil)
        handler.confirm(intent: intent([donated, donated], capability: .unknown)) { precondition($0.code == .failure) }
        handler.confirm(intent: intent([donated])) { precondition($0.code == .ready) }
        handler.confirm(intent: intent([donated], capability: .videoCall)) { precondition($0.code == .failure) }
        handler.confirm(intent: intent([donated, donated])) { precondition($0.code == .failure) }
        handler.handle(intent: intent([donated])) { response in
            precondition(response.code == .continueInApp && response.userActivity?.activityType == "INStartCallIntent")
        }
        handler.handle(intent: intent([donated], capability: .videoCall)) { precondition($0.code == .failure) }
        handler.handle(intent: intent([donated, donated])) { precondition($0.code == .failure) }
        handler.handle(intent: INStartAudioCallIntent(destinationType: .normal, contacts: [donated])) { response in
            precondition(response.code == .continueInApp && response.userActivity?.activityType == "INStartAudioCallIntent")
        }
        let decoded = try JSONDecoder().decode(CallRole.self, from: JSONEncoder().encode(linked))
        precondition(decoded.systemCallPhoneNumber == callNumber)
        let migration = CNMutableContact()
        migration.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+12025550123"))]
        let oldEmails = SystemCallContact.previousEmailAddresses(for: linked.id, number: callNumber)
        let existingEmails = [CNLabeledValue(label: CNLabelHome, value: "fixture@example.invalid" as NSString),
                              CNLabeledValue(label: CNLabelWork, value: oldEmails[0] as NSString),
                              CNLabeledValue(label: "Tincall", value: "unrelated@example.invalid" as NSString)]
        migration.emailAddresses = existingEmails + oldEmails.map { CNLabeledValue(label: "Tincall", value: $0 as NSString) }
        let migrated = SystemContactReader.addingCallNumbers(to: migration, callNumbers: [linked.id: callNumber])!
        precondition(migrated.emailAddresses == existingEmails, "Only exact app-owned email fields may be removed")
        precondition(migrated.phoneNumbers.count == 2 && migrated.phoneNumbers[0] == migration.phoneNumbers[0])
        precondition(migrated.phoneNumbers[1].label == "Tincall" && migrated.phoneNumbers[1].value.stringValue == callNumber)
        precondition(SystemContactReader.addingCallNumbers(to: migrated, callNumbers: [linked.id: callNumber]) == nil)
        print("PASS: short phone identity restored, experiment emails removed without touching existing fields; old email records still route")
        print("PASS: short addresses persist; native intent continuation and explicit cellular fallback validated")
        print("PASS: linked identities and legacy/modern audio intents route correctly; stale, ambiguous, unknown, video and group requests fail closed")
    }

    static func checkContactStore() async throws {
        let store = CNContactStore()
        let roleID = UUID()
        let number = SystemCallContact.newPhoneNumber(excluding: [])
        let fixture = CNMutableContact()
        fixture.givenName = "Tincall isolated fixture"
        fixture.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+1 202 555 0123")),
                                CNLabeledValue(label: "Tincall", value: CNPhoneNumber(stringValue: SystemCallContact.legacyPhoneNumber(for: roleID)))]
        fixture.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "fixture@example.invalid" as NSString)]
            + SystemCallContact.previousEmailAddresses(for: roleID, number: number).map {
                CNLabeledValue(label: "Tincall", value: $0 as NSString)
            }
        let add = CNSaveRequest()
        add.add(fixture, toContainerWithIdentifier: nil)
        try store.execute(add)
        defer {
            let remove = CNSaveRequest()
            remove.delete(fixture)
            try? store.execute(remove)
        }
        let reader = SystemContactReader()
        _ = try await reader.read(identifier: fixture.identifier, callNumbers: [roleID: number])
        _ = try await reader.read(identifier: fixture.identifier, callNumbers: [roleID: number])
        let result = try store.unifiedContact(withIdentifier: fixture.identifier,
            keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
                          CNContactEmailAddressesKey as CNKeyDescriptor])
        precondition(result.givenName == fixture.givenName)
        precondition(result.emailAddresses.map { String($0.value) } == ["fixture@example.invalid"])
        precondition(result.phoneNumbers.count == 2)
        precondition(result.phoneNumbers[0].value.stringValue == "+1 202 555 0123")
        precondition(result.phoneNumbers[0].label == CNLabelPhoneNumberMobile)
        precondition(result.phoneNumbers[1].label == "Tincall" && result.phoneNumbers[1].value.stringValue == number)
        let plain = CNMutableContact()
        plain.givenName = "No telephone"
        let updated = SystemContactReader.addingCallNumbers(to: plain, callNumbers: [roleID: number])!
        precondition(updated.phoneNumbers.count == 1 && updated.phoneNumbers[0].value.stringValue == number)
        precondition(SystemContactReader.addingCallNumbers(to: updated, callNumbers: [roleID: number]) == nil)
    }
}
