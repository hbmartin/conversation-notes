import ComposableArchitecture
import SwiftUI

@main
struct SpeechRecognitionApp: App {
  @MainActor
  static let store = Store(initialState: AppFeature.State()) {
    #if DEBUG
      AppFeature()
        ._printChanges()
    #else
      AppFeature()
    #endif
  }

  var body: some Scene {
    WindowGroup {
      AppView(store: Self.store)
    }
  }
}
