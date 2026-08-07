import ComposableArchitecture
import Foundation
import UIKit

/// Reads and switches the home-screen icon.
///
/// The alternates are declared by the asset catalog through
/// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`, so the names UIKit expects are exactly the icon
/// sets' names — see `AppIconVariant.assetName`.
@DependencyClient
struct AppIconClient: Sendable {
  var isSupported: @Sendable () async -> Bool = { false }
  var current: @Sendable () async -> AppIconVariant = { .wovenIris }
  var select: @Sendable (_ variant: AppIconVariant) async throws -> Void
}

extension AppIconClient: TestDependencyKey {
  static var previewValue: Self {
    let selected = LockIsolated(AppIconVariant.wovenIris)
    return Self(
      isSupported: { true },
      current: { selected.value },
      select: { selected.setValue($0) }
    )
  }

  /// Reading the icon is spelled out rather than left unimplemented, so tests that only care about
  /// the rest of Settings do not each have to override it. Changing the icon stays unimplemented:
  /// a test that switches icons should say so.
  static let testValue = Self(
    isSupported: { false },
    current: { .wovenIris },
    select: { _ in reportIssue("Unimplemented: AppIconClient.select") }
  )
}

extension AppIconClient: DependencyKey {
  static let liveValue = Self(
    isSupported: { await MainActor.run { UIApplication.shared.supportsAlternateIcons } },
    current: {
      await MainActor.run { AppIconVariant(alternateIconName: UIApplication.shared.alternateIconName) }
    },
    select: { variant in try await Self.apply(variant) }
  )

  /// Setting the icon it is already showing still pops the system's "you have changed the icon"
  /// alert, so skip the call when nothing would change.
  @MainActor
  private static func apply(_ variant: AppIconVariant) async throws {
    guard UIApplication.shared.alternateIconName != variant.alternateIconName else { return }
    try await UIApplication.shared.setAlternateIconName(variant.alternateIconName)
  }
}

extension DependencyValues {
  var appIconClient: AppIconClient {
    get { self[AppIconClient.self] }
    set { self[AppIconClient.self] = newValue }
  }
}
