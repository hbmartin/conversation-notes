import ComposableArchitecture
import Speech
import SwiftUI
import UIKit

/// The guided voice interview: a Claude agent asks one question at a time (spoken by
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
    let summary: String?
    var phase: Phase = .idle
    var currentQuestion = ""
    var partialAnswer = ""
    var turns: [InterviewTurn] = []
    var serviceAuditTrail: [ServiceAuditMetadata] = []
    var extraction: InterviewExtraction?
    var pendingRecord: InterviewRecord?
    var failure: FailureState?
    var startedAt: Date?
    @Presents var alert: AlertState<Action.Alert>?

    var isStandalone: Bool { self.summary == nil }

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
    case discardButtonTapped
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)

    @CasePathable
    enum Delegate {
      case interviewFinished(InterviewRecord)
      case discarded(sessionID: Session.ID, interviewID: UUID)
      case openSettings
    }

    enum Alert: Equatable {
      case confirmDiscard
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

      case .discardButtonTapped:
        let isStandalone = state.isStandalone
        state.alert = AlertState {
          TextState(isStandalone ? "Discard this interview?" : "Cancel this interview?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmDiscard) {
            TextState(isStandalone ? "Discard" : "Cancel Interview")
          }
          ButtonState(role: .cancel) { TextState("Keep Interviewing") }
        } message: {
          TextState(
            isStandalone
              ? "Recorded answers from this unfinished interview will be permanently deleted."
              : "Partial answers will be deleted. You can restart from the conversation summary."
          )
        }
        return .none

      case .alert(.presented(.confirmDiscard)):
        return .merge(
          .cancel(id: CancelID.service),
          .cancel(id: CancelID.tts),
          .cancel(id: CancelID.stt),
          .cancel(id: CancelID.silence),
          .run { [sessionID = state.sessionID, interviewID = state.interviewID] send in
            await self.speechClient.finishTask()
            await send(.delegate(.discarded(sessionID: sessionID, interviewID: interviewID)))
          }
        )

      case .alert:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
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
  @Bindable var store: StoreOf<Interview>
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    AuroraScreen {
      GeometryReader { geometry in
        ScrollView {
          VStack(spacing: 22) {
            Spacer(minLength: 22)
            phaseContent
            Spacer(minLength: 22)
            if store.phase != .finished {
              Label(
                "Question \(store.turns.count + 1)",
                systemImage: "point.3.connected.trianglepath.dotted"
              )
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 14)
              .padding(.vertical, 8)
              .background(.thinMaterial, in: .capsule)
            }
          }
          .frame(maxWidth: .infinity, minHeight: geometry.size.height)
          .padding(.horizontal, 24)
          .padding(.bottom, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
      }
      .frame(maxWidth: 680)
    }
    .navigationTitle(store.isStandalone ? "Guided Interview" : "Conversation Interview")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(
      store.isStandalone || (store.phase != .finished && store.phase != .failed)
    )
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbar {
      if store.phase != .finished {
        ToolbarItem(placement: .cancellationAction) {
          Button(store.isStandalone ? "Discard" : "Cancel", role: .destructive) {
            store.send(.discardButtonTapped)
          }
        }
      }
    }
    .alert($store.scope(\.alert, action: \.alert))
    .task {
      await store.send(.task).finish()
    }
  }

  @ViewBuilder
  private var phaseContent: some View {
    switch store.phase {
    case .idle, .authorizing, .processing, .committing:
      VStack(spacing: 18) {
        Image(systemName: store.phase == .authorizing ? "waveform.badge.mic" : "sparkles")
          .font(.system(size: 48, weight: .semibold))
          .foregroundStyle(AppTheme.interview)
          .symbolEffect(.pulse, isActive: !self.reduceMotion)
        ProgressView()
          .controlSize(.large)
          .tint(AppTheme.interview)
        Text(
          store.phase == .authorizing ? "Preparing speech access" : "Preparing the next question"
        )
        .font(.title2.bold())
        Text(
          store.phase == .authorizing
            ? "The interview listens only while you answer."
            : "Your guided debrief is adapting to what you have shared."
        )
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      }
      .frame(maxWidth: 520)
      .padding(30)
      .auroraPanel(cornerRadius: 28)

    case .speaking, .listening, .finishing:
      VStack(spacing: 22) {
        ZStack {
          Circle()
            .fill(AppTheme.interview.opacity(0.14))
          Circle()
            .stroke(AppTheme.interview.opacity(0.25), lineWidth: 12)
            .padding(9)
          Image(
            systemName: store.phase == .listening
              ? "waveform" : "speaker.wave.2.fill"
          )
          .font(.system(size: 44, weight: .semibold))
          .foregroundStyle(AppTheme.interview)
          .symbolEffect(.pulse, isActive: !self.reduceMotion)
        }
        .frame(width: 128, height: 128)
        .accessibilityHidden(true)

        Text(store.phase == .listening ? "Listening" : "Guided prompt")
          .font(.subheadline.bold())
          .foregroundStyle(AppTheme.interview)
          .textCase(.uppercase)

        Text(store.currentQuestion)
          .font(.system(.title, design: .rounded, weight: .bold))
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)

        if store.phase == .listening {
          Text(
            store.partialAnswer.isEmpty ? "Start speaking when you’re ready…" : store.partialAnswer
          )
          .font(.body)
          .foregroundStyle(store.partialAnswer.isEmpty ? .secondary : .primary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, minHeight: 74)
          .padding(20)
          .auroraPanel(cornerRadius: 22)
          .accessibilityLabel("Current answer")

          Button {
            store.send(.doneButtonTapped)
          } label: {
            Label("Finish Answer", systemImage: "checkmark")
              .frame(minWidth: 160)
          }
          .buttonStyle(.glassProminent)
          .tint(AppTheme.interview)
          .controlSize(.large)
          .disabled(store.partialAnswer.isEmpty)
        }
      }

    case .finished:
      VStack(spacing: 18) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 64))
          .foregroundStyle(.green)
        Text("Interview recorded")
          .font(.title.bold())
        Text("Your structured debrief and recorded answers are saved on this device.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: 520)
      .padding(30)
      .auroraPanel(cornerRadius: 28)

    case .failed:
      VStack(spacing: 18) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 52))
          .foregroundStyle(.orange)
        Text("Interview paused")
          .font(.title2.bold())
        Text(store.failure?.message ?? "Something went wrong.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        if store.failure?.isRetryable == true {
          Button("Retry") {
            store.send(.retryButtonTapped)
          }
          .buttonStyle(.glassProminent)
          .tint(AppTheme.interview)
          .controlSize(.large)
        }
        switch store.failure?.settingsDestination {
        case .app:
          Button("Open Settings") {
            store.send(.appSettingsButtonTapped)
          }
          .buttonStyle(.glass)
          .controlSize(.large)
        case .system:
          Link(
            "Open System Settings",
            destination: URL(string: UIApplication.openSettingsURLString)!
          )
          .buttonStyle(.glass)
          .controlSize(.large)
        case nil:
          EmptyView()
        }
      }
      .frame(maxWidth: 520)
      .padding(30)
      .auroraPanel(cornerRadius: 28)
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
