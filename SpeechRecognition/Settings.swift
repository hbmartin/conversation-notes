import ComposableArchitecture
import SwiftUI

@Reducer
struct Settings {
  @ObservableState
  struct State: Equatable {
    var apiKey = ""
    var didSave = false
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
        return .none

      case .onAppear:
        state.apiKey = (try? self.apiKeyClient.load()) ?? ""
        return .none

      case .saveTapped:
        try? self.apiKeyClient.save(state.apiKey)
        state.didSave = true
        return .none

      case .deleteTapped:
        try? self.apiKeyClient.delete()
        state.apiKey = ""
        state.didSave = false
        return .none
      }
    }
  }
}

struct SettingsView: View {
  @Bindable var store: StoreOf<Settings>

  var body: some View {
    Form {
      Section {
        SecureField("sk-ant-…", text: $store.apiKey)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      } header: {
        Text("Anthropic API Key")
      } footer: {
        Text(
          "Used for summarization and the post-conversation interview. Stored in the Keychain on this device only."
        )
      }

      Section {
        Button("Save") {
          store.send(.saveTapped)
        }
        .disabled(store.apiKey.isEmpty)
        if store.didSave {
          Label("Saved", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
        Button("Remove Key", role: .destructive) {
          store.send(.deleteTapped)
        }
      }
    }
    .navigationTitle("Settings")
    .onAppear {
      store.send(.onAppear)
    }
  }
}
