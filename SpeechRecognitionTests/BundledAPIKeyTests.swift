import ComposableArchitecture
import Foundation
import Testing

@testable import SpeechRecognition

struct BundledAPIKeyPayloadTests {
  @Test
  func roundTripsAnthropicKeyASCII() throws {
    for key in ["sk-ant-test", "sk-ant-KEY_123"] {
      let bytes = Array(key.utf8)
      let mask = bytes.indices.map { UInt8(truncatingIfNeeded: $0 * 37 + 11) }
      let payload = try BundledAPIKeyPayload.encode(key, mask: mask)

      #expect(BundledAPIKeyPayload.decode(payload) == key)
      #expect(!payload.contains(key))
    }
  }

  @Test
  func rejectsEmptyInvalidAndWrongMaskLength() {
    #expect(throws: BundledAPIKeyPayload.EncodingError.emptyKey) {
      try BundledAPIKeyPayload.encode("", mask: [])
    }
    #expect(throws: BundledAPIKeyPayload.EncodingError.invalidKey) {
      try BundledAPIKeyPayload.encode("sk-ant-🔐", mask: [UInt8](repeating: 0, count: 11))
    }
    #expect(throws: BundledAPIKeyPayload.EncodingError.maskLengthMismatch) {
      try BundledAPIKeyPayload.encode("sk-ant-key", mask: [0])
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
      "v1.0000000000000000000000.736b2d616e742d74657374.",
      "v1.0000000000000000000000.736b2d616e742df09f9490",
    ])
  func rejectsMalformedPayload(_ payload: String) {
    #expect(BundledAPIKeyPayload.decode(payload) == nil)
  }

  @Test
  func rejectsNonUTF8Plaintext() {
    // 0xff XOR 0x00 remains an invalid single-byte UTF-8 sequence.
    #expect(BundledAPIKeyPayload.decode("v1.00.ff") == nil)
  }

  @Test
  func loadsValidPayloadFromInfoDictionary() throws {
    let key = "sk-ant-test"
    let payload = try BundledAPIKeyPayload.encode(
      key,
      mask: [UInt8](repeating: 0, count: key.utf8.count)
    )

    #expect(
      BundledAPIKey.load(from: ["BundledAnthropicAPIKeyPayload": payload]) == key
    )
    #expect(BundledAPIKey.load(from: [:]) == nil)
    #expect(
      BundledAPIKey.load(from: ["BundledAnthropicAPIKeyPayload": "malformed"]) == nil
    )
  }
}

struct APIKeyResolutionTests {
  @Test
  func keychainOverridesBundledKey() throws {
    let client = APIKeyClient(
      load: { "  operator-key\n" },
      loadBundled: { "bundled-key" },
      save: { _ in },
      delete: {}
    )

    #expect(try client.resolvedKey() == "operator-key")
  }

  @Test
  func bundledKeyIsFallback() throws {
    let client = APIKeyClient(
      load: { " \n" },
      loadBundled: { " bundled-key " },
      save: { _ in },
      delete: {}
    )

    #expect(try client.resolvedKey() == "bundled-key")
  }

  @Test
  func keychainReadFailureDoesNotChangeCredentialSource() {
    struct LoadError: Error {}
    let client = APIKeyClient(
      load: { throw LoadError() },
      loadBundled: { "bundled-key" },
      save: { _ in },
      delete: {}
    )

    #expect(throws: LoadError.self) {
      try client.resolvedKey()
    }
  }

  @Test
  func missingWhenBothSourcesAreBlank() throws {
    let client = APIKeyClient(
      load: { nil },
      loadBundled: { "" },
      save: { _ in },
      delete: {}
    )

    #expect(try client.resolvedKey() == nil)
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

  @Test
  func keychainReadFailureIsPresentedWithoutUsingBundledSource() async {
    struct LoadError: Error {}
    let store = TestStore(initialState: Settings.State()) {
      Settings()
    } withDependencies: {
      $0.apiKeyClient.load = { throw LoadError() }
      $0.apiKeyClient.loadBundled = { "bundled-key" }
    }

    await store.send(.onAppear) {
      $0.credentialSource = .operatorKeyUnavailable
      $0.errorMessage = "The operator key could not be read."
    }
    #expect(store.state.credentialSource.canRemoveOperatorKey)
  }

  @Test
  func removesOperatorKeyWhenItsReadStateIsUnavailable() async {
    let deleted = LockIsolated(false)
    let store = TestStore(
      initialState: Settings.State(
        credentialSource: .operatorKeyUnavailable,
        errorMessage: "The operator key could not be read."
      )
    ) {
      Settings()
    } withDependencies: {
      $0.apiKeyClient.loadBundled = { "bundled-key" }
      $0.apiKeyClient.delete = { deleted.setValue(true) }
    }

    await store.send(.deleteTapped) {
      $0.credentialSource = .bundled
      $0.errorMessage = nil
    }
    #expect(deleted.value)
  }

  @Test
  func trimsOperatorKeyBeforeSaving() async {
    let saved = LockIsolated<String?>(nil)
    let store = TestStore(initialState: Settings.State(apiKey: "  sk-ant-operator\n")) {
      Settings()
    } withDependencies: {
      $0.apiKeyClient.save = { saved.setValue($0) }
    }

    await store.send(.saveTapped) {
      $0.apiKey = "sk-ant-operator"
      $0.credentialSource = .operatorKey
      $0.didSave = true
    }
    #expect(saved.value == "sk-ant-operator")
  }

  @Test
  func blankOperatorKeyDoesNotSave() async {
    let didSave = LockIsolated(false)
    let store = TestStore(initialState: Settings.State(apiKey: " \n")) {
      Settings()
    } withDependencies: {
      $0.apiKeyClient.save = { _ in didSave.setValue(true) }
    }

    await store.send(.saveTapped)
    #expect(!didSave.value)
  }

  @Test
  func saveFailureIsPresented() async {
    struct SaveError: Error {}
    let store = TestStore(initialState: Settings.State(apiKey: "sk-ant-operator")) {
      Settings()
    } withDependencies: {
      $0.apiKeyClient.save = { _ in throw SaveError() }
    }

    await store.send(.saveTapped) {
      $0.errorMessage = "The API key could not be saved."
    }
  }
}
