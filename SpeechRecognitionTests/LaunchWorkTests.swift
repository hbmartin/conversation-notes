import ComposableArchitecture
import Foundation
import Testing

@testable import SpeechRecognition

/// Launch-cost regression tests that deliberately time nothing.
///
/// `docs/launch-performance.md` records why. Launch is ~1.8 CPU-seconds of framework startup and
/// app-owned code is ~5% of it, so the signal a stopwatch would have to find is small; meanwhile
/// run-to-run variance on a shared machine is large enough to invent regressions that are not
/// there — during that investigation a 340ms "cost of 200 sessions" turned out to be noise, and
/// 1000 sessions then measured faster than 200. These tests pin what can be *counted* instead:
/// how many actions launch takes, what `State.init` touches before the first frame, and what each
/// persisted record costs to decode. Timing lives in `Scripts/measure-launch.sh`, which reports
/// rather than gates.
@MainActor
struct LaunchWorkTests {
  /// The console at launch reads
  /// `onLaunch → launchRecoveryCompleted → connectivityChanged(true) → drainQueue`, and all four
  /// run before or around the first frame. Pinning the exact sequence puts new launch-time work
  /// in front of a reviewer: a fifth entry is either deliberate or a round trip that should have
  /// been done inline, which is exactly what `launchRecoveryCompleted` replaced.
  @Test
  func launchSettlesInAFixedSequenceOfActions() async {
    @Shared(.sessions) var sessions: IdentifiedArrayOf<Session> = [
      Session(id: UUID(0), startDate: Date(timeIntervalSince1970: 0), state: .saved)
    ]
    let recorded = LockIsolated<[String]>([])
    let metricsSubscriptions = LockIsolated(0)
    // `NWPathMonitor` does not report for tens of milliseconds, so recovery always finishes
    // first. Driving the stream by hand keeps that real ordering deterministic here instead of
    // racing the effects `onLaunch` merges.
    let (connectivity, connectivityContinuation) = AsyncStream.makeStream(of: Bool.self)
    let store = TestStore(initialState: AppFeature.State()) {
      CombineReducers {
        Reduce<AppFeature.State, AppFeature.Action> { _, action in
          recorded.withValue { $0.append("\(action)") }
          return .none
        }
        AppFeature()
      }
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.audioStorage.purgeAllRecordings = {}
      $0.transcriptVault.pendingIDs = { [] }
      $0.interviewArtifacts.storedIDs = { [] }
      $0.connectivity.observe = { connectivity }
      $0.launchMetrics.start = { metricsSubscriptions.withValue { $0 += 1 } }
    }

    let task = await store.send(.onLaunch)
    await store.receive(\.launchRecoveryCompleted)
    connectivityContinuation.yield(true)
    await store.receive(\.connectivityChanged) { $0.isConnected = true }
    await store.receive(\.drainQueue)
    await task.cancel()

    #expect(
      recorded.value == [
        "onLaunch",
        "launchRecoveryCompleted",
        "connectivityChanged(true)",
        "drainQueue",
      ]
    )
    // Subscribing to MetricKit dispatches no action, which is why it is asserted here rather than
    // showing up in the sequence above — and it happens once, not once per launch effect.
    #expect(metricsSubscriptions.value == 1)
  }

  /// `State.init` runs on the main thread before the first frame, so whatever it touches is
  /// launch cost paid before anything is on screen. Today that is one build-time flag and the
  /// persisted session list. Every other client's `testValue` is unimplemented, so a new call
  /// added to `init` fails this test on its own — the list of clients does not have to be
  /// maintained here for the guard to hold.
  @Test
  func stateInitReadsTheFeatureFlagAndNothingElse() {
    let flagReads = LockIsolated(0)
    let state = withDependencies {
      $0.featureFlags.isConversationCaptureEnabled = {
        flagReads.withValue { $0 += 1 }
        return true
      }
    } operation: {
      AppFeature.State()
    }

    #expect(flagReads.value == 1)
    #expect(state.isConversationCaptureEnabled)
  }

  /// `sessions.json` is decoded synchronously on the main thread in `State.init`, before the
  /// first frame, and nothing caps how many records that is — followup 5 in
  /// docs/launch-performance.md. Every field on `Session` is therefore multiplied by the session
  /// count at launch. Pinning the field set makes adding one a deliberate decision, especially a
  /// transcript, an audio path, or anything else unbounded.
  @Test
  func sessionPersistsOnlyTheFieldsLaunchCanAffordToDecode() throws {
    let encoded = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(Self.fullyPopulatedSession)
    )
    let keys = Set(try #require(encoded as? [String: Any]).keys)

    #expect(
      keys == [
        "id",
        "kind",
        "startDate",
        "duration",
        "state",
        "summary",
        "consentUtterance",
        "interviewID",
        "lossReason",
        "summarizationFailure",
        "summaryServiceAudit",
      ]
    )
  }

  /// The prose fields are bounded by the service's token limit and are the point of the record.
  /// Everything else is fixed-size metadata, and it is that overhead — not the prose — that is
  /// paid for every session in the file whether or not the operator ever opens it.
  @Test
  func sessionMetadataOverheadStaysSmall() throws {
    var session = Self.fullyPopulatedSession
    session.summary = nil
    session.consentUtterance = nil
    session.lossReason = nil
    let bytes = try JSONEncoder().encode(session).count

    #expect(bytes < 400, "per-session metadata is now \(bytes) bytes")
  }

  private static let fullyPopulatedSession = Session(
    id: UUID(0),
    kind: .interview,
    startDate: Date(timeIntervalSince1970: 0),
    duration: 42,
    state: .saved,
    summary: "A summary.",
    consentUtterance: "Sure, go ahead.",
    interviewID: UUID(1),
    lossReason: "A reason.",
    summarizationFailure: SummarizationFailure(
      kind: .rateLimited,
      attemptCount: 1,
      nextRetryAt: Date(timeIntervalSince1970: 30),
      requiredAction: .automaticRetry
    ),
    summaryServiceAudit: ServiceAuditMetadata(
      requestID: "req-1",
      modelVersion: "model-1",
      promptVersion: "summary-v1"
    )
  )
}
