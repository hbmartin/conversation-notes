import ComposableArchitecture
import Foundation
import Testing

@testable import SpeechRecognition

@MainActor
struct AppIconTests {
  @Test
  func alternateIconNamesRoundTrip() {
    for variant in AppIconVariant.allCases {
      #expect(AppIconVariant(alternateIconName: variant.alternateIconName) == variant)
    }
    // The primary icon is the absence of an alternate, and an icon this build no longer ships
    // falls back to it rather than leaving Settings with nothing selected.
    #expect(AppIconVariant.wovenIris.alternateIconName == nil)
    #expect(AppIconVariant(alternateIconName: "AppIconRetired") == .wovenIris)
  }

  /// The names must match `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` in the project, which is
  /// what registers them with UIKit.
  @Test
  func assetNamesMatchTheAssetCatalog() {
    #expect(
      AppIconVariant.allCases.map(\.assetName) == [
        "AppIcon", "AppIconThreadAperture", "AppIconBraidedBloom", "AppIconWovenIrisInverted",
      ]
    )
  }

  @Test
  func openingSettingsShowsTheIconInUse() async {
    let store = TestStore(initialState: Settings.State()) {
      Settings()
    } withDependencies: {
      $0.apiKeyClient.load = { nil }
      $0.apiKeyClient.loadBundled = { nil }
      $0.appIconClient.current = { .braidedBloom }
      $0.appIconClient.isSupported = { true }
    }

    await store.send(.onAppear)
    await store.receive(\.appIconLoaded) {
      $0.appIcon = .braidedBloom
      $0.canChooseAppIcon = true
    }
  }

  @Test
  func choosingAnIconSwitchesIt() async {
    let selected = LockIsolated<[AppIconVariant]>([])
    let store = TestStore(initialState: Settings.State()) {
      Settings()
    } withDependencies: {
      $0.appIconClient.select = { variant in selected.withValue { $0.append(variant) } }
    }

    await store.send(.appIconTapped(.threadAperture)) {
      $0.appIcon = .threadAperture
    }
    #expect(selected.value == [.threadAperture])

    // Tapping the icon already in use would still pop the system alert, so it does nothing.
    await store.send(.appIconTapped(.threadAperture))
    #expect(selected.value == [.threadAperture])
  }

  @Test
  func aRefusedSwitchPutsTheSelectionBack() async {
    struct IconError: Error {}
    let store = TestStore(initialState: Settings.State()) {
      Settings()
    } withDependencies: {
      $0.appIconClient.select = { _ in throw IconError() }
    }

    await store.send(.appIconTapped(.wovenIrisInverted)) {
      $0.appIcon = .wovenIrisInverted
    }
    await store.receive(\.appIconSelectionFailed) {
      $0.appIcon = .wovenIris
      $0.appIconErrorMessage = "The app icon could not be changed."
    }
  }
}
