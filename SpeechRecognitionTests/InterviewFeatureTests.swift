import ComposableArchitecture
import Foundation
import Speech
import Testing

@testable import SpeechRecognition

private let extractionJSON = """
  {
    "hcp_specialty": "Cardiology",
    "topics_discussed": ["Phase 3 efficacy data"],
    "key_scientific_questions": "Subgroup analysis methodology",
    "unanswered_follow_ups": "None",
    "med_info_requests": "None",
    "adverse_event_reported": false,
    "adverse_event_detail": "",
    "off_label_discussed": false,
    "off_label_detail": "",
    "hcp_sentiment": "positive",
    "commitments_next_steps": "Send publication",
    "follow_up_needed": true
  }
  """

private let expectedExtraction = try! JSONDecoder().decode(
  InterviewExtraction.self,
  from: Data(extractionJSON.utf8)
)

private func questionStep(
  _ text: String,
  audit: ServiceAuditMetadata? = nil
) -> InterviewStep {
  .question(text, audit: audit)
}

private func completedStep(
  audit: ServiceAuditMetadata? = nil
) -> InterviewStep {
  .completed(expectedExtraction, audit: audit)
}

private func partialResult(_ text: String) -> SpeechRecognitionResult {
  SpeechRecognitionResult(
    bestTranscription: Transcription(formattedString: text, segments: []),
    isFinal: false,
    transcriptions: []
  )
}

@MainActor
struct InterviewFeatureTests {
  @MainActor
  private struct Harness {
    let clock = TestClock()
    let serviceResults: LockIsolated<[Result<InterviewStep, ConversationServiceError>]>
    let contexts = LockIsolated<[InterviewContext]>([])
    let sttContinuations = LockIsolated<
      [AsyncThrowingStream<SpeechRecognitionResult, any Error>.Continuation]
    >([])
    let savedRecord = LockIsolated<InterviewRecord?>(nil)
    let store: TestStore<Interview.State, Interview.Action>

    init(
      summary: String? = "A summary.",
      serviceScript: [Result<InterviewStep, ConversationServiceError>]
    ) {
      let serviceResults = LockIsolated(serviceScript)
      self.serviceResults = serviceResults
      let contexts = self.contexts
      let sttContinuations = self.sttContinuations
      let savedRecord = self.savedRecord
      let clock = self.clock
      self.store = TestStore(
        initialState: Interview.State(
          interviewID: UUID(42),
          sessionID: UUID(0),
          summary: summary
        )
      ) {
        Interview()
      } withDependencies: {
        $0.continuousClock = clock
        $0.date.now = Date(timeIntervalSince1970: 0)
        $0.conversationService.nextInterviewStep = { context in
          contexts.withValue { $0.append(context) }
          return try serviceResults.withValue { $0.removeFirst() }.get()
        }
        $0.ttsClient.speak = { _ in }
        $0.ttsClient.stop = {}
        $0.speechClient.requestAuthorization = { .authorized }
        $0.speechClient.startTask = { _, _ in
          let (stream, continuation) =
            AsyncThrowingStream.makeStream(of: SpeechRecognitionResult.self)
          sttContinuations.withValue { $0.append(continuation) }
          return stream
        }
        $0.speechClient.finishTask = {
          sttContinuations.withValue { $0.last?.finish() }
        }
        $0.interviewArtifacts.interviewDirectory = { _ in
          URL(fileURLWithPath: "/dev/null/interviews")
        }
        $0.interviewArtifacts.save = { record in
          savedRecord.setValue(record)
        }
      }
    }

    func startAuthorized() async {
      await self.store.send(.task) {
        $0.phase = .authorizing
        $0.startedAt = Date(timeIntervalSince1970: 0)
      }
      await self.store.receive(\.speechAuthorizationResponse) {
        $0.phase = .processing
      }
    }

    func yieldPartial(_ text: String) {
      _ = self.sttContinuations.withValue { $0.last?.yield(partialResult(text)) }
    }
  }

  @Test
  func happyPathPersistsDomainHistoryAndAuditTrail() async {
    let firstAudit = ServiceAuditMetadata(
      requestID: "req-1",
      modelVersion: "model-1",
      promptVersion: "interview-v2"
    )
    let finalAudit = ServiceAuditMetadata(
      requestID: "req-2",
      modelVersion: "model-1",
      promptVersion: "interview-v2"
    )
    let harness = Harness(serviceScript: [
      .success(questionStep("What is the HCP's specialty?", audit: firstAudit)),
      .success(completedStep(audit: finalAudit)),
    ])
    let store = harness.store

    await harness.startAuthorized()
    await store.receive(\.serviceResponse.success) {
      $0.serviceAuditTrail = [firstAudit]
      $0.currentQuestion = "What is the HCP's specialty?"
      $0.phase = .speaking
    }
    await store.receive(\.questionSpoken) {
      $0.phase = .listening
    }

    harness.yieldPartial("Cardiology")
    await store.receive(\.sttPartial) {
      $0.partialAnswer = "Cardiology"
    }
    await store.send(.doneButtonTapped) {
      $0.phase = .committing
    }
    await store.receive(\.answerCommitted) {
      $0.turns = [
        InterviewTurn(
          index: 0,
          question: "What is the HCP's specialty?",
          answerTranscript: "Cardiology",
          audioFileName: "answer-0.caf",
          askedAt: Date(timeIntervalSince1970: 0)
        )
      ]
      $0.partialAnswer = ""
      $0.phase = .processing
    }

    await store.receive(\.serviceResponse.success) {
      $0.serviceAuditTrail.append(finalAudit)
      $0.extraction = expectedExtraction
      $0.phase = .finishing
      $0.currentQuestion = InterviewAgent.closingRemark
    }
    await store.receive(\.closingSpoken) {
      $0.phase = .finished
    }
    await store.receive(\.delegate.interviewFinished)

    #expect(harness.contexts.value.count == 2)
    #expect(harness.contexts.value[0].exchanges.isEmpty)
    #expect(
      harness.contexts.value[1].exchanges
        == [InterviewExchange(question: "What is the HCP's specialty?", answer: "Cardiology")]
    )
    #expect(harness.savedRecord.value?.model == "model-1")
    #expect(harness.savedRecord.value?.serviceAuditTrail == [firstAudit, finalAudit])
    #expect(harness.savedRecord.value?.extraction == expectedExtraction)
  }

  @Test
  func standaloneInterviewUsesNoSummaryAndPersistsThatOrigin() async {
    let harness = Harness(summary: nil, serviceScript: [.success(completedStep())])
    let store = harness.store

    await harness.startAuthorized()
    await store.receive(\.serviceResponse.success) {
      $0.extraction = expectedExtraction
      $0.phase = .finishing
      $0.currentQuestion = InterviewAgent.closingRemark
    }
    await store.receive(\.closingSpoken) {
      $0.phase = .finished
    }
    await store.receive(\.delegate.interviewFinished)

    #expect(harness.contexts.value.count == 1)
    #expect(harness.contexts.value[0].summary == nil)
    #expect(harness.savedRecord.value?.summaryUsed == nil)
    #expect(harness.savedRecord.value?.sessionID == UUID(0))
  }

  @Test
  func standaloneDiscardConfirmsAndDelegatesCleanup() async {
    let harness = Harness(summary: nil, serviceScript: [])
    let store = harness.store
    store.exhaustivity = .off

    await store.send(.discardButtonTapped)
    #expect(store.state.alert != nil)

    await store.send(.alert(.presented(.confirmDiscard)))
    await store.receive(\.delegate.discarded)
  }

  @Test
  func authorizationDenialNeverStartsCloudWorkAndIgnoresLateResponse() async {
    let harness = Harness(serviceScript: [])
    let store = harness.store
    let (authorization, authorizationContinuation) =
      AsyncStream.makeStream(of: SFSpeechRecognizerAuthorizationStatus.self)
    store.dependencies.speechClient.requestAuthorization = {
      for await status in authorization { return status }
      return .denied
    }

    let task = await store.send(.task) {
      $0.phase = .authorizing
      $0.startedAt = Date(timeIntervalSince1970: 0)
    }
    await Task.yield()
    #expect(harness.contexts.value.isEmpty)

    authorizationContinuation.yield(.denied)
    authorizationContinuation.finish()
    await store.receive(\.speechAuthorizationResponse) {
      $0.phase = .failed
      $0.failure = Interview.State.FailureState(
        message: "Speech recognition permission is required for the voice interview.",
        isRetryable: false,
        settingsDestination: .system
      )
    }
    #expect(harness.contexts.value.isEmpty)

    await store.send(.serviceResponse(.success(questionStep("Late question"))))
    #expect(store.state.phase == .failed)
    #expect(harness.contexts.value.isEmpty)
    await task.cancel()
  }

  @Test
  func authorizationMustCompleteBeforeFirstServiceRequest() async {
    let harness = Harness(serviceScript: [.success(questionStep("First question?"))])
    let store = harness.store
    let (authorization, authorizationContinuation) =
      AsyncStream.makeStream(of: SFSpeechRecognizerAuthorizationStatus.self)
    store.dependencies.speechClient.requestAuthorization = {
      for await status in authorization { return status }
      return .denied
    }

    await store.send(.task) {
      $0.phase = .authorizing
      $0.startedAt = Date(timeIntervalSince1970: 0)
    }
    await Task.yield()
    #expect(harness.contexts.value.isEmpty)

    authorizationContinuation.yield(.authorized)
    authorizationContinuation.finish()
    await store.receive(\.speechAuthorizationResponse) {
      $0.phase = .processing
    }
    await store.receive(\.serviceResponse.success) {
      $0.currentQuestion = "First question?"
      $0.phase = .speaking
    }
    #expect(harness.contexts.value.count == 1)
    await store.receive(\.questionSpoken) {
      $0.phase = .listening
    }
    harness.sttContinuations.withValue { $0.last?.finish() }
    await store.finish()
  }

  @Test
  func retryableServiceFailureResendsSameDomainContext() async {
    let harness = Harness(serviceScript: [
      .failure(.serviceUnavailable),
      .success(questionStep("First question?")),
    ])
    let store = harness.store

    await harness.startAuthorized()
    await store.receive(\.serviceResponse.failure) {
      $0.phase = .failed
      $0.failure = Interview.State.FailureState(
        message: ConversationServiceError.serviceUnavailable.userMessage,
        isRetryable: true
      )
    }
    await store.send(.retryButtonTapped) {
      $0.failure = nil
      $0.phase = .processing
    }
    await store.receive(\.serviceResponse.success) {
      $0.currentQuestion = "First question?"
      $0.phase = .speaking
    }
    #expect(harness.contexts.value.count == 2)
    #expect(harness.contexts.value[0] == harness.contexts.value[1])
    await store.receive(\.questionSpoken) {
      $0.phase = .listening
    }
    harness.sttContinuations.withValue { $0.last?.finish() }
    await store.finish()
  }

  @Test
  func credentialFailureLinksToAppSettingsAndIsNotRetryable() async {
    let harness = Harness(serviceScript: [.failure(.credentialsMissing)])
    let store = harness.store

    await harness.startAuthorized()
    await store.receive(\.serviceResponse.failure) {
      $0.phase = .failed
      $0.failure = Interview.State.FailureState(
        message: ConversationServiceError.credentialsMissing.userMessage,
        isRetryable: false,
        settingsDestination: .app
      )
    }
    await store.send(.appSettingsButtonTapped)
    await store.receive(\.delegate.openSettings)
    await store.send(.retryButtonTapped)
    #expect(store.state.phase == .failed)
  }

  @Test
  func silenceDebounceCommitsOnlyLatestPartial() async {
    let harness = Harness(serviceScript: [
      .success(questionStep("First question?")),
      .success(questionStep("Second question?")),
    ])
    let store = harness.store
    store.exhaustivity = .off

    await harness.startAuthorized()
    await store.receive(\.serviceResponse.success)
    await store.receive(\.questionSpoken)
    harness.yieldPartial("One")
    await store.receive(\.sttPartial)
    await harness.clock.advance(by: .seconds(1.5))
    harness.yieldPartial("One two")
    await store.receive(\.sttPartial)
    await harness.clock.advance(by: .seconds(1.5))
    #expect(store.state.turns.isEmpty)

    await harness.clock.advance(by: .seconds(0.5))
    await store.receive(\.silenceTimerFired)
    await store.receive(\.answerCommitted)
    #expect(store.state.turns.first?.answerTranscript == "One two")
    await store.receive(\.questionSpoken)
    harness.sttContinuations.withValue { $0.last?.finish() }
  }

  @Test
  func failedSaveRetriesPendingRecordWithoutAnotherServiceCall() async {
    let harness = Harness(serviceScript: [.success(completedStep())])
    let store = harness.store
    store.exhaustivity = .off
    let saveAttempts = LockIsolated(0)
    let savedRecord = harness.savedRecord
    store.dependencies.interviewArtifacts.save = { record in
      let attempt = saveAttempts.withValue { count -> Int in
        count += 1
        return count
      }
      guard attempt > 1 else { throw CocoaError(.fileWriteNoPermission) }
      savedRecord.setValue(record)
    }

    await harness.startAuthorized()
    await store.receive(\.serviceResponse.success)
    await store.receive(\.closingSpoken)
    await store.receive(\.saveFailed)
    #expect(store.state.pendingRecord != nil)

    await store.send(.retryButtonTapped)
    await store.receive(\.delegate.interviewFinished)
    #expect(saveAttempts.value == 2)
    #expect(savedRecord.value?.extraction == expectedExtraction)
    #expect(harness.serviceResults.value.isEmpty)
  }

  @Test
  func sttFailureRetriesByRelisteningWithoutServiceCall() async {
    let harness = Harness(serviceScript: [.success(questionStep("First question?"))])
    let store = harness.store
    store.exhaustivity = .off

    await harness.startAuthorized()
    await store.receive(\.serviceResponse.success)
    await store.receive(\.questionSpoken)
    harness.sttContinuations.withValue {
      $0.last?.finish(throwing: SpeechClient.Failure.taskError)
    }
    await store.receive(\.sttFailed)

    await store.send(.retryButtonTapped)
    await store.receive(\.questionSpoken)
    #expect(harness.contexts.value.count == 1)
    #expect(harness.serviceResults.value.isEmpty)
    harness.sttContinuations.withValue { $0.last?.finish() }
  }
}
