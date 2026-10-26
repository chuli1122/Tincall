// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Contacts
import Foundation

actor SystemContactReader {
    private let store = CNContactStore()
    private let keys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactThumbnailImageDataKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor
    ]

    /// Only the explicit link toggle may request permission; refresh never prompts.
    func requestAccess() async throws -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            do { return try await store.requestAccess(for: .contacts) }
            catch { throw TincallError(message: String(localized: "通讯录授权请求失败（\((error as NSError).code)）")) }
        @unknown default:
            throw TincallError(message: String(localized: "无法确认通讯录授权状态"))
        }
    }

    /// Use this store's identifiers for ongoing links. The system picker can return
    /// identifiers that are not readable through the app's limited-access store.
    /// Names, thumbnails and CallKit matching handles are fetched; unnamed contacts cannot be linked.
    func availableContacts() throws -> [LinkedContact] {
        try checkAccess()
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var contacts: [LinkedContact] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let snapshot = Self.snapshot(from: contact)
                if !snapshot.name.isEmpty { contacts.append(snapshot) }
            }
        } catch {
            throw TincallError(message: String(localized: "暂时无法读取联系人列表，请稍后重试。"))
        }
        return contacts
    }

    /// Reads the selected contact. Saved links may also add their local call numbers.
    /// Never requests access or logs contact identifiers; existing fields are preserved.
    func read(identifier: String, callNumbers: [UUID: String] = [:]) throws -> LinkedContact {
        try checkAccess()
        var contact: CNContact
        do {
            contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
        } catch {
            let failure = error as NSError
            if failure.domain == CNErrorDomain, failure.code == CNError.Code.recordDoesNotExist.rawValue {
                throw TincallError(message: String(localized: "此关联已失效或不在授权范围内，请重新选择联系人。若列表中没有，请先管理可访问的联系人。"))
            }
            throw TincallError(message: String(localized: "暂时无法更新联系人，已保留原资料，请稍后重试。"))
        }
        var snapshot = Self.snapshot(from: contact)
        guard !snapshot.name.isEmpty else {
            throw TincallError(message: String(localized: "所选系统联系人没有姓名，请选择有姓名的联系人"))
        }
        if let updated = Self.addingCallNumbers(to: contact, callNumbers: callNumbers) {
            do {
                let request = CNSaveRequest()
                request.update(updated)
                try store.execute(request)
                contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
                snapshot = Self.snapshot(from: contact)
                guard callNumbers.values.allSatisfy({ number in
                    snapshot.phoneNumbers?.contains(number) == true
                }) else { throw TincallError(message: "contact_number_not_saved") }
                guard callNumbers.allSatisfy({ id, number in
                    let oldAddresses = SystemCallContact.previousEmailAddresses(for: id, number: number)
                    return !contact.emailAddresses.contains { field in
                        field.label == "Tincall" && oldAddresses.contains {
                            $0.caseInsensitiveCompare(String(field.value)) == .orderedSame
                        }
                    }
                }) else { throw TincallError(message: "contact_email_not_removed") }
            } catch {
                throw TincallError(message: String(localized: "无法写入 Tincall 通话号码，原有号码未改动。请检查通讯录权限，或联系人是否只读。"))
            }
        }
        return snapshot
    }

    nonisolated static func addingCallNumbers(to contact: CNContact, callNumbers: [UUID: String]) -> CNMutableContact? {
        let updated = contact.mutableCopy() as! CNMutableContact
        var changed = false
        for (id, number) in callNumbers {
            let oldAddresses = SystemCallContact.previousEmailAddresses(for: id, number: number)
            let emailCount = updated.emailAddresses.count
            updated.emailAddresses.removeAll { field in
                field.label == "Tincall" && oldAddresses.contains {
                    $0.caseInsensitiveCompare(String(field.value)) == .orderedSame
                }
            }
            changed = changed || emailCount != updated.emailAddresses.count
            let legacy = SystemCallContact.legacyPhoneNumber(for: id)
            let previousCount = updated.phoneNumbers.count
            updated.phoneNumbers.removeAll { $0.label == "Tincall" && $0.value.stringValue == legacy }
            changed = changed || previousCount != updated.phoneNumbers.count
            guard !updated.phoneNumbers.contains(where: { $0.value.stringValue == number }) else { continue }
            updated.phoneNumbers.append(CNLabeledValue(label: "Tincall", value: CNPhoneNumber(stringValue: number)))
            changed = true
        }
        return changed ? updated : nil
    }

    private func checkAccess() throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || status == .limited else {
            throw TincallError(message: String(localized: "没有读取所选联系人的通讯录权限，请在系统设置中允许访问。"))
        }
    }

    private nonisolated static func snapshot(from contact: CNContact) -> LinkedContact {
        let familyName = contact.isKeyAvailable(CNContactFamilyNameKey) ? contact.familyName : ""
        let givenName = contact.isKeyAvailable(CNContactGivenNameKey) ? contact.givenName : ""
        let formattedName = contact.areKeysAvailable([CNContactFormatter.descriptorForRequiredKeys(for: .fullName)])
            ? CNContactFormatter.string(from: contact, style: .fullName)
            : familyName + givenName
        return LinkedContact(identifier: contact.identifier,
                             name: (formattedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                             avatarData: contact.isKeyAvailable(CNContactThumbnailImageDataKey) ? contact.thumbnailImageData : nil,
                             familyName: familyName, givenName: givenName,
                             phoneNumber: contact.isKeyAvailable(CNContactPhoneNumbersKey)
                                ? contact.phoneNumbers.first(where: { !$0.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.value.stringValue : nil,
                             phoneNumbers: contact.isKeyAvailable(CNContactPhoneNumbersKey)
                                ? contact.phoneNumbers.map { $0.value.stringValue } : nil,
                             emailAddress: contact.isKeyAvailable(CNContactEmailAddressesKey)
                                ? contact.emailAddresses.first(where: { !String($0.value).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).map { String($0.value) } : nil)
    }
}
