import ComposableArchitecture
import Foundation
import Testing

@testable import SpeechRecognition

struct BundledAPIKeyPayloadTests {
  @Test
  func roundTripsASCIIAndUnicode() throws {
    for key in ["sk-ant-test", "clé-🔐-テスト"] {
      let bytes = Array(key.utf8)
      let mask = bytes.indices.map { UInt8(truncatingIfNeeded: $0 * 37 + 11) }
      let payload = try BundledAPIKeyPayload.encode(key, mask: mask)

      #expect(BundledAPIKeyPayload.decode(payload) == key)
      #expect(!payload.contains(key))
    }
  }

  @Test
  func rejectsEmptyKeyAndWrongMaskLength() {
    #expect(throws: BundledAPIKeyPayload.EncodingError.emptyKey) {
      try BundledAPIKeyPayload.encode("", mask: [])
    }
    #expect(throws: BundledAPIKeyPayload.EncodingError.maskLengthMismatch) {
      try BundledAPIKeyPayload.encode("key", mask: [0])
    }
  }

  @Test(
    arguments: [
      "",
      "v2.00.00",
      "v1..",
      "v1.0.00",
      "v1.gg.00",
      "v1.0000.00",
      "v1.00.00.extra",
    ])
  func rejectsMalformedPayload(_ payload: String) {
    #expect(BundledAPIKeyPayload.decode(payload) == nil)
  }

  @Test
  func rejectsNonUTF8Plaintext() {
    // 0xff XOR 0x00 remains an invalid single-byte UTF-8 sequence.
    #expect(BundledAPIKeyPayload.decode("v1.00.ff") == nil)
  }
}

struct APIKeyResolutionTests {
  @Test
  func keychainOverridesBundledKey() {
    let client = APIKeyClient(
      load: { "  operator-key\n" },
      loadBundled: { "bundled-key" },
      save: { _ in },
      delete: {}
    )

    #expect(client.resolvedKey() == "operator-key")
  }

  @Test
  func bundledKeyIsFallback() {
    let client = APIKeyClient(
      load: { " \n" },
      loadBundled: { " bundled-key " },
      save: { _ in },
      delete: {}
    )

    #expect(client.resolvedKey() == "bundled-key")
  }

  @Test
  func keychainReadFailureFallsBackToBundledKey() {
    struct LoadError: Error {}
    let client = APIKeyClient(
      load: { throw LoadError() },
      loadBundled: { "bundled-key" },
      save: { _ in },
      delete: {}
    )

    #expect(client.resolvedKey() == "bundled-key")
  }

  @Test
  func missingWhenBothSourcesAreBlank() {
    let client = APIKeyClient(
      load: { nil },
      loadBundled: { "" },
      save: { _ in },
      delete: {}
    )

    #expect(client.resolvedKey() == nil)
  }
}

@MainActor
struct SettingsCredentialSourceTests {
  @Test
  func presentsBundledSourceWithoutShowingBundledValue() async {
    let store = TestStore(initialState: Settings.State()) {
      Settings()
    } withDependencies: {
      $0.apiKeyClient.load = { nil }
      $0.apiKeyClient.loadBundled = { "bundled-key" }
    }

    await store.send(.onAppear) {
      $0.apiKey = ""
      $0.credentialSource = .bundled
    }
  }

  @Test
  func operatorKeyOverridesBundledSource() async {
    let store = TestStore(initialState: Settings.State()) {
      Settings()
    } withDependencies: {
      $0.apiKeyClient.load = { "operator-key" }
      $0.apiKeyClient.loadBundled = { "bundled-key" }
    }

    await store.send(.onAppear) {
      $0.apiKey = "operator-key"
      $0.credentialSource = .operatorKey
    }
  }

  @Test
  func removingOperatorKeyFallsBackToBundledSource() async {
    let deleted = LockIsolated(false)
    let store = TestStore(
      initialState: Settings.State(
        apiKey: "operator-key",
        credentialSource: .operatorKey
      )
    ) {
      Settings()
    } withDependencies: {
      $0.apiKeyClient.loadBundled = { "bundled-key" }
      $0.apiKeyClient.delete = { deleted.setValue(true) }
    }

    await store.send(.deleteTapped) {
      $0.apiKey = ""
      $0.credentialSource = .bundled
    }
    #expect(deleted.value)
  }

  @Test
  func missingSourceWhenNoCredentialExists() async {
    let store = TestStore(initialState: Settings.State(credentialSource: .bundled)) {
      Settings()
    } withDependencies: {
      $0.apiKeyClient.load = { nil }
      $0.apiKeyClient.loadBundled = { nil }
    }

    await store.send(.onAppear) {
      $0.credentialSource = .missing
    }
  }
}
