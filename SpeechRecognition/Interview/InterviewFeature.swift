import ComposableArchitecture
import Speech
import SwiftUI
import UIKit

/// The post-conversation voice interview: a Claude agent asks one question at a time (spoken by
/// TTS), the operator answers by voice (streamed by STT, committed on a silence timeout or the
/// Done button), and the loop ends when the agent calls `record_interview` with the full field
/// schema. Only domain Q&A history lives in state; the service implementation owns provider
/// messages, prompts, tools, and model selection.
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
    var serviceAuditTrail: [ServiceAuditMetadata] = []
    var extraction: InterviewExtraction?
    var pendingRecord: InterviewRecord?
    var failure: FailureState?
    var startedAt: Date?

    enum Phase: Equatable {
      case idle
      case authorizing
      case processing
      case speaking
      case listening
      case committing
      case finishing
      case finished
      case failed
    }

    struct FailureState: Equatable {
      var message: String
      var isRetryable: Bool
      /// STT failures retry by re-entering listening; agent failures re-send the turn.
      var resumesListening = false
      var settingsDestination: SettingsDestination? = nil

      enum SettingsDestination: Equatable {
        case app
        case system
      }
    }
  }

  enum Action {
    case task
    case speechAuthorizationResponse(SFSpeechRecognizerAuthorizationStatus)
    case serviceResponse(Result<InterviewStep, any Error>)
    case questionSpoken
    case sttPartial(String)
    case sttFailed
    case silenceTimerFired
    case doneButtonTapped
    case answerCommitted(String)
    case closingSpoken
    case saveFailed(InterviewRecord)
    case retryButtonTapped
    case appSettingsButtonTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate {
      case interviewFinished(InterviewRecord)
      case openSettings
    }
  }

  @Dependency(\.conversationService) var conversationService
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
    case service
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        guard state.phase == .idle else { return .none }
        state.startedAt = self.now
        state.phase = .authorizing
        return .run { send in
          let status = await self.speechClient.requestAuthorization()
          await send(.speechAuthorizationResponse(status))
        }

      case .speechAuthorizationResponse(.authorized):
        guard state.phase == .authorizing else { return .none }
        state.phase = .processing
        return self.requestStep(state)

      case .speechAuthorizationResponse:
        guard state.phase == .authorizing else { return .none }
        state.phase = .failed
        state.failure = State.FailureState(
          message: "Speech recognition permission is required for the voice interview.",
          isRetryable: false,
          settingsDestination: .system
        )
        return .merge(
          .cancel(id: CancelID.service),
          .cancel(id: CancelID.tts),
          .cancel(id: CancelID.stt),
          .cancel(id: CancelID.silence)
        )

      case .serviceResponse(.success(let step)):
        guard state.phase == .processing else { return .none }
        switch step {
        case .completed(let extraction, let audit):
          if let audit { state.serviceAuditTrail.append(audit) }
          state.extraction = extraction
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

        case .question(let question, let audit):
          if let audit { state.serviceAuditTrail.append(audit) }
          guard !question.isEmpty else {
            state.phase = .failed
            state.failure = State.FailureState(
              message: ConversationServiceError.invalidResponse.userMessage,
              isRetryable: false
            )
            return .none
          }
          state.currentQuestion = question
          state.phase = .speaking
          return .run { send in
            do {
              try await self.tts.speak(question)
            } catch is CancellationError {
              return
            } catch {}
            await send(.questionSpoken)
          }
          .cancellable(id: CancelID.tts, cancelInFlight: true)
        }

      case .serviceResponse(.failure(let error)):
        guard state.phase == .processing else { return .none }
        let serviceError = error as? ConversationServiceError ?? .unknown
        state.phase = .failed
        state.failure = State.FailureState(
          message: serviceError.userMessage,
          isRetryable: serviceError.isRetryable || serviceError == .unknown,
          settingsDestination: {
            switch serviceError {
            case .credentialsMissing, .credentialsRejected: return .app
            default: return nil
            }
          }()
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
        state.phase = .committing
        return .merge(
          .cancel(id: CancelID.silence),
          .cancel(id: CancelID.stt),
          .run { [answer = state.partialAnswer] send in
            await self.speechClient.finishTask()
            await send(.answerCommitted(answer))
          }
        )

      case .answerCommitted(let answer):
        guard state.phase == .committing else { return .none }
        state.turns.append(
          InterviewTurn(
            index: state.turns.count,
            question: state.currentQuestion,
            answerTranscript: answer,
            audioFileName: "answer-\(state.turns.count).caf",
            askedAt: self.now
          )
        )
        state.partialAnswer = ""
        state.phase = .processing
        return self.requestStep(state)

      case .closingSpoken:
        guard state.phase == .finishing else { return .none }
        let record = InterviewRecord(
          id: state.interviewID,
          sessionID: state.sessionID,
          startedAt: state.startedAt ?? self.now,
          endedAt: self.now,
          summaryUsed: state.summary,
          turns: state.turns,
          extraction: state.extraction,
          model: state.serviceAuditTrail.last?.modelVersion ?? "service-managed",
          serviceAuditTrail: state.serviceAuditTrail
        )
        state.phase = .finished
        return .run { send in
          try self.artifacts.save(record)
          await send(.delegate(.interviewFinished(record)))
        } catch: { _, send in
          await send(.saveFailed(record))
        }

      case .saveFailed(let record):
        guard
          state.phase == .finished
            || (state.phase == .failed && state.pendingRecord?.id == record.id)
        else { return .none }
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
        return self.requestStep(state)

      case .appSettingsButtonTapped:
        guard state.failure?.settingsDestination == .app else { return .none }
        return .send(.delegate(.openSettings))

      case .delegate:
        return .none
      }
    }
  }

  private func requestStep(_ state: State) -> Effect<Action> {
    let exchanges = state.turns.map {
      InterviewExchange(question: $0.question, answer: $0.answerTranscript)
    }
    return .run {
      [
        interviewID = state.interviewID,
        sessionID = state.sessionID,
        summary = state.summary,
        exchanges,
      ] send in
      await send(
        .serviceResponse(
          Result {
            try await self.conversationService.nextInterviewStep(
              InterviewContext(
                interviewID: interviewID,
                sessionID: sessionID,
                summary: summary,
                exchanges: exchanges
              )
            )
          }
        )
      )
    }
    .cancellable(id: CancelID.service, cancelInFlight: true)
  }
}

struct InterviewView: View {
  let store: StoreOf<Interview>

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      switch store.phase {
      case .idle, .authorizing, .processing, .committing:
        ProgressView()
        Text(store.phase == .authorizing ? "Requesting speech access…" : "Thinking…")
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
        switch store.failure?.settingsDestination {
        case .app:
          Button("Open Settings") {
            store.send(.appSettingsButtonTapped)
          }
          .buttonStyle(.bordered)
        case .system:
          Link(
            "Open System Settings",
            destination: URL(string: UIApplication.openSettingsURLString)!
          )
          .buttonStyle(.bordered)
        case nil:
          EmptyView()
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
