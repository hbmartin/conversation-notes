import ComposableArchitecture
import Foundation

/// Owns the transient staging area for in-progress conversation recordings.
///
/// Audio here is unencrypted (accepted risk R5) but excluded from backups, and is destroyed
/// the moment transcription succeeds. `purgeAllRecordings` is the crash-recovery hammer: at app
/// launch no recording can legitimately be in progress, so the entire directory is orphaned by
/// definition.
@DependencyClient
struct AudioStorageClient: Sendable {
  var recordingURL: @Sendable (_ id: Session.ID) throws -> URL
  var destroyRecording: @Sendable (_ id: Session.ID) async throws -> Void
  var purgeAllRecordings: @Sendable () async throws -> Void
}

extension AudioStorageClient: TestDependencyKey {
  static var previewValue: Self {
    live(baseDirectory: FileManager.default.temporaryDirectory)
  }

  static let testValue = Self()
}

extension AudioStorageClient: DependencyKey {
  static var liveValue: Self {
    live(baseDirectory: .applicationSupportDirectory)
  }

  static func live(baseDirectory: URL) -> Self {
    @Sendable func stagingDirectory() throws -> URL {
      var directory = baseDirectory.appending(components: "MSLCapture", "AudioStaging")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? directory.setResourceValues(values)
      return directory
    }
    @Sendable func url(for id: Session.ID) throws -> URL {
      try stagingDirectory().appending(component: "\(id.uuidString).m4a")
    }
    return Self(
      recordingURL: { id in try url(for: id) },
      destroyRecording: { id in
        let url = try url(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.removeItem(at: url)
        }
      },
      purgeAllRecordings: {
        let directory = try stagingDirectory()
        let contents = try FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil
        )
        for url in contents {
          try? FileManager.default.removeItem(at: url)
        }
      }
    )
  }
}

extension DependencyValues {
  var audioStorage: AudioStorageClient {
    get { self[AudioStorageClient.self] }
    set { self[AudioStorageClient.self] = newValue }
  }
}
