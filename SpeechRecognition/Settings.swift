import ComposableArchitecture
import Foundation
import SwiftUI

@Reducer
struct Settings {
  @ObservableState
  struct State: Equatable {
    var apiKey = ""
    var credentialSource = CredentialSource.missing
    var didSave = false
    var errorMessage: String?
  }

  enum CredentialSource: Equatable {
    case operatorKey
    case bundled
    case missing

    var title: String {
      switch self {
      case .operatorKey: "Operator key"
      case .bundled: "Bundled test key"
      case .missing: "Missing"
      }
    }

    var systemImage: String {
      switch self {
      case .operatorKey: "key.fill"
      case .bundled: "shippingbox.fill"
      case .missing: "exclamationmark.triangle.fill"
      }
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case onAppear
    case saveTapped
    case deleteTapped
  }

  @Dependency(\.apiKeyClient) var apiKeyClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.didSave = false
        state.errorMessage = nil
        return .none

      case .onAppear:
        let operatorKey = normalizedAPIKey((try? self.apiKeyClient.load()) ?? nil)
        let bundledKey = normalizedAPIKey(self.apiKeyClient.loadBundled())
        state.apiKey = operatorKey ?? ""
        state.credentialSource = operatorKey != nil ? .operatorKey : bundledKey != nil ? .bundled : .missing
        return .none

      case .saveTapped:
        guard let key = normalizedAPIKey(state.apiKey) else { return .none }
        do {
          try self.apiKeyClient.save(key)
          state.apiKey = key
          state.credentialSource = .operatorKey
          state.didSave = true
        } catch {
          state.didSave = false
          state.errorMessage = "The API key could not be saved."
        }
        return .none

      case .deleteTapped:
        do {
          try self.apiKeyClient.delete()
          state.apiKey = ""
          state.credentialSource = normalizedAPIKey(self.apiKeyClient.loadBundled()) == nil
            ? .missing : .bundled
          state.didSave = false
        } catch {
          state.errorMessage = "The API key could not be removed."
        }
        return .none
      }
    }
  }
}

struct SettingsView: View {
  @Bindable var store: StoreOf<Settings>

  var body: some View {
    AuroraScreen {
      Form {
        Section("Active Credential") {
          Label(store.credentialSource.title, systemImage: store.credentialSource.systemImage)
            .foregroundStyle(store.credentialSource == .missing ? .orange : .primary)
        }

        Section {
          SecureField("sk-ant-…", text: $store.apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
          Text("Anthropic API Key")
        } footer: {
          Text(
            "Used for conversation summaries and guided interviews. A saved operator key is stored in this device's Keychain and overrides any bundled test key."
          )
        }

        Section {
          Button("Save") {
            store.send(.saveTapped)
          }
          .disabled(normalizedAPIKey(store.apiKey) == nil)
          if store.didSave {
            Label("Saved", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          }
          if let errorMessage = store.errorMessage {
            Text(errorMessage).foregroundStyle(.red)
          }
          Button("Remove Operator Key", role: .destructive) {
            store.send(.deleteTapped)
          }
          .disabled(store.credentialSource != .operatorKey)
        }
      }
      .scrollContentBackground(.hidden)
    }
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .onAppear {
      store.send(.onAppear)
    }
  }
}
