// Renders the selectable app icons into the asset catalog from the shared CoreGraphics artwork,
// so the PNGs on disk can never drift from the previews Settings draws.
//
// Usage (from the repository root):
//
//     Scripts/render-app-icons.sh
//
// which compiles this file together with SpeechRecognition/AppIconArtwork.swift and runs it.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum RenderAppIcons {
  /// Every size iOS asks an app icon for. Alternates need these spelled out: Xcode downscales a
  /// lone 1024 source for the *primary* icon only, so an alternate declared that way compiles into
  /// the catalog with no icon the home screen can actually install, and switching to it fails.
  /// Each entry is drawn at its own resolution rather than resampled, and entries that come out
  /// the same number of pixels share one file.
  static let entries: [(idiom: String, size: String, scale: Int, points: Double)] = [
    ("iphone", "20x20", 2, 20), ("iphone", "20x20", 3, 20),
    ("iphone", "29x29", 2, 29), ("iphone", "29x29", 3, 29),
    ("iphone", "40x40", 2, 40), ("iphone", "40x40", 3, 40),
    ("iphone", "60x60", 2, 60), ("iphone", "60x60", 3, 60),
    ("ipad", "20x20", 1, 20), ("ipad", "20x20", 2, 20),
    ("ipad", "29x29", 1, 29), ("ipad", "29x29", 2, 29),
    ("ipad", "40x40", 1, 40), ("ipad", "40x40", 2, 40),
    ("ipad", "76x76", 2, 76),
    ("ipad", "83.5x83.5", 2, 83.5),
    ("ios-marketing", "1024x1024", 1, 1024),
  ]

  static func main() throws {
    let catalog = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("SpeechRecognition/Assets.xcassets")
    guard FileManager.default.fileExists(atPath: catalog.path) else {
      throw Failure("Run from the repository root: \(catalog.path) not found.")
    }

    for variant in AppIconVariant.allCases {
      let directory = catalog.appendingPathComponent("\(variant.assetName).appiconset")
      try self.replaceDirectory(at: directory)

      var images: [String] = []
      var rendered: Set<Int> = []
      for entry in self.entries {
        let pixels = Int((entry.points * Double(entry.scale)).rounded())
        let fileName = "\(variant.assetName)-\(pixels).png"
        if rendered.insert(pixels).inserted {
          try self.writePNG(
            variant,
            pixels: pixels,
            to: directory.appendingPathComponent(fileName)
          )
        }
        images.append(
          """
              {
                "filename" : "\(fileName)",
                "idiom" : "\(entry.idiom)",
                "scale" : "\(entry.scale)x",
                "size" : "\(entry.size)"
              }
          """
        )
      }

      try self.contentsJSON(images: images)
        .write(
          to: directory.appendingPathComponent("Contents.json"),
          atomically: true,
          encoding: .utf8
        )
      print("rendered \(variant.assetName).appiconset (\(rendered.count) sizes)")
    }
  }

  /// Start each set empty so renamed or retired sizes cannot linger in the catalog.
  private static func replaceDirectory(at url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  /// Opaque sRGB, no alpha channel: App Store validation rejects app icons with transparency.
  private static func writePNG(_ variant: AppIconVariant, pixels: Int, to url: URL) throws {
    guard
      let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    else { throw Failure("Could not create a \(pixels)×\(pixels) bitmap context.") }

    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    // Match the y-down coordinate system the artwork (and SwiftUI's Canvas) assumes.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: 1, y: -1)
    AppIconArtwork.draw(variant, in: context, size: CGFloat(pixels))

    guard let image = context.makeImage() else { throw Failure("Could not snapshot the bitmap.") }
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else { throw Failure("Could not open \(url.path) for writing.") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw Failure("Could not encode \(url.path).")
    }
  }

  private static func contentsJSON(images: [String]) -> String {
    """
    {
      "images" : [
    \(images.joined(separator: ",\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
  }
}

struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
