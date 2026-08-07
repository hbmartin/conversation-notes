import ComposableArchitecture
import Foundation

/// Build-time feature gates, injected the same way as the bundled credential:
/// `CONVERSATION_CAPTURE_ENABLED` build setting → `Info.plist` → `Bundle.main.infoDictionary`.
/// A gate is resolved once when the feature's state is created, so it cannot change mid-run.
enum ConversationCaptureFlag {
  private static let infoDictionaryKey = "ConversationCaptureEnabled"

  static var isEnabled: Bool {
    self.isEnabled(from: Bundle.main.infoDictionary ?? [:])
  }

  /// Fails closed: a missing, unsubstituted (`$(CONVERSATION_CAPTURE_ENABLED)`), or unrecognized
  /// value disables conversation capture, so a build-setting typo can never ship the feature by
  /// accident. Info.plist substitution yields the *string* "YES"/"NO", never a plist boolean.
  static func isEnabled(from infoDictionary: [String: Any]) -> Bool {
    guard let raw = infoDictionary[self.infoDictionaryKey] as? String else { return false }
    return ["YES", "1", "true"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

@DependencyClient
struct FeatureFlagsClient: Sendable {
  var isConversationCaptureEnabled: @Sendable () -> Bool = { true }
}

extension FeatureFlagsClient: TestDependencyKey {
  static let previewValue = Self(isConversationCaptureEnabled: { true })

  /// Spelled out rather than left unimplemented so existing tests exercise the feature-on path
  /// without each having to override the dependency; tests for the gate opt in explicitly.
  static let testValue = Self(isConversationCaptureEnabled: { true })
}

extension FeatureFlagsClient: DependencyKey {
  static let liveValue = Self(
    isConversationCaptureEnabled: { ConversationCaptureFlag.isEnabled }
  )
}

extension DependencyValues {
  var featureFlags: FeatureFlagsClient {
    get { self[FeatureFlagsClient.self] }
    set { self[FeatureFlagsClient.self] = newValue }
  }
}
