import Foundation
import Testing
import UIKit

@testable import SpeechRecognition

/// The launch screen exists to make the gap before the first rendered frame read as "the app is
/// already up" rather than a white flash. It only does that for as long as its colour matches what
/// the first frame actually paints, and nothing at runtime can check that for us — the launch
/// screen is drawn by the system before any of our code runs.
@MainActor
struct LaunchScreenTests {
  @Test
  func launchBackgroundAssetMatchesTheAuroraAverage() throws {
    for (style, expected) in [
      (UIUserInterfaceStyle.light, AppTheme.launchBackgroundLight),
      (UIUserInterfaceStyle.dark, AppTheme.launchBackgroundDark),
    ] {
      let dynamic = try #require(
        UIColor(named: AppTheme.launchBackgroundAssetName, in: .main, compatibleWith: nil),
        "\(AppTheme.launchBackgroundAssetName).colorset is missing from the asset catalog"
      )
      let color = dynamic.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
      var red: CGFloat = 0
      var green: CGFloat = 0
      var blue: CGFloat = 0
      var alpha: CGFloat = 0
      let resolved = color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
      #expect(resolved)
      // The compiled catalog quantises to 8 bits, so a step of 1/255 is expected noise; any real
      // drift between the asset and the mesh is an order of magnitude larger.
      #expect(abs(Double(red) - expected.red) < 0.005)
      #expect(abs(Double(green) - expected.green) < 0.005)
      #expect(abs(Double(blue) - expected.blue) < 0.005)
      #expect(alpha == 1)
    }
  }

  /// Without this key the launch screen falls back to plain white, which is the flash the colour
  /// asset was added to remove.
  @Test
  func infoPlistPointsAtTheLaunchBackgroundAsset() throws {
    let launchScreen = try #require(
      Bundle.main.infoDictionary?["UILaunchScreen"] as? [String: Any]
    )
    #expect(launchScreen["UIColorName"] as? String == AppTheme.launchBackgroundAssetName)
  }

  @Test
  func launchBackgroundIsDerivedFromTheRenderedMesh() {
    // Guards the derivation itself: a mesh edit must move the launch colour, or the asset test
    // above would happily keep passing against a stale constant.
    #expect(AppTheme.auroraLightMesh.count == 9)
    #expect(AppTheme.auroraDarkMesh.count == 9)
    #expect(AppTheme.averaged(AppTheme.auroraLightMesh).red == 7.90 / 9)
    #expect(AppTheme.launchBackgroundLight.red > AppTheme.averaged(AppTheme.auroraLightMesh).red)
    #expect(AppTheme.launchBackgroundDark.blue < AppTheme.averaged(AppTheme.auroraDarkMesh).blue)
  }
}
