import SwiftUI

enum AppTheme {
  static let conversation = Color(red: 0.12, green: 0.52, blue: 0.92)
  static let interview = Color(red: 0.52, green: 0.31, blue: 0.94)
  static let recording = Color(red: 0.95, green: 0.19, blue: 0.28)
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
      colors: self.colorScheme == .dark ? self.darkColors : self.lightColors,
      background: self.colorScheme == .dark
        ? Color(red: 0.025, green: 0.035, blue: 0.09)
        : Color(red: 0.93, green: 0.97, blue: 1)
    )
    .overlay {
      LinearGradient(
        colors: [
          .clear,
          self.colorScheme == .dark ? .black.opacity(0.24) : .white.opacity(0.18),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
    .ignoresSafeArea()
    .accessibilityHidden(true)
  }

  private var lightColors: [Color] {
    [
      Color(red: 0.89, green: 0.96, blue: 1),
      Color(red: 0.80, green: 0.89, blue: 1),
      Color(red: 0.91, green: 0.84, blue: 1),
      Color(red: 0.80, green: 0.96, blue: 0.98),
      Color(red: 0.92, green: 0.95, blue: 1),
      Color(red: 0.84, green: 0.81, blue: 1),
      Color(red: 0.93, green: 0.99, blue: 1),
      Color(red: 0.85, green: 0.91, blue: 1),
      Color(red: 0.96, green: 0.90, blue: 1),
    ]
  }

  private var darkColors: [Color] {
    [
      Color(red: 0.025, green: 0.06, blue: 0.14),
      Color(red: 0.05, green: 0.16, blue: 0.30),
      Color(red: 0.16, green: 0.07, blue: 0.30),
      Color(red: 0.02, green: 0.20, blue: 0.25),
      Color(red: 0.07, green: 0.10, blue: 0.23),
      Color(red: 0.25, green: 0.08, blue: 0.35),
      Color(red: 0.02, green: 0.08, blue: 0.16),
      Color(red: 0.06, green: 0.13, blue: 0.27),
      Color(red: 0.15, green: 0.06, blue: 0.24),
    ]
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
