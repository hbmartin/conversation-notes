import ComposableArchitecture
import SwiftUI

/// The full-screen capture flow for one session:
/// record → stop → (power gate) → transcribe on-device → secure transcript in the encrypted
/// vault → destroy audio → hand off to the root summarization queue.
///
/// `phase` is transient UI; the durable machine is `session.state` (shared, persisted), and the
/// reducer keeps them in lockstep at each transition.
@Reducer
struct ActiveSession {
  @ObservableState
  struct State: Equatable {
    @Shared var session: Session
    var phase: Phase = .recording(paused: false)
    var elapsed: TimeInterval = 0
    var isDiscarding = false
    @Presents var alert: AlertState<Action.Alert>?

    enum Phase: Equatable {
      case recording(paused: Bool)
      case stopping
      case waitingForPower(PowerStatus)
      case transcribing
      case securingTranscript
      /// From here on the UI renders off `session.state`
      /// (`awaitingSummarization` → `summaryReady`), which the root queue advances.
      case pipeline
      case failed(String)
    }

    var isRecordingPhase: Bool {
      if case .recording = phase { return true } else { return false }
    }
  }

  enum Action {
    case onTask
    case timerTicked
    case finalDuration(TimeInterval)
    case pauseTapped
    case resumeTapped
    case stopTapped
    case discardTapped
    case permissionDenied
    case recorderDidFinish(Result<Bool, any Error>)
    case powerStatusResponse(PowerStatus)
    case sceneBecameActive
    case retryTranscriptionTapped
    case transcriptionResponse(Result<Transcript, any Error>)
    case transcriptSecured
    case securingFailed(String)
    case retrySummarizationTapped
    case startInterviewTapped
    case doneTapped
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)

    @CasePathable
    enum Delegate {
      case transcriptReady(Session.ID)
      case retrySummarization
      case discarded(Session.ID)
      case readyForInterview(Session.ID)
      case closed
    }

    enum Alert: Equatable {
      case confirmDiscard
      case acknowledgeLost
    }
  }

  @Dependency(\.audioRecorder) var audioRecorder
  @Dependency(\.audioStorage) var audioStorage
  @Dependency(\.transcriptionClient) var transcriptionClient
  @Dependency(\.transcriptVault) var transcriptVault
  @Dependency(\.powerState) var powerState
  @Dependency(\.continuousClock) var clock

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onTask:
        return .merge(
          // Warm up the on-device transcription model while recording so it's ready by Stop.
          .run { _ in
            try? await self.transcriptionClient.prepare(Locale(identifier: "en-US"))
          },
          .run { [id = state.session.id] send in
            guard await self.audioRecorder.requestRecordPermission() else {
              await send(.permissionDenied)
              return
            }
            await withTaskGroup(of: Void.self) { group in
              group.addTask {
                do {
                  let result = try await self.audioRecorder.startRecording(
                    url: self.audioStorage.recordingURL(id)
                  )
                  await send(.recorderDidFinish(.success(result)))
                } catch {
                  await send(.recorderDidFinish(.failure(error)))
                }
              }
              group.addTask {
                for await _ in self.clock.timer(interval: .seconds(1)) {
                  await send(.timerTicked)
                }
              }
              _ = await group.next()
              group.cancelAll()
            }
          }
        )

      case .timerTicked:
        if case .recording(paused: false) = state.phase {
          state.elapsed += 1
        }
        return .none

      case .finalDuration(let duration):
        state.elapsed = duration
        state.$session.withLock { $0.duration = duration }
        return .none

      case .pauseTapped:
        state.phase = .recording(paused: true)
        return .run { _ in await self.audioRecorder.pauseRecording() }

      case .resumeTapped:
        state.phase = .recording(paused: false)
        return .run { _ in await self.audioRecorder.resumeRecording() }

      case .stopTapped:
        guard state.isRecordingPhase else { return .none }
        state.phase = .stopping
        state.$session.withLock { $0.state = .stopped }
        return .run { send in
          if let duration = await self.audioRecorder.currentTime() {
            await send(.finalDuration(duration))
          }
          await self.audioRecorder.stopRecording()
        }

      case .permissionDenied:
        state.alert = AlertState {
          TextState("Microphone access denied")
        } actions: {
          ButtonState(action: .acknowledgeLost) { TextState("OK") }
        } message: {
          TextState("Enable microphone access in Settings to record a session.")
        }
        return .none

      case .recorderDidFinish(.success(true)):
        guard !state.isDiscarding else { return .none }
        guard state.phase == .stopping else { return .none }
        return .run { send in
          await send(.powerStatusResponse(self.powerState.powerStatus()))
        }

      case .recorderDidFinish(.success(false)), .recorderDidFinish(.failure):
        guard !state.isDiscarding else { return .none }
        return self.markLost(&state)

      case .powerStatusResponse(let status):
        guard status.allowsTranscription else {
          state.phase = .waitingForPower(status)
          return .none
        }
        state.phase = .transcribing
        state.$session.withLock { $0.state = .transcribing }
        return self.transcribe(state.session.id)

      case .sceneBecameActive, .retryTranscriptionTapped:
        switch state.phase {
        case .waitingForPower, .failed:
          return .run { send in
            await send(.powerStatusResponse(self.powerState.powerStatus()))
          }
        default:
          return .none
        }

      case .transcriptionResponse(.success(let transcript)):
        state.phase = .securingTranscript
        return .run { [id = state.session.id] send in
          do {
            // Order is the privacy invariant: the transcript must be durably in the encrypted
            // vault before the audio is destroyed.
            try await self.transcriptVault.store(id, transcript.fullText)
            try await self.audioStorage.destroyRecording(id)
            await send(.transcriptSecured)
          } catch {
            await send(.securingFailed("\(error.localizedDescription)"))
          }
        }

      case .transcriptionResponse(.failure(let error)):
        // Audio is intentionally NOT destroyed: transcription can be retried.
        state.phase = .failed("Transcription failed: \(error.localizedDescription)")
        state.$session.withLock { $0.state = .stopped }
        return .none

      case .transcriptSecured:
        state.phase = .pipeline
        state.$session.withLock { $0.state = .awaitingSummarization }
        return .send(.delegate(.transcriptReady(state.session.id)))

      case .securingFailed(let message):
        // The audio still exists (it is only destroyed after a successful vault write), so a
        // retry re-runs the power gate and transcription.
        state.phase = .failed("Could not secure the transcript: \(message)")
        state.$session.withLock { $0.state = .stopped }
        return .none

      case .retrySummarizationTapped:
        return .send(.delegate(.retrySummarization))

      case .discardTapped:
        state.alert = AlertState {
          TextState("Discard this session?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmDiscard) { TextState("Discard") }
          ButtonState(role: .cancel) { TextState("Keep") }
        } message: {
          TextState("The recording, transcript, and summary will be permanently deleted.")
        }
        return .none

      case .alert(.presented(.confirmDiscard)):
        state.isDiscarding = true
        return .run { [id = state.session.id] send in
          await self.audioRecorder.stopRecording()
          try? await self.audioStorage.destroyRecording(id)
          try? await self.transcriptVault.destroy(id)
          await send(.delegate(.discarded(id)))
        }

      case .alert(.presented(.acknowledgeLost)):
        return .send(.delegate(.closed))

      case .alert:
        return .none

      case .startInterviewTapped:
        return .send(.delegate(.readyForInterview(state.session.id)))

      case .doneTapped:
        return .send(.delegate(.closed))

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }

  private func transcribe(_ id: Session.ID) -> Effect<Action> {
    .run { send in
      await send(
        .transcriptionResponse(
          Result {
            try await self.transcriptionClient.transcribe(self.audioStorage.recordingURL(id))
          }
        )
      )
    }
  }

  private func markLost(_ state: inout State) -> Effect<Action> {
    state.phase = .failed("Recording interrupted")
    state.$session.withLock {
      $0.state = .lost
      $0.lossReason =
        "The recording was interrupted (for example by a phone call) and could not be recovered."
    }
    state.alert = AlertState {
      TextState("Recording interrupted")
    } actions: {
      ButtonState(action: .acknowledgeLost) { TextState("OK") }
    } message: {
      TextState(
        "Something interrupted the microphone, so this session was lost. Interrupted sessions cannot be resumed in this version."
      )
    }
    return .run { [id = state.session.id] _ in
      try? await self.audioStorage.destroyRecording(id)
      try? await self.transcriptVault.destroy(id)
    }
  }
}

struct ActiveSessionView: View {
  @Bindable var store: StoreOf<ActiveSession>
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Spacer()
        content
        Spacer()
      }
      .padding()
      .navigationTitle("Session")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Discard", role: .destructive) {
            store.send(.discardTapped)
          }
        }
      }
    }
    .alert($store.scope(\.alert, action: \.alert))
    .task {
      await store.send(.onTask).finish()
    }
    .onChange(of: scenePhase) { _, newValue in
      if newValue == .active {
        store.send(.sceneBecameActive)
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch store.phase {
    case .recording(let paused):
      Image(systemName: "record.circle")
        .font(.system(size: 56))
        .foregroundStyle(paused ? .secondary : Color.red)
        .symbolEffect(.pulse, isActive: !paused)
      Text(Duration.seconds(store.elapsed).formatted(.time(pattern: .minuteSecond)))
        .font(.largeTitle.monospacedDigit())
      Text(paused ? "Paused" : "Recording")
        .foregroundStyle(.secondary)
      HStack(spacing: 16) {
        Button(paused ? "Resume" : "Pause") {
          store.send(paused ? .resumeTapped : .pauseTapped)
        }
        .buttonStyle(.bordered)
        Button("Stop") {
          store.send(.stopTapped)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
      }

    case .stopping:
      ProgressView()
      Text("Stopping…").foregroundStyle(.secondary)

    case .waitingForPower(let status):
      Image(systemName: "battery.25percent")
        .font(.system(size: 56))
        .foregroundStyle(.orange)
      Text("Plug in to transcribe")
        .font(.title2)
      Text(
        """
        Transcription is a heavy on-device task. Connect power or charge above \
        30% (currently \(Int(status.batteryLevel * 100))%). Your recording is kept safely on \
        this device.
        """
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      Button("Try Again") {
        store.send(.retryTranscriptionTapped)
      }
      .buttonStyle(.borderedProminent)

    case .transcribing:
      ProgressView()
      Text("Transcribing on this device…")
        .foregroundStyle(.secondary)
      Text("The recording will be deleted as soon as transcription completes.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

    case .securingTranscript:
      ProgressView()
      Text("Securing transcript and deleting audio…")
        .foregroundStyle(.secondary)

    case .pipeline:
      pipelineContent

    case .failed(let message):
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 56))
        .foregroundStyle(.orange)
      Text(message)
        .multilineTextAlignment(.center)
      if store.session.state == .stopped {
        Button("Retry") {
          store.send(.retryTranscriptionTapped)
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  @ViewBuilder
  private var pipelineContent: some View {
    switch store.session.state {
    case .awaitingSummarization:
      ProgressView()
      Text("Summarizing…")
        .font(.title3)
      Text(
        "The encrypted transcript is queued and will be summarized when a connection is available. It is deleted as soon as the summary is saved."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      Button("Retry Now") {
        store.send(.retrySummarizationTapped)
      }
      .buttonStyle(.bordered)

    case .summaryReady:
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Summary")
            .font(.headline)
          Text(store.session.summary ?? "")
          if let consent = store.session.consentUtterance {
            Text("Consent")
              .font(.headline)
            Text("“\(consent)”")
              .italic()
          } else {
            Label(
              "No consent statement was found in the conversation.",
              systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            .font(.callout)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Button("Start Interview") {
        store.send(.startInterviewTapped)
      }
      .buttonStyle(.borderedProminent)
      Button("Finish Later") {
        store.send(.doneTapped)
      }
      .buttonStyle(.bordered)

    default:
      ProgressView()
    }
  }
}
