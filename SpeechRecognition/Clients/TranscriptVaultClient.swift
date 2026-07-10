import ComposableArchitecture
import Foundation

/// Encrypted holding area for transcripts awaiting cloud summarization.
///
/// This is the one artifact with an unbounded offline lifetime, so it gets
/// `NSFileProtectionComplete` and backup exclusion — which is exactly why this is a custom
/// client rather than `@Shared(.fileStorage)` (that applies neither). Files here are unreadable
/// while the device is locked; callers must treat read failures as transient.
@DependencyClient
struct TranscriptVaultClient: Sendable {
  var store: @Sendable (_ id: Session.ID, _ transcript: String) async throws -> Void
  var load: @Sendable (_ id: Session.ID) async throws -> String
  var destroy: @Sendable (_ id: Session.ID) async throws -> Void
  var pendingIDs: @Sendable () async -> [Session.ID] = { [] }
}

extension TranscriptVaultClient: TestDependencyKey {
  static var previewValue: Self {
    live(baseDirectory: FileManager.default.temporaryDirectory, fileProtection: false)
  }

  static let testValue = Self()
}

extension TranscriptVaultClient: DependencyKey {
  static var liveValue: Self {
    live(baseDirectory: .applicationSupportDirectory, fileProtection: true)
  }

  static func live(baseDirectory: URL, fileProtection: Bool) -> Self {
    @Sendable func queueDirectory() throws -> URL {
      var directory = baseDirectory.appending(components: "MSLCapture", "TranscriptQueue")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? directory.setResourceValues(values)
      return directory
    }
    @Sendable func url(for id: Session.ID) throws -> URL {
      try queueDirectory().appending(component: "\(id.uuidString).txt")
    }
    return Self(
      store: { id, transcript in
        var options: Data.WritingOptions = [.atomic]
        if fileProtection {
          options.insert(.completeFileProtection)
        }
        try Data(transcript.utf8).write(to: url(for: id), options: options)
      },
      load: { id in
        try String(decoding: Data(contentsOf: url(for: id)), as: UTF8.self)
      },
      destroy: { id in
        let url = try url(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.removeItem(at: url)
        }
      },
      pendingIDs: {
        guard let directory = try? queueDirectory(),
          let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
          )
        else { return [] }
        return contents.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
      }
    )
  }
}

extension DependencyValues {
  var transcriptVault: TranscriptVaultClient {
    get { self[TranscriptVaultClient.self] }
    set { self[TranscriptVaultClient.self] = newValue }
  }
}
