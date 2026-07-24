import Foundation
import Testing

@testable import SpeechRecognition

struct PersistenceCompatibilityTests {
  private struct LegacySession: Codable {
    let id: UUID
    var startDate: Date
    var duration: TimeInterval
    var state: SessionState
    var summary: String?
    var consentUtterance: String?
    var interviewID: UUID?
    var lossReason: String?
  }

  private struct LegacyInterviewRecord: Codable {
    let id: UUID
    var sessionID: UUID
    var startedAt: Date
    var endedAt: Date?
    var summaryUsed: String
    var turns: [InterviewTurn]
    var extraction: InterviewExtraction?
    var model: String
    var schemaVersion: Int
    var operatorEdits: [FieldEdit]?
  }

  @Test
  func legacySessionDecodesWithoutFailureOrAuditFields() throws {
    let legacy = LegacySession(
      id: UUID(0),
      startDate: Date(timeIntervalSince1970: 1),
      duration: 42,
      state: .awaitingSummarization,
      summary: nil,
      consentUtterance: nil,
      interviewID: nil,
      lossReason: nil
    )

    let session = try JSONDecoder().decode(
      Session.self,
      from: JSONEncoder().encode(legacy)
    )
    #expect(session.id == legacy.id)
    #expect(session.state == .awaitingSummarization)
    #expect(session.summarizationFailure == nil)
    #expect(session.summaryServiceAudit == nil)
  }

  @Test
  func legacyInterviewRecordDecodesWithoutAuditTrail() throws {
    let legacy = LegacyInterviewRecord(
      id: UUID(1),
      sessionID: UUID(0),
      startedAt: Date(timeIntervalSince1970: 1),
      endedAt: Date(timeIntervalSince1970: 2),
      summaryUsed: "Summary",
      turns: [],
      extraction: nil,
      model: "legacy-model",
      schemaVersion: 1,
      operatorEdits: nil
    )

    let record = try JSONDecoder().decode(
      InterviewRecord.self,
      from: JSONEncoder().encode(legacy)
    )
    #expect(record.id == legacy.id)
    #expect(record.model == "legacy-model")
    #expect(record.serviceAuditTrail == nil)
  }

  @Test
  func durableSummarizationFailureRoundTrips() throws {
    let retryDate = Date(timeIntervalSince1970: 1_000)
    let audit = ServiceAuditMetadata(
      requestID: "request-1",
      modelVersion: "model-2",
      promptVersion: "summary-v3"
    )
    let session = Session(
      id: UUID(2),
      startDate: Date(timeIntervalSince1970: 0),
      state: .awaitingSummarization,
      summarizationFailure: SummarizationFailure(
        kind: .rateLimited,
        attemptCount: 3,
        nextRetryAt: retryDate,
        requiredAction: .automaticRetry
      ),
      summaryServiceAudit: audit
    )

    let decoded = try JSONDecoder().decode(
      Session.self,
      from: JSONEncoder().encode(session)
    )
    #expect(decoded == session)
    #expect(decoded.summarizationFailure?.nextRetryAt == retryDate)
    #expect(decoded.summaryServiceAudit == audit)
  }
}
