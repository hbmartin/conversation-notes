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
    @Sendable func directory(for id: UUID) throws -> URL {
      let directory = baseDirectory.appending(components: "interviews", id.uuidString)
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
