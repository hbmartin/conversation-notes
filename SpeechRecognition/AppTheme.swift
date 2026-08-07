import SwiftUI

enum AppTheme {
  static let conversation = Color(red: 0.12, green: 0.52, blue: 0.92)
  static let interview = Color(red: 0.52, green: 0.31, blue: 0.94)
  static let recording = Color(red: 0.95, green: 0.19, blue: 0.28)

  /// One sRGB stop of the aurora mesh.
  ///
  /// Held as raw components rather than `Color` because the launch screen is an asset-catalog
  /// colour that no Swift code gets to run before: the only way to keep it matching the first
  /// rendered frame is to derive both from the same numbers and assert the match in tests. A
  /// launch background that has drifted from the mesh reads as a flash, which is precisely what
  /// giving the launch screen a colour is meant to remove.
  struct Stop: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let white = Self(red: 1, green: 1, blue: 1)
    static let black = Self(red: 0, green: 0, blue: 0)

    var color: Color { Color(red: self.red, green: self.green, blue: self.blue) }

    func blended(with other: Self, amount: Double) -> Self {
      Self(
        red: self.red + (other.red - self.red) * amount,
        green: self.green + (other.green - self.green) * amount,
        blue: self.blue + (other.blue - self.blue) * amount
      )
    }
  }

  static let auroraLightMesh: [Stop] = [
    Stop(red: 0.89, green: 0.96, blue: 1),
    Stop(red: 0.80, green: 0.89, blue: 1),
    Stop(red: 0.91, green: 0.84, blue: 1),
    Stop(red: 0.80, green: 0.96, blue: 0.98),
    Stop(red: 0.92, green: 0.95, blue: 1),
    Stop(red: 0.84, green: 0.81, blue: 1),
    Stop(red: 0.93, green: 0.99, blue: 1),
    Stop(red: 0.85, green: 0.91, blue: 1),
    Stop(red: 0.96, green: 0.90, blue: 1),
  ]

  static let auroraDarkMesh: [Stop] = [
    Stop(red: 0.025, green: 0.06, blue: 0.14),
    Stop(red: 0.05, green: 0.16, blue: 0.30),
    Stop(red: 0.16, green: 0.07, blue: 0.30),
    Stop(red: 0.02, green: 0.20, blue: 0.25),
    Stop(red: 0.07, green: 0.10, blue: 0.23),
    Stop(red: 0.25, green: 0.08, blue: 0.35),
    Stop(red: 0.02, green: 0.08, blue: 0.16),
    Stop(red: 0.06, green: 0.13, blue: 0.27),
    Stop(red: 0.15, green: 0.06, blue: 0.24),
  ]

  static let auroraLightBase = Stop(red: 0.93, green: 0.97, blue: 1)
  static let auroraDarkBase = Stop(red: 0.025, green: 0.035, blue: 0.09)

  /// Opacity of `AuroraBackground`'s diagonal overlay at its far corner. It ramps from `.clear`,
  /// so the mesh is shifted by half of this on average.
  static let auroraOverlayOpacity = (light: 0.18, dark: 0.24)

  /// The single colour that reads closest to the whole aurora screen: the flat mesh average,
  /// shifted by the overlay. `LaunchBackground.colorset` holds exactly these two values, and
  /// `LaunchScreenTests` fails if the two ever diverge.
  static let launchBackgroundLight = averaged(auroraLightMesh)
    .blended(with: Stop.white, amount: auroraOverlayOpacity.light / 2)
  static let launchBackgroundDark = averaged(auroraDarkMesh)
    .blended(with: Stop.black, amount: auroraOverlayOpacity.dark / 2)

  /// Asset-catalog colour named by `UILaunchScreen` in `Info.plist`.
  static let launchBackgroundAssetName = "LaunchBackground"

  static func averaged(_ stops: [Stop]) -> Stop {
    guard !stops.isEmpty else { return .black }
    let count = Double(stops.count)
    return Stop(
      red: stops.reduce(0) { $0 + $1.red } / count,
      green: stops.reduce(0) { $0 + $1.green } / count,
      blue: stops.reduce(0) { $0 + $1.blue } / count
    )
  }
}

struct AuroraBackground: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    MeshGradient(
      width: 3,
      height: 3,
      points: [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.52, 0.46], [1, 0.54],
        [0, 1], [0.48, 1], [1, 1],
      ],
      colors: (self.colorScheme == .dark ? AppTheme.auroraDarkMesh : AppTheme.auroraLightMesh)
        .map(\.color),
      background: self.colorScheme == .dark
        ? AppTheme.auroraDarkBase.color
        : AppTheme.auroraLightBase.color
    )
    .overlay {
      LinearGradient(
        colors: [
          .clear,
          self.colorScheme == .dark
            ? .black.opacity(AppTheme.auroraOverlayOpacity.dark)
            : .white.opacity(AppTheme.auroraOverlayOpacity.light),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
    .ignoresSafeArea()
    .accessibilityHidden(true)
  }
}

struct AuroraScreen<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ZStack {
      AuroraBackground()
      self.content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

extension View {
  func auroraPanel(cornerRadius: CGFloat = 24) -> some View {
    self
      .background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(.white.opacity(0.16), lineWidth: 1)
      }
  }
}
