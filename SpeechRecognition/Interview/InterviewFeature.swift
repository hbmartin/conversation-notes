import ComposableArchitecture
import Speech
import SwiftUI

/// The post-conversation voice interview: a Claude agent asks one question at a time (spoken by
/// TTS), the operator answers by voice (streamed by STT, committed on a silence timeout or the
/// Done button), and the loop ends when the agent calls `record_interview` with the full field
/// schema. The entire API message history lives in state so a retry re-sends it verbatim.
@Reducer
struct Interview {
  @ObservableState
  struct State: Equatable {
    let interviewID: UUID
    let sessionID: UUID
    let summary: String
    var phase: Phase = .idle
    var currentQuestion = ""
    var partialAnswer = ""
    var turns: [InterviewTurn] = []
    var messages: [AnthropicMessage] = []
    var extraction: InterviewExtraction?
    var pendingRecord: InterviewRecord?
    var failure: FailureState?
    var startedAt: Date?

    enum Phase: Equatable {
      case idle
      case processing
      case speaking
      case listening
      case finishing
      case finished
      case failed
    }

    struct FailureState: Equatable {
      var message: String
      var isRetryable: Bool
      /// STT failures retry by re-entering listening; agent failures re-send the turn.
      var resumesListening = false
    }
  }

  enum Action {
    case task
    case speechAuthorizationDenied
    case agentResponse(Result<AssistantTurn, any Error>)
    case questionSpoken
    case sttPartial(String)
    case sttFailed
    case silenceTimerFired
    case doneButtonTapped
    case answerCommitted(String)
    case closingSpoken
    case saveFailed(InterviewRecord)
    case retryButtonTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate {
      case interviewFinished(InterviewRecord)
    }
  }

  @Dependency(\.anthropicClient) var anthropic
  @Dependency(\.ttsClient) var tts
  @Dependency(\.speechClient) var speechClient
  @Dependency(\.interviewArtifacts) var artifacts
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now

  /// How long a pause in the operator's speech commits the current answer.
  static let silenceTimeout: Duration = .seconds(2)

  private enum CancelID {
    case stt
    case silence
    case tts
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        guard state.phase == .idle else { return .none }
        state.startedAt = self.now
        state.phase = .processing
        state.messages = [InterviewAgent.openingUserMessage]
        return .merge(
          .run { send in
            guard await self.speechClient.requestAuthorization() == .authorized else {
              await send(.speechAuthorizationDenied)
              return
            }
          },
          self.requestTurn(state)
        )

      case .speechAuthorizationDenied:
        state.phase = .failed
        state.failure = State.FailureState(
          message: "Speech recognition permission is required for the voice interview.",
          isRetryable: false
        )
        return .none

      case .agentResponse(.success(let turn)):
        state.messages.append(AnthropicMessage(role: .assistant, content: turn.content))
        if let toolUse = turn.toolUse, toolUse.name == InterviewAgent.toolName {
          do {
            state.extraction = try JSONDecoder().decode(
              InterviewExtraction.self,
              from: toolUse.input.encodedData()
            )
          } catch {
            // Defensive: `strict: true` makes schema-invalid tool input a dead path.
            state.phase = .failed
            state.failure = State.FailureState(
              message: "The interview agent returned malformed data.",
              isRetryable: true
            )
            return .none
          }
          state.phase = .finishing
          state.currentQuestion = InterviewAgent.closingRemark
          return .run { send in
            do {
              try await self.tts.speak(InterviewAgent.closingRemark)
            } catch is CancellationError {
              return
            } catch {}
            await send(.closingSpoken)
          }
          .cancellable(id: CancelID.tts, cancelInFlight: true)
        }
        guard turn.stopReason == .endTurn, !turn.text.isEmpty else {
          state.phase = .failed
          state.failure = State.FailureState(
            message: "The interview agent returned an unexpected response.",
            isRetryable: true
          )
          return .none
        }
        state.currentQuestion = turn.text
        state.phase = .speaking
        return .run { [question = turn.text] send in
          do {
            try await self.tts.speak(question)
          } catch is CancellationError {
            return
          } catch {}
          await send(.questionSpoken)
        }
        .cancellable(id: CancelID.tts, cancelInFlight: true)

      case .agentResponse(.failure(let error)):
        state.phase = .failed
        state.failure = State.FailureState(
          message: (error as? AnthropicClientError)?.userMessage
            ?? "Something went wrong talking to the interview agent.",
          isRetryable: (error as? AnthropicClientError)?.isRetryable ?? true
        )
        return .merge(.cancel(id: CancelID.stt), .cancel(id: CancelID.silence))

      case .questionSpoken:
        guard state.phase == .speaking else { return .none }
        state.phase = .listening
        state.partialAnswer = ""
        return .run { [turnIndex = state.turns.count, interviewID = state.interviewID] send in
          let recordingURL = try? self.artifacts
            .interviewDirectory(interviewID)
            .appending(component: "answer-\(turnIndex).caf")
          let request = SFSpeechAudioBufferRecognitionRequest()
          request.shouldReportPartialResults = true
          for try await result in await self.speechClient.startTask(request, recordingURL) {
            await send(.sttPartial(result.bestTranscription.formattedString))
          }
        } catch: { _, send in
          await send(.sttFailed)
        }
        .cancellable(id: CancelID.stt, cancelInFlight: true)

      case .sttPartial(let text):
        guard state.phase == .listening else { return .none }
        state.partialAnswer = text
        return .run { send in
          try await self.clock.sleep(for: Self.silenceTimeout)
          await send(.silenceTimerFired)
        }
        .cancellable(id: CancelID.silence, cancelInFlight: true)

      case .silenceTimerFired, .doneButtonTapped:
        guard state.phase == .listening, !state.partialAnswer.isEmpty else { return .none }
        return .merge(
          .cancel(id: CancelID.silence),
          .run { [answer = state.partialAnswer] send in
            await self.speechClient.finishTask()
            await send(.answerCommitted(answer))
          }
        )

      case .answerCommitted(let answer):
        state.turns.append(
          InterviewTurn(
            index: state.turns.count,
            question: state.currentQuestion,
            answerTranscript: answer,
            audioFileName: "answer-\(state.turns.count).caf",
            askedAt: self.now
          )
        )
        state.messages.append(AnthropicMessage(role: .user, content: [.text(answer)]))
        state.partialAnswer = ""
        state.phase = .processing
        return self.requestTurn(state)

      case .closingSpoken:
        let record = InterviewRecord(
          id: state.interviewID,
          sessionID: state.sessionID,
          startedAt: state.startedAt ?? self.now,
          endedAt: self.now,
          summaryUsed: state.summary,
          turns: state.turns,
          extraction: state.extraction,
          model: AnthropicModel.opus
        )
        state.phase = .finished
        return .run { send in
          try self.artifacts.save(record)
          await send(.delegate(.interviewFinished(record)))
        } catch: { _, send in
          await send(.saveFailed(record))
        }

      case .saveFailed(let record):
        state.phase = .failed
        state.pendingRecord = record
        state.failure = State.FailureState(
          message: "The interview could not be saved to disk.",
          isRetryable: true
        )
        return .none

      case .sttFailed:
        guard state.phase == .listening else { return .none }
        state.phase = .failed
        state.failure = State.FailureState(
          message: "Speech recognition failed.",
          isRetryable: true,
          resumesListening: true
        )
        return .cancel(id: CancelID.silence)

      case .retryButtonTapped:
        guard state.phase == .failed, let failure = state.failure else { return .none }
        guard failure.isRetryable else { return .none }
        state.failure = nil
        if failure.resumesListening {
          // Re-enter listening for the same question; the message history is unchanged.
          state.phase = .speaking
          return .send(.questionSpoken)
        }
        if let record = state.pendingRecord {
          return .run { send in
            try self.artifacts.save(record)
            await send(.delegate(.interviewFinished(record)))
          } catch: { _, send in
            await send(.saveFailed(record))
          }
        }
        state.phase = .processing
        return self.requestTurn(state)

      case .delegate:
        return .none
      }
    }
  }

  private func requestTurn(_ state: State) -> Effect<Action> {
    .run { [summary = state.summary, messages = state.messages] send in
      await send(
        .agentResponse(
          Result {
            try await self.anthropic.interviewTurn(
              InterviewTurnRequest(
                system: InterviewAgent.systemPrompt(summary: summary),
                messages: messages,
                tools: [InterviewAgent.recordInterviewTool]
              )
            )
          }
        )
      )
    }
  }
}

struct InterviewView: View {
  let store: StoreOf<Interview>

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      switch store.phase {
      case .idle, .processing:
        ProgressView()
        Text("Thinking…")
          .foregroundStyle(.secondary)

      case .speaking, .listening, .finishing:
        Image(
          systemName: store.phase == .listening
            ? "waveform.circle.fill" : "speaker.wave.2.circle.fill"
        )
        .font(.system(size: 56))
        .foregroundStyle(store.phase == .listening ? .red : .blue)
        .symbolEffect(.pulse, isActive: true)

        Text(store.currentQuestion)
          .font(.title2)
          .multilineTextAlignment(.center)
          .padding(.horizontal)

        if store.phase == .listening {
          Text(store.partialAnswer.isEmpty ? "Listening…" : store.partialAnswer)
            .foregroundStyle(store.partialAnswer.isEmpty ? .secondary : .primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

          Button("Done") {
            store.send(.doneButtonTapped)
          }
          .buttonStyle(.borderedProminent)
        }

      case .finished:
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 56))
          .foregroundStyle(.green)
        Text("Interview recorded")
          .font(.title2)

      case .failed:
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 56))
          .foregroundStyle(.orange)
        Text(store.failure?.message ?? "Something went wrong.")
          .multilineTextAlignment(.center)
          .padding(.horizontal)
        if store.failure?.isRetryable == true {
          Button("Retry") {
            store.send(.retryButtonTapped)
          }
          .buttonStyle(.borderedProminent)
        }
      }

      Spacer()

      Text("Question \(store.turns.count + 1)")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .opacity(store.phase == .finished ? 0 : 1)
    }
    .padding()
    .navigationTitle("Interview")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(store.phase != .finished && store.phase != .failed)
    .task {
      await store.send(.task).finish()
    }
  }
}

#Preview {
  NavigationStack {
    InterviewView(
      store: Store(
        initialState: Interview.State(
          interviewID: UUID(),
          sessionID: UUID(),
          summary: "The MSL discussed phase 3 efficacy data with a cardiologist."
        )
      ) {
        Interview()
      }
    )
  }
}
