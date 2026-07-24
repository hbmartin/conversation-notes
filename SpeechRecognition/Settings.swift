import ComposableArchitecture
import SwiftUI

@Reducer
struct Settings {
  @ObservableState
  struct State: Equatable {
    var apiKey = ""
    var didSave = false
    var errorMessage: String?
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
        state.apiKey = (try? self.apiKeyClient.load()) ?? ""
        return .none

      case .saveTapped:
        do {
          try self.apiKeyClient.save(state.apiKey)
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
        Section {
          SecureField("sk-ant-…", text: $store.apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
          Text("Anthropic API Key")
        } footer: {
          Text(
            "Used for conversation summaries and guided interviews. Stored in the Keychain on this device only."
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
          if let errorMessage = store.errorMessage {
            Text(errorMessage).foregroundStyle(.red)
          }
          Button("Remove Key", role: .destructive) {
            store.send(.deleteTapped)
          }
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
