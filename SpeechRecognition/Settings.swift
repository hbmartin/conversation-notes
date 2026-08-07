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
    var appIcon = AppIconVariant.wovenIris
    var canChooseAppIcon = false
    var appIconErrorMessage: String?
  }

  enum CredentialSource: Equatable {
    case operatorKey
    case operatorKeyUnavailable
    case bundled
    case missing

    var title: String {
      switch self {
      case .operatorKey: "Operator key"
      case .operatorKeyUnavailable: "Operator key unavailable"
      case .bundled: "Bundled test key"
      case .missing: "Missing"
      }
    }

    var systemImage: String {
      switch self {
      case .operatorKey: "key.fill"
      case .operatorKeyUnavailable: "exclamationmark.lock.fill"
      case .bundled: "shippingbox.fill"
      case .missing: "exclamationmark.triangle.fill"
      }
    }

    var canRemoveOperatorKey: Bool {
      self == .operatorKey || self == .operatorKeyUnavailable
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case onAppear
    case saveTapped
    case deleteTapped
    case appIconLoaded(AppIconVariant, canChoose: Bool)
    case appIconTapped(AppIconVariant)
    case appIconSelectionFailed(revertingTo: AppIconVariant)
  }

  @Dependency(\.apiKeyClient) var apiKeyClient
  @Dependency(\.appIconClient) var appIconClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.didSave = false
        state.errorMessage = nil
        return .none

      case .onAppear:
        state.errorMessage = nil
        do {
          let operatorKey = normalizedAPIKey(try self.apiKeyClient.load())
          let bundledKey = normalizedAPIKey(self.apiKeyClient.loadBundled())
          state.apiKey = operatorKey ?? ""
          state.credentialSource = operatorKey != nil
            ? .operatorKey : bundledKey != nil ? .bundled : .missing
        } catch {
          state.apiKey = ""
          state.credentialSource = .operatorKeyUnavailable
          state.errorMessage = "The operator key could not be read."
        }
        return .run { send in
          await send(
            .appIconLoaded(self.appIconClient.current(), canChoose: self.appIconClient.isSupported())
          )
        }

      case let .appIconLoaded(variant, canChoose):
        state.appIcon = variant
        state.canChooseAppIcon = canChoose
        return .none

      case let .appIconTapped(variant):
        guard state.appIcon != variant else { return .none }
        let previous = state.appIcon
        // Move the checkmark straight away and put it back if the switch is refused, so the list
        // never shows a selection the home screen does not have.
        state.appIcon = variant
        state.appIconErrorMessage = nil
        return .run { _ in
          try await self.appIconClient.select(variant)
        } catch: { _, send in
          await send(.appIconSelectionFailed(revertingTo: previous))
        }

      case let .appIconSelectionFailed(previous):
        state.appIcon = previous
        state.appIconErrorMessage = "The app icon could not be changed."
        return .none

      case .saveTapped:
        guard let key = normalizedAPIKey(state.apiKey) else { return .none }
        do {
          try self.apiKeyClient.save(key)
          state.apiKey = key
          state.credentialSource = .operatorKey
          state.didSave = true
          state.errorMessage = nil
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
          state.errorMessage = nil
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
          .disabled(!store.credentialSource.canRemoveOperatorKey)
        }

        if store.canChooseAppIcon {
          Section {
            ForEach(AppIconVariant.allCases) { variant in
              Button {
                store.send(.appIconTapped(variant))
              } label: {
                HStack(spacing: 12) {
                  AppIconPreview(variant: variant)
                  Text(variant.displayName)
                    .foregroundStyle(.primary)
                  Spacer(minLength: 8)
                  if store.appIcon == variant {
                    Image(systemName: "checkmark")
                      .fontWeight(.semibold)
                      .foregroundStyle(.tint)
                  }
                }
              }
              .accessibilityAddTraits(store.appIcon == variant ? .isSelected : [])
            }
          } header: {
            Text("App Icon")
          } footer: {
            if let appIconErrorMessage = store.appIconErrorMessage {
              Text(appIconErrorMessage).foregroundStyle(.red)
            }
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

/// Draws an icon at any size from the same artwork the asset catalog is rendered from, so the
/// choices in Settings cannot drift from what lands on the home screen.
struct AppIconPreview: View {
  let variant: AppIconVariant
  var side: CGFloat = 46

  /// iOS masks icons with a squircle a little over a fifth of the icon's width across.
  private var cornerRadius: CGFloat { self.side * 0.2237 }

  var body: some View {
    Canvas { context, size in
      context.withCGContext { cgContext in
        AppIconArtwork.draw(self.variant, in: cgContext, size: min(size.width, size.height))
      }
    }
    .frame(width: self.side, height: self.side)
    .clipShape(RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
        .strokeBorder(.primary.opacity(0.12))
    }
    .accessibilityHidden(true)
  }
}
