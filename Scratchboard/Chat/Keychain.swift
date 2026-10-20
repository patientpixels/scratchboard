import Foundation
import Security

protocol SecretStore: AnyObject {
  func string(for account: String) -> String?
  // Setting an empty string deletes the item.
  func set(_ value: String, for account: String) throws
  func delete(_ account: String) throws
}

struct KeychainError: LocalizedError, Equatable {
  let status: OSStatus

  var errorDescription: String? {
    SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
  }
}

// Generic-password items scoped to the app's bundle identifier.
final class Keychain: SecretStore {
  static let aiAPIKey = "aiAPIKey"

  // Replaced in tests.
  static var shared: any SecretStore = Keychain()

  let service: String

  init(service: String = Bundle.main.bundleIdentifier ?? "com.oliverspindler.Scratchboard") {
    self.service = service
  }

  func string(for account: String) -> String? {
    var query = baseQuery(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  func set(_ value: String, for account: String) throws {
    guard !value.isEmpty else {
      try delete(account)
      return
    }

    let data = Data(value.utf8)
    let query = baseQuery(account)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    switch status {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      let addStatus = SecItemAdd(item as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    default:
      throw KeychainError(status: status)
    }
  }

  func delete(_ account: String) throws {
    let status = SecItemDelete(baseQuery(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }

  private func baseQuery(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
  }
}

final class InMemorySecretStore: SecretStore {
  private(set) var values: [String: String]

  init(_ values: [String: String] = [:]) {
    self.values = values
  }

  func string(for account: String) -> String? {
    values[account]
  }

  func set(_ value: String, for account: String) throws {
    values[account] = value.isEmpty ? nil : value
  }

  func delete(_ account: String) throws {
    values[account] = nil
  }
}
