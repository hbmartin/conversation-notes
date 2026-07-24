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
      $0.conversationService.summarize = { _ in
        summarizeCalls.withValue { $0 += 1 }
        return SummaryResponse(summary: "Unexpected", consentUtterance: nil)
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
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.transcriptVault.load = { id in
        events.withValue { $0.append("vault.load(\(id))") }
        return "the transcript"
      }
      $0.transcriptVault.destroy = { id in
        events.withValue { $0.append("vault.destroy(\(id))") }
      }
      $0.conversationService.summarize = { request in
        events.withValue { $0.append("summarize") }
        #expect(request.transcript == "the transcript")
        return SummaryResponse(summary: "A summary.", consentUtterance: "Sure, go ahead.")
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
    let results = LockIsolated<[Result<SummaryResponse, ConversationServiceError>]>([
      .failure(.serviceUnavailable),
      .success(SummaryResponse(summary: "Second try.", consentUtterance: nil)),
    ])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.transcriptVault.load = { _ in "the transcript" }
      $0.transcriptVault.destroy = { _ in }
      $0.conversationService.summarize = { _ in
        try results.withValue { $0.removeFirst() }.get()
      }
    }

    store.exhaustivity = .off

    await store.send(.connectivityChanged(true))
    await store.receive(\.summarizationResponse)

    // First attempt failed: session untouched, transcript intact, backoff scheduled.
    #expect(store.state.sessions[id: id]?.state == .awaitingSummarization)
    #expect(store.state.sessions[id: id]?.summarizationFailure?.attemptCount == 1)
    #expect(store.state.sessions[id: id]?.summarizationFailure?.kind == .serviceUnavailable)
    #expect(
      store.state.sessions[id: id]?.summarizationFailure?.nextRetryAt
        == Date(timeIntervalSince1970: 30)
    )

    // First backoff is 30 seconds; advancing the clock retries and succeeds.
    await clock.advance(by: .seconds(30))
    await store.receive(\.transcriptDestroyed)
    await store.receive(\.drainQueue)

    #expect(store.state.sessions[id: id]?.state == .summaryReady)
    #expect(store.state.sessions[id: id]?.summary == "Second try.")
    #expect(store.state.sessions[id: id]?.summarizationFailure == nil)
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
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.transcriptVault.load = { id in "transcript \(id)" }
      $0.transcriptVault.destroy = { _ in }
      $0.conversationService.summarize = { request in
        let id = UUID(uuidString: String(request.transcript.dropFirst("transcript ".count)))!
        summarized.withValue { $0.append(id) }
        return SummaryResponse(summary: "Summary for \(id)", consentUtterance: nil)
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
  func nonRetryableFailureBlocksSessionAndDrainsNext() async {
    @Shared(.sessions) var sessions = [
      Session(
        id: UUID(0), startDate: Date(timeIntervalSince1970: 0), state: .awaitingSummarization),
      Session(
        id: UUID(1), startDate: Date(timeIntervalSince1970: 60), state: .awaitingSummarization),
    ]
    let results = LockIsolated<[Result<SummaryResponse, ConversationServiceError>]>([
      .failure(.credentialsRejected),
      .success(SummaryResponse(summary: "Second session.", consentUtterance: nil)),
    ])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.transcriptVault.load = { _ in "the transcript" }
      $0.transcriptVault.destroy = { _ in }
      $0.conversationService.summarize = { _ in
        try results.withValue { $0.removeFirst() }.get()
      }
    }
    store.exhaustivity = .off

    await store.send(.connectivityChanged(true))
    // Session 0 fails non-retryably; the queue skips it and moves on without backoff.
    await store.receive(\.summarizationResponse)
    await store.receive(\.summarizationResponse)
    await store.receive(\.transcriptDestroyed)

    #expect(store.state.sessions[id: UUID(0)]?.state == .awaitingSummarization)
    #expect(store.state.sessions[id: UUID(0)]?.summarizationFailure?.kind == .credentialsRejected)
    #expect(
      store.state.sessions[id: UUID(0)]?.summarizationFailure?.requiredAction == .openSettings)
    #expect(store.state.sessions[id: UUID(1)]?.state == .summaryReady)
    #expect(store.state.sessions[id: UUID(1)]?.summarizationFailure == nil)
  }

  @Test
  func retryClearsBlockedSessionsAndErrors() async {
    let id = UUID(0)
    @Shared(.sessions) var sessions = [
      Session(id: id, startDate: Date(timeIntervalSince1970: 0), state: .awaitingSummarization)
    ]
    let results = LockIsolated<[Result<SummaryResponse, ConversationServiceError>]>([
      .failure(.credentialsMissing),
      .success(SummaryResponse(summary: "After retry.", consentUtterance: nil)),
    ])
    var state = AppFeature.State()
    state.isConnected = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.transcriptVault.load = { _ in "the transcript" }
      $0.transcriptVault.destroy = { _ in }
      $0.conversationService.summarize = { _ in
        try results.withValue { $0.removeFirst() }.get()
      }
    }
    store.exhaustivity = .off

    await store.send(.drainQueue)
    await store.receive(\.summarizationResponse)
    #expect(store.state.sessions[id: id]?.summarizationFailure?.kind == .credentialsMissing)
    #expect(store.state.sessions[id: id]?.summarizationFailure?.requiredAction == .openSettings)

    // "Retry Now" in the session detail clears the block and the surfaced error.
    await store.send(.sessionTapped(id))
    await store.send(.path(.element(id: 0, action: .detail(.delegate(.retrySummarization(id))))))
    await store.receive(\.transcriptDestroyed)

    #expect(store.state.sessions[id: id]?.state == .summaryReady)
    #expect(store.state.sessions[id: id]?.summary == "After retry.")
    #expect(store.state.sessions[id: id]?.summarizationFailure == nil)
  }

  @Test
  func launchRecoveryPurgesAudioMarksLostAndSweepsOrphans() async {
    let recordingID = UUID(0)
    let transcribingID = UUID(1)
    let queuedID = UUID(2)
    let deniedID = UUID(3)
    let interviewingID = UUID(4)
    let standaloneInterviewingID = UUID(5)
    let linkedInterviewArtifactID = UUID(40)
    let standaloneInterviewArtifactID = UUID(50)
    let orphanVaultID = UUID(9)
    @Shared(.sessions) var sessions = [
      Session(id: recordingID, startDate: Date(timeIntervalSince1970: 0), state: .recording),
      Session(id: transcribingID, startDate: Date(timeIntervalSince1970: 60), state: .transcribing),
      Session(
        id: queuedID, startDate: Date(timeIntervalSince1970: 120), state: .awaitingSummarization),
      Session(
        id: deniedID, startDate: Date(timeIntervalSince1970: 180), state: .permissionDenied),
      Session(
        id: interviewingID,
        startDate: Date(timeIntervalSince1970: 240),
        state: .interviewing,
        summary: "Recovered summary",
        interviewID: linkedInterviewArtifactID
      ),
      Session(
        id: standaloneInterviewingID,
        kind: .interview,
        startDate: Date(timeIntervalSince1970: 300),
        state: .interviewing,
        interviewID: standaloneInterviewArtifactID
      ),
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
      $0.interviewArtifacts.destroy = { id in
        events.withValue { $0.append("interview.destroy(\(id))") }
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
        $0[id: interviewingID]?.state = .summaryReady
        $0[id: interviewingID]?.interviewID = nil
        $0[id: standaloneInterviewingID]?.state = .lost
        $0[id: standaloneInterviewingID]?.lossReason =
          "The app closed before this interview finished, so its partial answers were removed."
        $0[id: standaloneInterviewingID]?.interviewID = nil
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
    #expect(store.state.sessions[id: deniedID]?.state == .permissionDenied)
    #expect(store.state.sessions[id: interviewingID]?.state == .summaryReady)
    #expect(store.state.sessions[id: standaloneInterviewingID]?.state == .lost)
    #expect(events.value.contains("interview.destroy(\(linkedInterviewArtifactID))"))
    #expect(events.value.contains("interview.destroy(\(standaloneInterviewArtifactID))"))

    await task.cancel()
  }

  @Test
  func discardedSessionIsRemoved() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.interviewArtifacts.destroy = { _ in }
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.audioRecorder.requestRecordPermission = { true }
    }
    store.exhaustivity = .off

    await store.send(.newConversationButtonTapped) {
      $0.isRequestingMicrophonePermission = true
    }
    await store.receive(\.recordPermissionResponse) {
      $0.isRequestingMicrophonePermission = false
    }
    #expect(store.state.sessions.count == 1)
    #expect(store.state.activeSession != nil)

    await store.send(.activeSession(.presented(.delegate(.discarded(UUID(0)))))) {
      $0.activeSession = nil
    }
    #expect(store.state.sessions.isEmpty)
  }

  @Test
  func standaloneInterviewStartsWithoutConversationPermission() async {
    @Shared(.sessions) var sessions: IdentifiedArrayOf<Session> = []
    let permissionRequests = LockIsolated(0)
    var state = AppFeature.State()
    state.isConnected = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.audioRecorder.requestRecordPermission = {
        permissionRequests.withValue { $0 += 1 }
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.newInterviewButtonTapped)

    #expect(permissionRequests.value == 0)
    #expect(store.state.activeSession == nil)
    #expect(store.state.path.count == 1)
    #expect(store.state.sessions.count == 1)
    #expect(store.state.sessions[0].id == UUID(0))
    #expect(store.state.sessions[0].kind == .interview)
    #expect(store.state.sessions[0].state == .interviewing)
    #expect(store.state.sessions[0].summary == nil)
    #expect(store.state.sessions[0].interviewID == UUID(1))
  }

  @Test
  func standaloneInterviewWhileOfflineDoesNotCreateSession() async {
    @Shared(.sessions) var sessions: IdentifiedArrayOf<Session> = []
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.newInterviewButtonTapped)

    #expect(store.state.alert != nil)
    #expect(store.state.sessions.isEmpty)
    #expect(store.state.path.isEmpty)
  }

  @Test
  func standaloneInterviewCompletionAndDiscardManageIndependentSession() async throws {
    @Shared(.sessions) var sessions: IdentifiedArrayOf<Session> = []
    let destroyed = LockIsolated<[UUID]>([])
    var state = AppFeature.State()
    state.isConnected = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 100)
      $0.interviewArtifacts.destroy = { id in
        destroyed.withValue { $0.append(id) }
      }
    }
    store.exhaustivity = .off

    await store.send(.newInterviewButtonTapped)
    let completedRecord = InterviewRecord(
      id: UUID(1),
      sessionID: UUID(0),
      startedAt: Date(timeIntervalSince1970: 100),
      endedAt: Date(timeIntervalSince1970: 160),
      summaryUsed: nil,
      turns: [],
      extraction: nil,
      model: AnthropicModel.opus
    )
    await store.send(
      .path(.element(id: 0, action: .interview(.delegate(.interviewFinished(completedRecord)))))
    )

    #expect(store.state.path.isEmpty)
    #expect(store.state.sessions[id: UUID(0)]?.state == .saved)
    #expect(store.state.sessions[id: UUID(0)]?.kind == .interview)
    #expect(store.state.sessions[id: UUID(0)]?.interviewID == UUID(1))
    #expect(destroyed.value.isEmpty)

    await store.send(.newInterviewButtonTapped)
    let discardPathID = try #require(store.state.path.ids.first)
    await store.send(
      .path(
        .element(
          id: discardPathID,
          action: .interview(.delegate(.discarded(sessionID: UUID(2), interviewID: UUID(3))))
        )
      )
    ).finish()

    #expect(store.state.sessions[id: UUID(2)] == nil)
    #expect(store.state.path.isEmpty)
    #expect(destroyed.value == [UUID(3)])
  }

  @Test
  func deletingCompletedInterviewRemovesRetainedArtifacts() async {
    let sessionID = UUID(0)
    let interviewID = UUID(1)
    @Shared(.sessions) var sessions = [
      Session(
        id: sessionID,
        kind: .interview,
        startDate: Date(timeIntervalSince1970: 0),
        state: .saved,
        interviewID: interviewID
      )
    ]
    let destroyed = LockIsolated<[UUID]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.audioStorage.destroyRecording = { _ in }
      $0.transcriptVault.destroy = { _ in }
      $0.interviewArtifacts.destroy = { id in
        destroyed.withValue { $0.append(id) }
      }
    }
    store.exhaustivity = .off

    await store.send(.sessionTapped(sessionID))
    await store.send(
      .path(.element(id: 0, action: .detail(.delegate(.delete(sessionID)))))
    ).finish()

    #expect(store.state.sessions.isEmpty)
    #expect(store.state.path.isEmpty)
    #expect(destroyed.value == [interviewID])
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
    #expect(store.state.sessions[id: sessionID]?.state == .interviewing)
    #expect(store.state.sessions[id: sessionID]?.interviewID == interviewID)

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
    #expect(store.state.sessions[id: sessionID]?.state == .summaryReady)
  }

  @Test
  func microphoneDenialPersistsDeniedSessionWithoutStartingCapture() async {
    @Shared(.sessions) var sessions: IdentifiedArrayOf<Session> = []
    let recorderStarts = LockIsolated(0)
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 10)
      $0.audioRecorder.requestRecordPermission = { false }
      $0.audioRecorder.startRecording = { _ in
        recorderStarts.withValue { $0 += 1 }
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.newConversationButtonTapped)
    await store.receive(\.recordPermissionResponse)

    #expect(store.state.activeSession == nil)
    #expect(store.state.sessions.count == 1)
    #expect(store.state.sessions[0].state == .permissionDenied)
    #expect(store.state.sessions[0].lossReason?.contains("denied") == true)
    #expect(store.state.alert != nil)
    #expect(recorderStarts.value == 0)
  }

  @Test
  func abandoningInterviewRestoresSummaryReady() async {
    let sessionID = UUID(0)
    @Shared(.sessions) var sessions = [
      Session(
        id: sessionID,
        startDate: Date(timeIntervalSince1970: 0),
        state: .summaryReady,
        summary: "A summary."
      )
    ]
    var state = AppFeature.State()
    state.isConnected = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.interviewArtifacts.destroy = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.sessionTapped(sessionID))
    await store.send(.path(.element(id: 0, action: .detail(.delegate(.startInterview(sessionID))))))
    #expect(store.state.sessions[id: sessionID]?.state == .interviewing)

    await store.send(.path(.popFrom(id: 1)))
    #expect(store.state.sessions[id: sessionID]?.state == .summaryReady)
    #expect(store.state.path.count == 1)
  }

  @Test
  func deniedInterviewAuthorizationRestoresSummaryReadyWhenRouteCloses() async {
    let sessionID = UUID(0)
    @Shared(.sessions) var sessions = [
      Session(
        id: sessionID,
        startDate: Date(timeIntervalSince1970: 0),
        state: .summaryReady,
        summary: "A summary."
      )
    ]
    var state = AppFeature.State()
    state.isConnected = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.speechClient.requestAuthorization = { .denied }
      $0.interviewArtifacts.destroy = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.sessionTapped(sessionID))
    await store.send(
      .path(.element(id: 0, action: .detail(.delegate(.startInterview(sessionID)))))
    )
    #expect(store.state.sessions[id: sessionID]?.state == .interviewing)

    await store.send(.path(.element(id: 1, action: .interview(.task)))).finish()
    #expect(store.state.sessions[id: sessionID]?.state == .interviewing)

    await store.send(.path(.popFrom(id: 1)))
    #expect(store.state.sessions[id: sessionID]?.state == .summaryReady)
    #expect(store.state.path.count == 1)
  }

  @Test
  func retryNowTargetsOnlyRequestedSession() async {
    let firstID = UUID(0)
    let secondID = UUID(1)
    let blocked = SummarizationFailure(
      kind: .credentialsMissing,
      attemptCount: 1,
      nextRetryAt: nil,
      requiredAction: .openSettings
    )
    @Shared(.sessions) var sessions = [
      Session(
        id: firstID,
        startDate: Date(timeIntervalSince1970: 0),
        state: .awaitingSummarization,
        summarizationFailure: blocked
      ),
      Session(
        id: secondID,
        startDate: Date(timeIntervalSince1970: 1),
        state: .awaitingSummarization,
        summarizationFailure: blocked
      ),
    ]
    var state = AppFeature.State()
    state.isConnected = true
    state.path.append(.detail(SessionDetail.State(session: Shared($sessions[id: firstID])!)))
    let summarizedIDs = LockIsolated<[Session.ID]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 20)
      $0.transcriptVault.load = { _ in "transcript" }
      $0.transcriptVault.destroy = { _ in }
      $0.conversationService.summarize = { request in
        summarizedIDs.withValue { $0.append(request.sessionID) }
        return SummaryResponse(summary: "Recovered", consentUtterance: nil)
      }
    }
    store.exhaustivity = .off

    await store.send(
      .path(.element(id: 0, action: .detail(.delegate(.retrySummarization(firstID)))))
    )
    await store.receive(\.transcriptDestroyed)

    #expect(summarizedIDs.value == [firstID])
    #expect(store.state.sessions[id: firstID]?.state == .summaryReady)
    #expect(store.state.sessions[id: firstID]?.summarizationFailure == nil)
    #expect(store.state.sessions[id: secondID]?.state == .awaitingSummarization)
    #expect(store.state.sessions[id: secondID]?.summarizationFailure == blocked)
  }

  @Test
  func persistedDueRetryRunsAfterRelaunchDrain() async {
    let id = UUID(0)
    @Shared(.sessions) var sessions = [
      Session(
        id: id,
        startDate: Date(timeIntervalSince1970: 0),
        state: .awaitingSummarization,
        summarizationFailure: SummarizationFailure(
          kind: .network,
          attemptCount: 2,
          nextRetryAt: Date(timeIntervalSince1970: 10),
          requiredAction: .automaticRetry
        )
      )
    ]
    var state = AppFeature.State()
    state.isConnected = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 20)
      $0.transcriptVault.load = { _ in "transcript" }
      $0.transcriptVault.destroy = { _ in }
      $0.conversationService.summarize = { _ in
        SummaryResponse(summary: "Recovered after launch", consentUtterance: nil)
      }
    }
    store.exhaustivity = .off

    await store.send(.drainQueue)
    await store.receive(\.transcriptDestroyed)
    #expect(store.state.sessions[id: id]?.state == .summaryReady)
    #expect(store.state.sessions[id: id]?.summarizationFailure == nil)
  }

  @Test
  func credentialActionPushesSettingsWithoutClearingFailure() async {
    let id = UUID(0)
    let failure = SummarizationFailure(
      kind: .credentialsRejected,
      attemptCount: 1,
      nextRetryAt: nil,
      requiredAction: .openSettings
    )
    @Shared(.sessions) var sessions = [
      Session(
        id: id,
        startDate: Date(timeIntervalSince1970: 0),
        state: .awaitingSummarization,
        summarizationFailure: failure
      )
    ]
    var state = AppFeature.State()
    state.path.append(.detail(SessionDetail.State(session: Shared($sessions[id: id])!)))
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.path(.element(id: 0, action: .detail(.delegate(.openSettings)))))
    #expect(store.state.path.count == 2)
    #expect(store.state.sessions[id: id]?.summarizationFailure == failure)
  }

  @Test
  func summarizationFailureMessagesReuseConversationServiceCopy() {
    let matchingKinds: [(SummarizationFailure.Kind, ConversationServiceError)] = [
      (.credentialsMissing, .credentialsMissing),
      (.credentialsRejected, .credentialsRejected),
      (.network, .network),
      (.rateLimited, .rateLimited(retryAfterSeconds: nil)),
      (.serviceUnavailable, .serviceUnavailable),
      (.requestRejected, .requestRejected),
      (.invalidResponse, .invalidResponse),
      (.refusal, .contentRefused),
      (.truncation, .responseTruncated),
      (.unknown, .unknown),
    ]

    for (kind, serviceError) in matchingKinds {
      let failure = SummarizationFailure(
        kind: kind,
        attemptCount: 1,
        nextRetryAt: nil,
        requiredAction: .retryNow
      )
      #expect(failure.userMessage == serviceError.userMessage)
    }

    let transcriptFailure = SummarizationFailure(
      kind: .transcriptUnavailable,
      attemptCount: 1,
      nextRetryAt: nil,
      requiredAction: .contactSupport
    )
    #expect(
      transcriptFailure.userMessage
        == "The encrypted transcript could not be loaded. Contact support."
    )
  }

  @Test
  func unknownWaitsForManualRetryWhileDeterministicFailureRequiresSupport() async {
    let manualID = UUID(0)
    let supportID = UUID(1)
    @Shared(.sessions) var sessions = [
      Session(
        id: manualID,
        startDate: Date(timeIntervalSince1970: 0),
        state: .awaitingSummarization
      ),
      Session(
        id: supportID,
        startDate: Date(timeIntervalSince1970: 1),
        state: .awaitingSummarization
      ),
    ]
    let results = LockIsolated<[Result<SummaryResponse, ConversationServiceError>]>([
      .failure(.unknown),
      .failure(.invalidResponse),
      .success(SummaryResponse(summary: "Manually recovered", consentUtterance: nil)),
    ])
    var state = AppFeature.State()
    state.isConnected = true
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 20)
      $0.transcriptVault.load = { _ in "transcript" }
      $0.transcriptVault.destroy = { _ in }
      $0.conversationService.summarize = { _ in
        try results.withValue { $0.removeFirst() }.get()
      }
    }
    store.exhaustivity = .off

    await store.send(.drainQueue)
    await store.receive(\.summarizationResponse)
    await store.receive(\.summarizationResponse)

    let manualFailure = store.state.sessions[id: manualID]?.summarizationFailure
    #expect(manualFailure?.kind == .unknown)
    #expect(manualFailure?.requiredAction == .retryNow)
    #expect(manualFailure?.nextRetryAt == nil)
    #expect(manualFailure?.attemptCount == 1)
    #expect(
      store.state.sessions[id: supportID]?.summarizationFailure?.requiredAction
        == .contactSupport
    )
    #expect(store.state.sessions[id: supportID]?.summarizationFailure?.kind == .invalidResponse)
    #expect(results.value.count == 1)

    await store.send(.sessionTapped(manualID))
    await store.send(
      .path(.element(id: 0, action: .detail(.delegate(.retrySummarization(manualID)))))
    )
    await store.receive(\.transcriptDestroyed)

    #expect(store.state.sessions[id: manualID]?.state == .summaryReady)
    #expect(store.state.sessions[id: manualID]?.summarizationFailure == nil)
    #expect(store.state.sessions[id: supportID]?.state == .awaitingSummarization)
    #expect(
      store.state.sessions[id: supportID]?.summarizationFailure?.requiredAction
        == .contactSupport
    )
  }
}
