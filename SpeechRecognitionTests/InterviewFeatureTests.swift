import ComposableArchitecture
import Foundation
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

private func questionTurn(_ text: String) -> AssistantTurn {
  AssistantTurn(content: [.text(text)], stopReason: .endTurn, text: text, toolUse: nil)
}

private func toolUseTurn() -> AssistantTurn {
  let input = try! JSONValue(parsing: extractionJSON)
  return AssistantTurn(
    content: [.toolUse(id: "toolu_1", name: "record_interview", input: input)],
    stopReason: .toolUse,
    text: "",
    toolUse: AssistantTurn.ToolUseCall(id: "toolu_1", name: "record_interview", input: input)
  )
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
  /// Test harness bundling the scripted agent, controllable STT streams, clock, and spies.
  private struct Harness {
    let clock = TestClock()
    let agentResults: LockIsolated<[Result<AssistantTurn, AnthropicClientError>]>
    let sttContinuations = LockIsolated<
      [AsyncThrowingStream<SpeechRecognitionResult, any Error>.Continuation]
    >([])
    let savedRecord = LockIsolated<InterviewRecord?>(nil)
    let store: TestStore<Interview.State, Interview.Action>

    init(agentScript: [Result<AssistantTurn, AnthropicClientError>]) {
      let agentResults = LockIsolated(agentScript)
      self.agentResults = agentResults
      let sttContinuations = self.sttContinuations
      let savedRecord = self.savedRecord
      let clock = self.clock
      self.store = TestStore(
        initialState: Interview.State(
          interviewID: UUID(42),
          sessionID: UUID(0),
          summary: "A summary."
        )
      ) {
        Interview()
      } withDependencies: {
        $0.continuousClock = clock
        $0.date.now = Date(timeIntervalSince1970: 0)
        $0.anthropicClient.interviewTurn = { _ in
          try agentResults.withValue { $0.removeFirst() }.get()
        }
        $0.ttsClient.speak = { _ in }
        $0.ttsClient.stop = {}
        $0.speechClient.requestAuthorization = { .authorized }
        $0.speechClient.startTask = { _, _ in
          let (stream, continuation) = AsyncThrowingStream
            .makeStream(of: SpeechRecognitionResult.self)
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

    func yieldPartial(_ text: String) {
      sttContinuations.withValue { $0.last?.yield(partialResult(text)) }
    }
  }

  @Test
  func happyPath() async {
    let harness = Harness(agentScript: [
      .success(questionTurn("What is the HCP's specialty?")),
      .success(questionTurn("Were any adverse events mentioned?")),
      .success(toolUseTurn()),
    ])
    let store = harness.store

    await store.send(.task) {
      $0.phase = .processing
      $0.startedAt = Date(timeIntervalSince1970: 0)
      $0.messages = [InterviewAgent.openingUserMessage]
    }

    // Question 1: speak → listen → answer via silence timeout.
    await store.receive(\.agentResponse.success) {
      $0.messages.append(
        AnthropicMessage(role: .assistant, content: [.text("What is the HCP's specialty?")])
      )
      $0.currentQuestion = "What is the HCP's specialty?"
      $0.phase = .speaking
    }
    await store.receive(\.questionSpoken) {
      $0.phase = .listening
    }
    harness.yieldPartial("Card")
    await store.receive(\.sttPartial) { $0.partialAnswer = "Card" }
    harness.yieldPartial("Cardiology")
    await store.receive(\.sttPartial) { $0.partialAnswer = "Cardiology" }
    await harness.clock.advance(by: Interview.silenceTimeout)
    await store.receive(\.silenceTimerFired)
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
      $0.messages.append(AnthropicMessage(role: .user, content: [.text("Cardiology")]))
      $0.partialAnswer = ""
      $0.phase = .processing
    }

    // Question 2: answered via the Done button.
    await store.receive(\.agentResponse.success) {
      $0.messages.append(
        AnthropicMessage(role: .assistant, content: [.text("Were any adverse events mentioned?")])
      )
      $0.currentQuestion = "Were any adverse events mentioned?"
      $0.phase = .speaking
    }
    await store.receive(\.questionSpoken) {
      $0.phase = .listening
    }
    harness.yieldPartial("No adverse events")
    await store.receive(\.sttPartial) { $0.partialAnswer = "No adverse events" }
    await store.send(.doneButtonTapped)
    await store.receive(\.answerCommitted) {
      $0.turns.append(
        InterviewTurn(
          index: 1,
          question: "Were any adverse events mentioned?",
          answerTranscript: "No adverse events",
          audioFileName: "answer-1.caf",
          askedAt: Date(timeIntervalSince1970: 0)
        )
      )
      $0.messages.append(AnthropicMessage(role: .user, content: [.text("No adverse events")]))
      $0.partialAnswer = ""
      $0.phase = .processing
    }

    // Terminal turn: the agent calls `record_interview`.
    let expectedExtraction = try! JSONDecoder().decode(
      InterviewExtraction.self, from: Data(extractionJSON.utf8)
    )
    await store.receive(\.agentResponse.success) {
      $0.messages.append(
        AnthropicMessage(role: .assistant, content: toolUseTurn().content)
      )
      $0.extraction = expectedExtraction
      $0.phase = .finishing
      $0.currentQuestion = InterviewAgent.closingRemark
    }
    await store.receive(\.closingSpoken) {
      $0.phase = .finished
    }
    await store.receive(\.delegate.interviewFinished)

    let record = harness.savedRecord.value
    #expect(record?.id == UUID(42))
    #expect(record?.sessionID == UUID(0))
    #expect(record?.extraction == expectedExtraction)
    #expect(record?.turns.count == 2)
    #expect(record?.turns[0].answerTranscript == "Cardiology")
    #expect(record?.model == AnthropicModel.opus)
  }

  @Test
  func silenceDebounceRestartsOnEveryPartial() async {
    let harness = Harness(agentScript: [
      .success(questionTurn("First question?")),
      // Committing the answer always requests the next turn.
      .success(questionTurn("Second question?")),
    ])
    let store = harness.store
    store.exhaustivity = .off

    await store.send(.task)
    await store.receive(\.agentResponse.success)
    await store.receive(\.questionSpoken)

    harness.yieldPartial("One")
    await store.receive(\.sttPartial)
    await harness.clock.advance(by: .seconds(1.5))

    // A new partial before the timeout restarts the debounce.
    harness.yieldPartial("One two")
    await store.receive(\.sttPartial)
    await harness.clock.advance(by: .seconds(1.5))
    #expect(store.state.phase == .listening)
    #expect(store.state.turns.isEmpty)

    await harness.clock.advance(by: .seconds(0.5))
    await store.receive(\.silenceTimerFired)
    await store.receive(\.answerCommitted)
    #expect(store.state.turns.count == 1)
    #expect(store.state.turns[0].answerTranscript == "One two")

    // Wind down the second question's live STT stream.
    await store.receive(\.questionSpoken)
    harness.sttContinuations.withValue { $0.last?.finish() }
  }

  @Test
  func emptyAnswerNeverAutoCommits() async {
    let harness = Harness(agentScript: [
      .success(questionTurn("First question?"))
    ])
    let store = harness.store
    store.exhaustivity = .off

    await store.send(.task)
    await store.receive(\.agentResponse.success)
    await store.receive(\.questionSpoken)

    // The Done button with no speech does nothing either.
    await store.send(.doneButtonTapped)
    #expect(store.state.phase == .listening)
    #expect(store.state.turns.isEmpty)

    // Wind down the live STT stream.
    harness.sttContinuations.withValue { $0.last?.finish() }
  }

  @Test
  func retryableAgentFailureRetriesWithSameMessages() async {
    let harness = Harness(agentScript: [
      .failure(.serverError(status: 529)),
      .success(questionTurn("First question?")),
    ])
    let store = harness.store

    await store.send(.task) {
      $0.phase = .processing
      $0.startedAt = Date(timeIntervalSince1970: 0)
      $0.messages = [InterviewAgent.openingUserMessage]
    }
    await store.receive(\.agentResponse.failure) {
      $0.phase = .failed
      $0.failure = Interview.State.FailureState(
        message: AnthropicClientError.serverError(status: 529).userMessage,
        isRetryable: true
      )
    }
    let messagesBeforeRetry = store.state.messages

    await store.send(.retryButtonTapped) {
      $0.failure = nil
      $0.phase = .processing
    }
    #expect(store.state.messages == messagesBeforeRetry)
    await store.receive(\.agentResponse.success) {
      $0.messages.append(
        AnthropicMessage(role: .assistant, content: [.text("First question?")])
      )
      $0.currentQuestion = "First question?"
      $0.phase = .speaking
    }
    await store.receive(\.questionSpoken) {
      $0.phase = .listening
    }

    // Wind down the live STT stream so no effect outlives the test.
    harness.sttContinuations.withValue { $0.last?.finish() }
    await store.finish()
  }

  @Test
  func refusalIsTerminal() async {
    let harness = Harness(agentScript: [
      .failure(.refused)
    ])
    let store = harness.store

    await store.send(.task) {
      $0.phase = .processing
      $0.startedAt = Date(timeIntervalSince1970: 0)
      $0.messages = [InterviewAgent.openingUserMessage]
    }
    await store.receive(\.agentResponse.failure) {
      $0.phase = .failed
      $0.failure = Interview.State.FailureState(
        message: AnthropicClientError.refused.userMessage,
        isRetryable: false
      )
    }
    // A retry tap on a non-retryable failure still re-sends (the button is hidden in the UI,
    // and state remains consistent if it is somehow triggered) — but the guard requires a
    // failure to be present, so this is a no-op after clearing.
  }

  @Test
  func sttFailureRetriesByRelistening() async {
    let harness = Harness(agentScript: [
      .success(questionTurn("First question?"))
    ])
    let store = harness.store
    store.exhaustivity = .off

    await store.send(.task)
    await store.receive(\.agentResponse.success)
    await store.receive(\.questionSpoken)

    // The recognizer errors mid-listen.
    harness.sttContinuations.withValue {
      $0.last?.finish(throwing: SpeechClient.Failure.taskError)
    }
    await store.receive(\.sttFailed) {
      $0.phase = .failed
      $0.failure = Interview.State.FailureState(
        message: "Speech recognition failed.",
        isRetryable: true,
        resumesListening: true
      )
    }

    await store.send(.retryButtonTapped) {
      $0.failure = nil
      $0.phase = .speaking
    }
    await store.receive(\.questionSpoken) {
      $0.phase = .listening
    }
    // The message history is untouched: the same question is re-asked without a new API call.
    #expect(harness.agentResults.value.isEmpty)

    // Wind down the live STT stream so no effect outlives the test.
    harness.sttContinuations.withValue { $0.last?.finish() }
  }
}
