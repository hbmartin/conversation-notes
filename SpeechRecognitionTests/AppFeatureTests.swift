import ComposableArchitecture
import Foundation
import Testing

@testable import SpeechRecognition

@MainActor
struct AppFeatureTests {
  @Test
  func offlineDoesNotSummarize() async {
    @Shared(.sessions) var sessions = [
      Session(id: UUID(0), startDate: Date(timeIntervalSince1970: 0), state: .awaitingSummarization)
    ]
    var state = AppFeature.State()
    state.isConnected = false
    let summarizeCalls = LockIsolated(0)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.anthropicClient.summarize = { _ in
        summarizeCalls.withValue { $0 += 1 }
        return SummarizationResult(summary: "Unexpected", consentUtterance: nil)
      }
    }
    await store.send(.drainQueue)
    #expect(summarizeCalls.value == 0)
  }

  @Test
  func connectivityDrainsQueueAndDestroysTranscriptAfterSummary() async {
    let id = UUID(0)
    @Shared(.sessions) var sessions = [
      Session(id: id, startDate: Date(timeIntervalSince1970: 0), state: .awaitingSummarization)
    ]
    let events = LockIsolated<[String]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.transcriptVault.load = { id in
        events.withValue { $0.append("vault.load(\(id))") }
        return "the transcript"
      }
      $0.transcriptVault.destroy = { id in
        events.withValue { $0.append("vault.destroy(\(id))") }
      }
      $0.anthropicClient.summarize = { transcript in
        events.withValue { $0.append("summarize") }
        #expect(transcript == "the transcript")
        return SummarizationResult(summary: "A summary.", consentUtterance: "Sure, go ahead.")
      }
    }

    store.exhaustivity = .off

    await store.send(.connectivityChanged(true))
    await store.receive(\.transcriptDestroyed)
    await store.receive(\.drainQueue)

    #expect(store.state.sessions[id: id]?.state == .summaryReady)
    #expect(store.state.sessions[id: id]?.summary == "A summary.")
    #expect(store.state.sessions[id: id]?.consentUtterance == "Sure, go ahead.")
    // The transcript is destroyed only after the summary landed in shared state.
    #expect(events.value == ["vault.load(\(id))", "summarize", "vault.destroy(\(id))"])
  }

  @Test
  func summarizationFailureBacksOffAndRetries() async {
    let id = UUID(0)
    @Shared(.sessions) var sessions = [
      Session(id: id, startDate: Date(timeIntervalSince1970: 0), state: .awaitingSummarization)
    ]
    let clock = TestClock()
    let results = LockIsolated<[Result<SummarizationResult, AnthropicClientError>]>([
      .failure(.serverError(status: 529)),
      .success(SummarizationResult(summary: "Second try.", consentUtterance: nil)),
    ])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.transcriptVault.load = { _ in "the transcript" }
      $0.transcriptVault.destroy = { _ in }
      $0.anthropicClient.summarize = { _ in
        try results.withValue { $0.removeFirst() }.get()
      }
    }

    store.exhaustivity = .off

    await store.send(.connectivityChanged(true))
    await store.receive(\.summarizationResponse)

    // First attempt failed: session untouched, transcript intact, backoff scheduled.
    #expect(store.state.summarizeAttempt == 1)
    #expect(store.state.sessions[id: id]?.state == .awaitingSummarization)

    // First backoff is 30 seconds; advancing the clock retries and succeeds.
    await clock.advance(by: .seconds(30))
    await store.receive(\.transcriptDestroyed)
    await store.receive(\.drainQueue)

    #expect(store.state.summarizeAttempt == 0)
    #expect(store.state.sessions[id: id]?.state == .summaryReady)
    #expect(store.state.sessions[id: id]?.summary == "Second try.")
  }

  @Test
  func multipleQueuedSessionsDrainSequentially() async {
    @Shared(.sessions) var sessions = [
      Session(
        id: UUID(0), startDate: Date(timeIntervalSince1970: 0), state: .awaitingSummarization),
      Session(
        id: UUID(1), startDate: Date(timeIntervalSince1970: 60), state: .awaitingSummarization),
    ]
    let summarized = LockIsolated<[Session.ID]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.transcriptVault.load = { id in "transcript \(id)" }
      $0.transcriptVault.destroy = { _ in }
      $0.anthropicClient.summarize = { transcript in
        let id = UUID(uuidString: String(transcript.dropFirst("transcript ".count)))!
        summarized.withValue { $0.append(id) }
        return SummarizationResult(summary: "Summary for \(id)", consentUtterance: nil)
      }
    }
    store.exhaustivity = .off

    await store.send(.connectivityChanged(true))
    await store.receive(\.drainQueue)
    await store.receive(\.summarizationResponse)
    await store.receive(\.transcriptDestroyed)
    await store.receive(\.drainQueue)
    await store.receive(\.summarizationResponse)
    await store.receive(\.transcriptDestroyed)
    await store.receive(\.drainQueue)

    #expect(summarized.value == [UUID(0), UUID(1)])
    #expect(store.state.sessions.allSatisfy { $0.state == .summaryReady })
  }

  @Test
  func launchRecoveryPurgesAudioMarksLostAndSweepsOrphans() async {
    let recordingID = UUID(0)
    let transcribingID = UUID(1)
    let queuedID = UUID(2)
    let orphanVaultID = UUID(9)
    @Shared(.sessions) var sessions = [
      Session(id: recordingID, startDate: Date(timeIntervalSince1970: 0), state: .recording),
      Session(id: transcribingID, startDate: Date(timeIntervalSince1970: 60), state: .transcribing),
      Session(
        id: queuedID, startDate: Date(timeIntervalSince1970: 120), state: .awaitingSummarization),
    ]
    let events = LockIsolated<[String]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.audioStorage.purgeAllRecordings = {
        events.withValue { $0.append("audio.purgeAll") }
      }
      $0.transcriptVault.pendingIDs = { [queuedID, orphanVaultID] }
      $0.transcriptVault.destroy = { id in
        events.withValue { $0.append("vault.destroy(\(id))") }
      }
      // Never yields: connectivity is exercised separately so receive order is deterministic.
      $0.connectivity.observe = { AsyncStream { _ in } }
    }

    let lossReason =
      "The app closed before transcription completed, so this recording could not be recovered."
    let task = await store.send(.onLaunch) {
      $0.$sessions.withLock {
        $0[id: recordingID]?.state = .lost
        $0[id: recordingID]?.lossReason = lossReason
        $0[id: transcribingID]?.state = .lost
        $0[id: transcribingID]?.lossReason = lossReason
      }
    }
    await store.receive(\.drainQueue)

    #expect(events.value.contains("audio.purgeAll"))
    // In-flight sessions' vault entries are defensively destroyed; the orphan is swept; the
    // legitimately queued transcript is untouched.
    #expect(events.value.contains("vault.destroy(\(recordingID))"))
    #expect(events.value.contains("vault.destroy(\(transcribingID))"))
    #expect(events.value.contains("vault.destroy(\(orphanVaultID))"))
    #expect(!events.value.contains("vault.destroy(\(queuedID))"))
    #expect(store.state.sessions[id: queuedID]?.state == .awaitingSummarization)

    await task.cancel()
  }

  @Test
  func discardedSessionIsRemoved() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.audioRecorder.requestRecordPermission = { true }
    }
    store.exhaustivity = .off

    await store.send(.newSessionButtonTapped)
    #expect(store.state.sessions.count == 1)
    #expect(store.state.activeSession != nil)

    await store.send(.activeSession(.presented(.delegate(.discarded(UUID(0)))))) {
      $0.activeSession = nil
    }
    #expect(store.state.sessions.isEmpty)
  }

  @Test
  func interviewFinishedSavesRecordReferenceAndPops() async {
    let sessionID = UUID(0)
    @Shared(.sessions) var sessions = [
      Session(
        id: sessionID,
        startDate: Date(timeIntervalSince1970: 0),
        state: .summaryReady,
        summary: "A summary."
      )
    ]
    let interviewID = UUID(42)
    var state = AppFeature.State()
    state.isConnected = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .constant(interviewID)
    }
    store.exhaustivity = .off

    await store.send(.sessionTapped(sessionID))
    await store.send(.path(.element(id: 0, action: .detail(.delegate(.startInterview(sessionID))))))
    #expect(store.state.path.count == 2)

    let record = InterviewRecord(
      id: interviewID,
      sessionID: sessionID,
      startedAt: Date(timeIntervalSince1970: 0),
      endedAt: Date(timeIntervalSince1970: 60),
      summaryUsed: "A summary.",
      turns: [],
      extraction: nil,
      model: AnthropicModel.opus
    )
    await store.send(
      .path(.element(id: 1, action: .interview(.delegate(.interviewFinished(record)))))
    )
    #expect(store.state.sessions[id: sessionID]?.interviewID == interviewID)
    #expect(store.state.sessions[id: sessionID]?.state == .saved)
    #expect(store.state.path.count == 1)
  }

  @Test
  func startInterviewWhileOfflineShowsAlert() async {
    let sessionID = UUID(0)
    @Shared(.sessions) var sessions = [
      Session(
        id: sessionID,
        startDate: Date(timeIntervalSince1970: 0),
        state: .summaryReady,
        summary: "A summary."
      )
    ]
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.sessionTapped(sessionID))
    await store.send(.path(.element(id: 0, action: .detail(.delegate(.startInterview(sessionID))))))
    #expect(store.state.alert != nil)
    #expect(store.state.path.count == 1)
  }
}
