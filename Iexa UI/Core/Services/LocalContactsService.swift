import Contacts
import Foundation

enum LocalContactsError: LocalizedError {
    case accessDenied
    case contactNotFound

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "需要通讯录权限才能读取本机联系人。"
        case .contactNotFound:
            return "找不到这个本机联系人。"
        }
    }
}

struct LocalContactPhone: Codable, Sendable {
    let label: String
    let value: String
}

struct LocalContactEmail: Codable, Sendable {
    let label: String
    let value: String
}

/// A privacy-scoped representation of a device contact.
///
/// The app intentionally exposes read-only contact operations to the local AI
/// tools. Creating, updating, or deleting contacts would require an explicit
/// user-confirmation UI rather than an autonomous tool call.
struct LocalContact: Codable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let givenName: String
    let familyName: String
    let organizationName: String?
    let phoneNumbers: [LocalContactPhone]
    let emailAddresses: [LocalContactEmail]
}

@MainActor
final class LocalContactsService {
    static let shared = LocalContactsService()

    private let contactStore = CNContactStore()
    private let keysToFetch: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactNamePrefixKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactMiddleNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactNameSuffixKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor
    ]

    private init() {}

    func listContacts(query: String? = nil, limit: Int = 50) async throws -> [LocalContact] {
        try await ensureAccess()
        let maximum = min(max(limit, 1), 100)
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !trimmedQuery.isEmpty {
            let predicate = CNContact.predicateForContacts(matchingName: trimmedQuery)
            return try contactStore
                .unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
                .map(mapContact)
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                .prefix(maximum)
                .map { $0 }
        }

        var contacts: [LocalContact] = []
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        request.sortOrder = .userDefault
        try contactStore.enumerateContacts(with: request) { [weak self] contact, stop in
            guard let self else {
                stop.pointee = true
                return
            }
            contacts.append(self.mapContact(contact))
            if contacts.count >= maximum {
                stop.pointee = true
            }
        }
        return contacts
    }

    func contact(id: String) async throws -> LocalContact {
        try await ensureAccess()
        do {
            let contact = try contactStore.unifiedContact(withIdentifier: id, keysToFetch: keysToFetch)
            return mapContact(contact)
        } catch let error as CNError where error.code == .recordDoesNotExist {
            throw LocalContactsError.contactNotFound
        }
    }

    private func ensureAccess() async throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return
        case .notDetermined:
            let granted = try await requestAccess()
            if granted { return }
            throw LocalContactsError.accessDenied
        case .denied, .restricted:
            throw LocalContactsError.accessDenied
        @unknown default:
            throw LocalContactsError.accessDenied
        }
    }

    private func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            contactStore.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func mapContact(_ contact: CNContact) -> LocalContact {
        let displayName = displayName(for: contact)
        let fallbackName = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalContact(
            id: contact.identifier,
            displayName: displayName.isEmpty ? (fallbackName.isEmpty ? "未命名联系人" : fallbackName) : displayName,
            givenName: contact.givenName,
            familyName: contact.familyName,
            organizationName: contact.organizationName.isEmpty ? nil : contact.organizationName,
            phoneNumbers: contact.phoneNumbers.map {
                LocalContactPhone(label: localizedLabel($0.label), value: $0.value.stringValue)
            },
            emailAddresses: contact.emailAddresses.map {
                LocalContactEmail(label: localizedLabel($0.label), value: String($0.value))
            }
        )
    }

    private func displayName(for contact: CNContact) -> String {
        let name = [
            contact.namePrefix,
            contact.givenName,
            contact.middleName,
            contact.familyName,
            contact.nameSuffix
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return name
        }

        let nickname = contact.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nickname.isEmpty {
            return nickname
        }

        return ""
    }

    private func localizedLabel(_ label: String?) -> String {
        CNLabeledValue<NSString>.localizedString(forLabel: label ?? CNLabelOther)
    }
}
