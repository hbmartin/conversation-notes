import ComposableArchitecture
import Foundation
import Security

/// Stores the operator's Anthropic API key in the Keychain
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: encrypted at rest, never leaves the
/// device in a backup, rotatable without a rebuild).
@DependencyClient
struct APIKeyClient: Sendable {
  var load: @Sendable () throws -> String?
  var loadBundled: @Sendable () -> String?
  var save: @Sendable (_ key: String) throws -> Void
  var delete: @Sendable () throws -> Void
}

struct KeychainError: Error, Equatable {
  var status: OSStatus
}

extension APIKeyClient: TestDependencyKey {
  static var previewValue: Self {
    let stored = LockIsolated<String?>("sk-ant-preview")
    return Self(
      load: { stored.value },
      loadBundled: { nil },
      save: { stored.setValue($0) },
      delete: { stored.setValue(nil) }
    )
  }

  static let testValue = Self()
}

extension APIKeyClient: DependencyKey {
  static var liveValue: Self {
    let service = "msl-capture.anthropic-api-key"
    @Sendable func baseQuery() -> [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
      ]
    }
    return Self(
      load: {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
          guard let data = result as? Data else { return nil }
          return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
          return nil
        default:
          throw KeychainError(status: status)
        }
      },
      loadBundled: {
        BundledAPIKey.load()
      },
      save: { key in
        let data = Data(key.utf8)
        var query = baseQuery()
        let updateStatus = SecItemUpdate(
          query as CFDictionary,
          [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
          return
        case errSecItemNotFound:
          query[kSecValueData as String] = data
          query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
          let addStatus = SecItemAdd(query as CFDictionary, nil)
          guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
          throw KeychainError(status: updateStatus)
        }
      },
      delete: {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
          throw KeychainError(status: status)
        }
      }
    )
  }
}

extension APIKeyClient {
  /// Returns an operator-provided Keychain credential when present, otherwise the credential
  /// bundled into Debug/TestFlight builds. The bundled value is never copied into Keychain.
  func resolvedKey() -> String? {
    let operatorKey = normalizedAPIKey((try? self.load()) ?? nil)
    return operatorKey ?? normalizedAPIKey(self.loadBundled())
  }
}

func normalizedAPIKey(_ value: String?) -> String? {
  guard let value else { return nil }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

extension DependencyValues {
  var apiKeyClient: APIKeyClient {
    get { self[APIKeyClient.self] }
    set { self[APIKeyClient.self] = newValue }
  }
}
