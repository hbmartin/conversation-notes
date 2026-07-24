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
    case recorderDidFinish(Result<Bool, any Error>)
    case powerStatusResponse(PowerStatus)
    case sceneBecameActive
    case retryTranscriptionTapped
    case transcriptionResponse(Result<Transcript, any Error>)
    case transcriptSecured
    case securingFailed(String)
    case retrySummarizationTapped
    case openSettingsTapped
    case startInterviewTapped
    case doneTapped
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)

    @CasePathable
    enum Delegate {
      case transcriptReady(Session.ID)
      case retrySummarization(Session.ID)
      case openSettings
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
            try? await self.transcriptionClient.prepare()
          },
          .run { [id = state.session.id] send in
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

      case .recorderDidFinish(.success(true)):
        guard !state.isDiscarding else { return .none }
        guard state.phase == .stopping else { return .none }
        return .run { send in
          await send(.powerStatusResponse(self.powerState.powerStatus()))
        }

      case .recorderDidFinish(.success(false)), .recorderDidFinish(.failure):
        guard !state.isDiscarding else { return .none }
        switch state.phase {
        case .recording, .stopping:
          break
        default:
          return .none
        }
        return self.markLost(&state)

      case .powerStatusResponse(let status):
        switch state.phase {
        case .stopping, .waitingForPower:
          break
        case .failed where state.session.state == .stopped:
          break
        default:
          return .none
        }
        guard status.allowsTranscription else {
          state.phase = .waitingForPower(status)
          return .none
        }
        state.phase = .transcribing
        state.$session.withLock { $0.state = .transcribing }
        return self.transcribe(state.session.id)

      case .sceneBecameActive, .retryTranscriptionTapped:
        switch state.phase {
        case .waitingForPower:
          return .run { send in
            await send(.powerStatusResponse(self.powerState.powerStatus()))
          }
        case .failed where state.session.state == .stopped:
          return .run { send in
            await send(.powerStatusResponse(self.powerState.powerStatus()))
          }
        default:
          return .none
        }

      case .transcriptionResponse(.success(let transcript)):
        guard state.phase == .transcribing else { return .none }
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
        guard state.phase == .transcribing else { return .none }
        // Audio is intentionally NOT destroyed: transcription can be retried.
        state.phase = .failed("Transcription failed: \(error.localizedDescription)")
        state.$session.withLock { $0.state = .stopped }
        return .none

      case .transcriptSecured:
        guard state.phase == .securingTranscript else { return .none }
        state.phase = .pipeline
        state.$session.withLock { $0.state = .awaitingSummarization }
        return .send(.delegate(.transcriptReady(state.session.id)))

      case .securingFailed(let message):
        guard state.phase == .securingTranscript else { return .none }
        // The audio still exists (it is only destroyed after a successful vault write), so a
        // retry re-runs the power gate and transcription.
        state.phase = .failed("Could not secure the transcript: \(message)")
        state.$session.withLock { $0.state = .stopped }
        return .none

      case .retrySummarizationTapped:
        guard state.session.state == .awaitingSummarization else { return .none }
        return .send(.delegate(.retrySummarization(state.session.id)))

      case .openSettingsTapped:
        return .send(.delegate(.openSettings))

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
      AuroraScreen {
        GeometryReader { geometry in
          ScrollView {
            VStack(spacing: 24) {
              Spacer(minLength: 28)
              content
              Spacer(minLength: 28)
            }
            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
          }
          .scrollBounceBehavior(.basedOnSize)
          .scrollIndicators(.hidden)
        }
        .frame(maxWidth: 680)
      }
      .navigationTitle("Conversation")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.hidden, for: .navigationBar)
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
      ZStack {
        Circle()
          .fill((paused ? Color.secondary : AppTheme.recording).opacity(0.14))
        Circle()
          .stroke((paused ? Color.secondary : AppTheme.recording).opacity(0.26), lineWidth: 14)
          .padding(10)
        Image(systemName: paused ? "pause.fill" : "waveform")
          .font(.system(size: 48, weight: .semibold))
          .foregroundStyle(paused ? .secondary : AppTheme.recording)
          .symbolEffect(.pulse, isActive: !paused)
      }
      .frame(width: 150, height: 150)
      .accessibilityHidden(true)

      Text(Duration.seconds(store.elapsed).formatted(.time(pattern: .minuteSecond)))
        .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
        .contentTransition(.numericText())
        .minimumScaleFactor(0.7)
      Text(paused ? "Paused" : "Recording conversation")
        .font(.headline)
        .foregroundStyle(paused ? .secondary : AppTheme.recording)
      Text(
        "Keep this screen open or lock your device. The conversation continues recording in the background."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 440)

      GlassEffectContainer(spacing: 14) {
        HStack(spacing: 14) {
          Button {
            store.send(paused ? .resumeTapped : .pauseTapped)
          } label: {
            Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.glass)
          .controlSize(.large)

          Button {
            store.send(.stopTapped)
          } label: {
            Label("Stop", systemImage: "stop.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.glassProminent)
          .tint(AppTheme.recording)
          .controlSize(.large)
        }
      }
      .frame(maxWidth: 480)
      .padding(.top, 14)

    case .stopping:
      statusPanel(
        icon: "stop.circle.fill",
        color: AppTheme.recording,
        title: "Finishing recording",
        message: "Securing the audio before on-device transcription begins.",
        showsProgress: true
      )

    case .waitingForPower(let status):
      statusPanel(
        icon: "battery.25percent",
        color: .orange,
        title: "Plug in to transcribe",
        message:
          "Transcription is a heavy on-device task. Connect power or charge above 30% (currently \(Int(status.batteryLevel * 100))%). Your recording is kept safely on this device."
      )
      Button("Try Again") {
        store.send(.retryTranscriptionTapped)
      }
      .buttonStyle(.glassProminent)
      .controlSize(.large)

    case .transcribing:
      statusPanel(
        icon: "waveform.and.magnifyingglass",
        color: AppTheme.conversation,
        title: "Transcribing on this device",
        message: "The recording will be deleted as soon as transcription completes.",
        showsProgress: true
      )

    case .securingTranscript:
      statusPanel(
        icon: "lock.shield.fill",
        color: AppTheme.conversation,
        title: "Securing transcript",
        message: "Deleting the source audio and preparing a compliance-safe summary.",
        showsProgress: true
      )

    case .pipeline:
      pipelineContent

    case .failed(let message):
      statusPanel(
        icon: "exclamationmark.triangle.fill",
        color: .orange,
        title: "This capture needs attention",
        message: message
      )
      if store.session.state == .stopped {
        Button("Retry") {
          store.send(.retryTranscriptionTapped)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
      }
    }
  }

  private func statusPanel(
    icon: String,
    color: Color,
    title: String,
    message: String,
    showsProgress: Bool = false
  ) -> some View {
    VStack(spacing: 18) {
      Image(systemName: icon)
        .font(.system(size: 50, weight: .semibold))
        .foregroundStyle(color)
      Text(title)
        .font(.title2.bold())
        .multilineTextAlignment(.center)
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      if showsProgress {
        ProgressView()
          .controlSize(.large)
          .tint(color)
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: 520)
    .padding(28)
    .auroraPanel(cornerRadius: 28)
  }

  @ViewBuilder
  private var pipelineContent: some View {
    switch store.session.state {
    case .awaitingSummarization:
      VStack(spacing: 16) {
        Image(systemName: "sparkles")
          .font(.system(size: 46, weight: .semibold))
          .foregroundStyle(AppTheme.interview)
        if store.session.summarizationFailure == nil {
          ProgressView()
            .controlSize(.large)
        }
        Text(
          store.session.summarizationFailure == nil
            ? "Creating your summary" : "Summary needs attention"
        )
        .font(.title2.bold())
        SummarizationStatusView(
          failure: store.session.summarizationFailure,
          retry: { store.send(.retrySummarizationTapped) },
          openSettings: { store.send(.openSettingsTapped) }
        )
      }
      .frame(maxWidth: 540)
      .padding(28)
      .auroraPanel(cornerRadius: 28)

    case .summaryReady:
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Label("Conversation summary", systemImage: "sparkles")
            .font(.title3.bold())
            .foregroundStyle(AppTheme.conversation)
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
        .padding(24)
        .auroraPanel()
      }
      Button("Start Interview") {
        store.send(.startInterviewTapped)
      }
      .buttonStyle(.glassProminent)
      .tint(AppTheme.interview)
      .controlSize(.large)
      Button("Finish Later") {
        store.send(.doneTapped)
      }
      .buttonStyle(.glass)
      .controlSize(.large)

    default:
      ProgressView()
    }
  }
}
