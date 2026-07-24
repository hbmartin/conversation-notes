import ComposableArchitecture
import Foundation

/// Persistence for retained interview artifacts: `Documents/interviews/<uuid>/record.json`
/// plus the per-answer audio segments the speech client writes into the same directory.
@DependencyClient
struct InterviewArtifactsClient: Sendable {
  /// Returns (and creates) the directory for one interview's artifacts.
  var interviewDirectory: @Sendable (_ interviewID: UUID) throws -> URL
  var save: @Sendable (_ record: InterviewRecord) throws -> Void
  var load: @Sendable (_ interviewID: UUID) throws -> InterviewRecord
  var destroy: @Sendable (_ interviewID: UUID) throws -> Void
  /// Every interview ID with artifacts on disk, for the launch-time orphan sweep.
  var storedIDs: @Sendable () -> [UUID] = { [] }
}

extension InterviewArtifactsClient: TestDependencyKey {
  static var previewValue: Self {
    live(baseDirectory: FileManager.default.temporaryDirectory)
  }

  static let testValue = Self()
}

extension InterviewArtifactsClient: DependencyKey {
  static var liveValue: Self {
    live(baseDirectory: .documentsDirectory)
  }

  static func live(baseDirectory: URL) -> Self {
    let interviewsRoot = baseDirectory.appending(component: "interviews")
    @Sendable func url(for id: UUID) -> URL {
      interviewsRoot.appending(component: id.uuidString)
    }
    @Sendable func directory(for id: UUID) throws -> URL {
      let directory = url(for: id)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    }
    return Self(
      interviewDirectory: { id in try directory(for: id) },
      save: { record in
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(
          to: directory(for: record.id).appending(component: "record.json"),
          options: .atomic
        )
      },
      load: { id in
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(
          contentsOf: directory(for: id).appending(component: "record.json")
        )
        return try decoder.decode(InterviewRecord.self, from: data)
      },
      destroy: { id in
        let url = url(for: id)
        if FileManager.default.fileExists(atPath: url.path()) {
          try FileManager.default.removeItem(at: url)
        }
      },
      storedIDs: {
        let contents =
          (try? FileManager.default.contentsOfDirectory(
            at: interviewsRoot,
            includingPropertiesForKeys: nil
          )) ?? []
        return contents.compactMap { UUID(uuidString: $0.lastPathComponent) }
      }
    )
  }
}

extension DependencyValues {
  var interviewArtifacts: InterviewArtifactsClient {
    get { self[InterviewArtifactsClient.self] }
    set { self[InterviewArtifactsClient.self] = newValue }
  }
}
