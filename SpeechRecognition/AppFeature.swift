import ComposableArchitecture
import SwiftUI
import UIKit

/// The root of the app: the session list, navigation, and — crucially — the long-lived
/// summarization queue and launch-time crash recovery. The queue lives here (not in the capture
/// flow) so retries continue after the capture UI is dismissed.
@Reducer
struct AppFeature {
  @Reducer
  enum Path {
    case detail(SessionDetail)
    case interview(Interview)
    case settings(Settings)
  }

  @ObservableState
  struct State: Equatable {
    @Shared(.sessions) var sessions
    var path = StackState<Path.State>()
    @Presents var activeSession: ActiveSession.State?
    @Presents var alert: AlertState<Action.Alert>?
    var isConnected = false
    var isRequestingMicrophonePermission = false
    /// Only concurrency is transient; retry eligibility and timing live on each persisted session.
    var summarizationInFlightID: Session.ID?
    /// Build-time gate; resolved once at launch so the home screen renders correctly on first pass.
    var isConversationCaptureEnabled: Bool

    init() {
      @Dependency(\.featureFlags) var featureFlags
      self.isConversationCaptureEnabled = featureFlags.isConversationCaptureEnabled()
    }

    /// A new capture cannot begin while another microphone workflow — a pending permission
    /// prompt, an active recording, or an interview — is underway.
    var canStartCapture: Bool {
      !self.isRequestingMicrophonePermission
        && self.activeSession == nil
        && !self.path.contains { pathState in
          if case .interview = pathState { return true }
          return false
        }
    }
  }

  enum Action {
    case onLaunch
    case newConversationButtonTapped
    case newInterviewButtonTapped
    case recordPermissionResponse(Bool)
    case interviewPermissionResponse(Bool)
    case settingsButtonTapped
    case sessionTapped(Session.ID)
    case connectivityChanged(Bool)
    case drainQueue
    case retryTimerFired(Session.ID, Date)
    case summarizationResponse(Session.ID, Result<SummaryResponse, any Error>)
    case transcriptDestroyed(Session.ID)
    case path(StackActionOf<Path>)
    case activeSession(PresentationAction<ActiveSession.Action>)
    case alert(PresentationAction<Alert>)

    enum Alert: Equatable {
      case openSystemSettings
    }
  }

  @Dependency(\.audioRecorder) var audioRecorder
  @Dependency(\.audioStorage) var audioStorage
  @Dependency(\.transcriptVault) var transcriptVault
  @Dependency(\.connectivity) var connectivity
  @Dependency(\.conversationService) var conversationService
  @Dependency(\.interviewArtifacts) var interviewArtifacts
  @Dependency(\.continuousClock) var clock
  @Dependency(\.openURL) var openURL
  @Dependency(\.uuid) var uuid
  @Dependency(\.date.now) var now

  private enum CancelID {
    case connectivity
    case drain
    case retry
  }

  private enum SummarizationPipelineError: Error {
    case transcriptUnavailable
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onLaunch:
        // Crash recovery, before anything else. At launch no recording can legitimately be in
        // progress, so any staged audio is orphaned by definition and any session that was
        // mid-capture is unrecoverable (privacy-safe: purge, inform).
        let lostIDs = state.sessions
          .filter { [.recording, .stopped, .transcribing].contains($0.state) }
          .map(\.id)
        state.$sessions.withLock { sessions in
          for id in lostIDs {
            sessions[id: id]?.state = .lost
            sessions[id: id]?.lossReason =
              "The app closed before transcription completed, so this recording could not be recovered."
          }
          for id in sessions.ids where sessions[id: id]?.state == .interviewing {
            if sessions[id: id]?.kind == .interview {
              sessions[id: id]?.state = .lost
              sessions[id: id]?.lossReason =
                "The app closed before this interview finished, so its partial answers were removed."
            } else {
              // A linked interview can be redone because its conversation summary is intact.
              sessions[id: id]?.state = .summaryReady
            }
            sessions[id: id]?.interviewID = nil
          }
        }
        let validIDs = Set(state.sessions.ids)
        let summarizedIDs = Set(
          state.sessions
            .filter {
              [.summaryReady, .interviewing, .saved, .permissionDenied, .lost].contains($0.state)
            }
            .map(\.id)
        )
        // Interrupted interviews had their `interviewID` cleared above, so the artifact sweep
        // purges their partial answers along with any directory a crash mid-cleanup leaked.
        // The orphan set is fixed here, synchronously with that state fixup: an interview
        // started while the cleanup effect below is still running gets a fresh ID that cannot
        // be in this snapshot, so the sweep can never destroy a live interview's artifacts.
        let retainedInterviewIDs = Set(state.sessions.compactMap(\.interviewID))
        let orphanedInterviewArtifactIDs = self.interviewArtifacts.storedIDs()
          .filter { !retainedInterviewIDs.contains($0) }
        return .merge(
          .run { send in
            try? await self.audioStorage.purgeAllRecordings()
            for id in lostIDs {
              try? await self.transcriptVault.destroy(id)
            }
            // Orphan sweep: vault files with no matching session.
            for id in await self.transcriptVault.pendingIDs() {
              if !validIDs.contains(id) || summarizedIDs.contains(id) {
                try? await self.transcriptVault.destroy(id)
              }
            }
            // Orphan sweep: interview artifact directories no session referenced at launch.
            for id in orphanedInterviewArtifactIDs {
              try? self.interviewArtifacts.destroy(id)
            }
            await send(.drainQueue)
          },
          .run { send in
            for await connected in self.connectivity.observe() {
              await send(.connectivityChanged(connected))
            }
          }
          .cancellable(id: CancelID.connectivity)
        )

      case .newConversationButtonTapped:
        guard state.isConversationCaptureEnabled, state.canStartCapture else { return .none }
        state.isRequestingMicrophonePermission = true
        return .run { send in
          let allowed = await self.audioRecorder.requestRecordPermission()
          await send(.recordPermissionResponse(allowed))
        }

      case .newInterviewButtonTapped:
        guard state.canStartCapture else { return .none }
        guard state.isConnected else {
          state.alert = self.offlineInterviewAlert
          return .none
        }
        state.isRequestingMicrophonePermission = true
        return .run { send in
          let allowed = await self.audioRecorder.requestRecordPermission()
          await send(.interviewPermissionResponse(allowed))
        }

      case .interviewPermissionResponse(true):
        guard state.isRequestingMicrophonePermission else { return .none }
        state.isRequestingMicrophonePermission = false
        // Connectivity was verified before the permission prompt, but the prompt can stay up
        // long enough for the connection to drop; re-check before creating the session.
        guard state.isConnected else {
          state.alert = self.offlineInterviewAlert
          return .none
        }
        let sessionID = self.uuid()
        let interviewID = self.uuid()
        let session = Session(
          id: sessionID,
          kind: .interview,
          startDate: self.now,
          state: .interviewing,
          interviewID: interviewID
        )
        state.$sessions.withLock { _ = $0.append(session) }
        state.path.append(
          .interview(
            Interview.State(
              interviewID: interviewID,
              sessionID: sessionID,
              summary: nil
            )
          )
        )
        return .none

      case .interviewPermissionResponse(false):
        guard state.isRequestingMicrophonePermission else { return .none }
        state.isRequestingMicrophonePermission = false
        let session = Session(
          id: self.uuid(),
          kind: .interview,
          startDate: self.now,
          state: .permissionDenied,
          lossReason: "Microphone access was denied before the interview began."
        )
        state.$sessions.withLock { _ = $0.append(session) }
        state.alert = self.microphoneDeniedAlert
        return .none

      case .recordPermissionResponse(true):
        guard state.isRequestingMicrophonePermission else { return .none }
        state.isRequestingMicrophonePermission = false
        let session = Session(id: self.uuid(), startDate: self.now, state: .recording)
        state.$sessions.withLock { _ = $0.append(session) }
        guard let sharedSession = Shared(state.$sessions[id: session.id]) else { return .none }
        state.activeSession = ActiveSession.State(session: sharedSession)
        return .none

      case .recordPermissionResponse(false):
        guard state.isRequestingMicrophonePermission else { return .none }
        state.isRequestingMicrophonePermission = false
        let session = Session(
          id: self.uuid(),
          startDate: self.now,
          state: .permissionDenied,
          lossReason: "Microphone access was denied before recording began."
        )
        state.$sessions.withLock { _ = $0.append(session) }
        state.alert = self.microphoneDeniedAlert
        return .none

      case .settingsButtonTapped:
        state.path.append(.settings(Settings.State()))
        return .none

      case .sessionTapped(let id):
        guard let sharedSession = Shared(state.$sessions[id: id]) else { return .none }
        state.path.append(.detail(SessionDetail.State(session: sharedSession)))
        return .none

      case .connectivityChanged(let connected):
        let wasConnected = state.isConnected
        state.isConnected = connected
        if connected, !wasConnected {
          return .merge(.cancel(id: CancelID.retry), .send(.drainQueue))
        }
        return connected ? .none : .cancel(id: CancelID.retry)

      case .drainQueue:
        return self.drainQueue(state: &state)

      case .retryTimerFired(let id, let scheduledAt):
        guard
          state.sessions[id: id]?.state == .awaitingSummarization,
          state.sessions[id: id]?.summarizationFailure?.requiredAction == .automaticRetry,
          state.sessions[id: id]?.summarizationFailure?.nextRetryAt == scheduledAt
        else { return .none }
        state.$sessions.withLock { sessions in
          sessions[id: id]?.summarizationFailure?.requiredAction = .retryNow
          sessions[id: id]?.summarizationFailure?.nextRetryAt = self.now
        }
        return .send(.drainQueue)

      case .summarizationResponse(let id, .success(let result)):
        guard state.summarizationInFlightID == id else { return .none }
        state.summarizationInFlightID = nil
        state.$sessions.withLock { sessions in
          sessions[id: id]?.summary = result.summary
          sessions[id: id]?.consentUtterance = result.consentUtterance
          sessions[id: id]?.state = .summaryReady
          sessions[id: id]?.summarizationFailure = nil
          sessions[id: id]?.summaryServiceAudit = result.audit
        }
        // Destroy the transcript only after the summary is durably in shared state.
        return .run { send in
          try? await self.transcriptVault.destroy(id)
          await send(.transcriptDestroyed(id))
        }

      case .summarizationResponse(let id, .failure(let error)):
        guard state.summarizationInFlightID == id else { return .none }
        state.summarizationInFlightID = nil
        let previousAttempts = state.sessions[id: id]?.summarizationFailure?.attemptCount ?? 0
        let failure = self.summarizationFailure(
          for: error,
          attemptCount: previousAttempts + 1
        )
        state.$sessions.withLock { sessions in
          sessions[id: id]?.summarizationFailure = failure
        }
        return .send(.drainQueue)

      case .transcriptDestroyed:
        // Continue with the next queued session, if any.
        return .send(.drainQueue)

      case .activeSession(.presented(.delegate(let delegateAction))):
        switch delegateAction {
        case .transcriptReady:
          return .send(.drainQueue)
        case .retrySummarization(let id):
          return self.retrySummarization(state: &state, id: id)
        case .openSettings:
          state.activeSession = nil
          state.path.append(.settings(Settings.State()))
          return .none
        case .discarded(let id):
          state.activeSession = nil
          state.$sessions.withLock { _ = $0.remove(id: id) }
          if state.summarizationInFlightID == id {
            state.summarizationInFlightID = nil
            return .merge(.cancel(id: CancelID.drain), .send(.drainQueue))
          }
          return .send(.drainQueue)
        case .readyForInterview(let id):
          state.activeSession = nil
          return self.startInterview(state: &state, sessionID: id)
        case .closed:
          state.activeSession = nil
          return .none
        }

      case .activeSession:
        return .none

      case .path(.element(_, action: .detail(.delegate(let delegateAction)))):
        switch delegateAction {
        case .startInterview(let id):
          return self.startInterview(state: &state, sessionID: id)
        case .retrySummarization(let id):
          return self.retrySummarization(state: &state, id: id)
        case .openSettings:
          state.path.append(.settings(Settings.State()))
          return .none
        case .delete(let id):
          let interviewID = state.sessions[id: id]?.interviewID
          state.path.removeAll()
          state.$sessions.withLock { _ = $0.remove(id: id) }
          let cleanup = Effect<Action>.run { _ in
            try? await self.audioStorage.destroyRecording(id)
            try? await self.transcriptVault.destroy(id)
            if let interviewID {
              try? self.interviewArtifacts.destroy(interviewID)
            }
          }
          if state.summarizationInFlightID == id {
            state.summarizationInFlightID = nil
            return .merge(
              .cancel(id: CancelID.drain),
              cleanup,
              .send(.drainQueue)
            )
          }
          return .merge(cleanup, .send(.drainQueue))
        }

      case .path(
        .element(let pathID, action: .interview(.delegate(.interviewFinished(let record))))):
        state.$sessions.withLock { sessions in
          sessions[id: record.sessionID]?.interviewID = record.id
          sessions[id: record.sessionID]?.state = .saved
        }
        state.path.pop(from: pathID)
        return .none

      case .path(.element(_, action: .interview(.delegate(.openSettings)))):
        state.path.append(.settings(Settings.State()))
        return .none

      case .path(
        .element(
          let pathID,
          action: .interview(.delegate(.discarded(let sessionID, let interviewID)))
        )
      ):
        state.path.pop(from: pathID)
        if state.sessions[id: sessionID]?.kind == .interview {
          state.$sessions.withLock { _ = $0.remove(id: sessionID) }
        } else {
          state.$sessions.withLock { sessions in
            sessions[id: sessionID]?.state = .summaryReady
            sessions[id: sessionID]?.interviewID = nil
          }
        }
        return .run { _ in
          try? self.interviewArtifacts.destroy(interviewID)
        }

      case .path(.popFrom(let pathID)):
        guard let index = state.path.ids.firstIndex(of: pathID) else { return .none }
        // Only in-progress interviews are abandoned; a finished interview in the popped range
        // has a saved record whose artifacts must be retained.
        let abandonedInterviews = state.path[index...]
          .compactMap { pathState -> (Session.ID, UUID)? in
            guard case .interview(let interview) = pathState else { return nil }
            return (interview.sessionID, interview.interviewID)
          }
          .filter { state.sessions[id: $0.0]?.state == .interviewing }
        guard !abandonedInterviews.isEmpty else { return .none }
        state.$sessions.withLock { sessions in
          for (id, _) in abandonedInterviews {
            if sessions[id: id]?.kind == .interview {
              _ = sessions.remove(id: id)
            } else {
              sessions[id: id]?.state = .summaryReady
              sessions[id: id]?.interviewID = nil
            }
          }
        }
        return .run { _ in
          for (_, interviewID) in abandonedInterviews {
            try? self.interviewArtifacts.destroy(interviewID)
          }
        }

      case .path:
        return .none

      case .alert(.presented(.openSystemSettings)):
        return .run { _ in
          await self.openURL(URL(string: UIApplication.openSettingsURLString)!)
        }

      case .alert:
        return .none
      }
    }
    .ifLet(\.$activeSession, action: \.activeSession) {
      ActiveSession()
    }
    .ifLet(\.$alert, action: \.alert)
    .forEach(\.path, action: \.path)
  }

  private func drainQueue(state: inout State) -> Effect<Action> {
    guard state.isConnected, state.summarizationInFlightID == nil else { return .none }

    let now = self.now
    if let session = state.sessions.first(where: { session in
      guard session.state == .awaitingSummarization else { return false }
      guard let failure = session.summarizationFailure else { return true }
      switch failure.requiredAction {
      case .retryNow:
        return failure.nextRetryAt.map { $0 <= now } ?? false
      case .automaticRetry:
        return failure.nextRetryAt.map { $0 <= now } ?? true
      case .openSettings, .contactSupport:
        return false
      }
    }) {
      let id = session.id
      state.summarizationInFlightID = id
      return .merge(
        .cancel(id: CancelID.retry),
        .run { send in
          let result: Result<SummaryResponse, any Error>
          do {
            let transcript: String
            do {
              transcript = try await self.transcriptVault.load(id)
            } catch {
              throw SummarizationPipelineError.transcriptUnavailable
            }
            result = await Result {
              try await self.conversationService.summarize(
                SummaryRequest(sessionID: id, transcript: transcript)
              )
            }
          } catch {
            result = .failure(error)
          }
          await send(.summarizationResponse(id, result))
        }
        .cancellable(id: CancelID.drain, cancelInFlight: true)
      )
    }

    guard
      let scheduled =
        (state.sessions
          .filter { session in
            session.state == .awaitingSummarization
              && session.summarizationFailure?.requiredAction == .automaticRetry
              && session.summarizationFailure?.nextRetryAt != nil
          }
          .compactMap({ session -> (Session.ID, Date)? in
            guard let date = session.summarizationFailure?.nextRetryAt else { return nil }
            return (session.id, date)
          })
          .min(by: { $0.1 < $1.1 }))
    else { return .cancel(id: CancelID.retry) }

    let delay = max(0, scheduled.1.timeIntervalSince(now))
    return .run { send in
      try await self.clock.sleep(for: .seconds(delay))
      await send(.retryTimerFired(scheduled.0, scheduled.1))
    }
    .cancellable(id: CancelID.retry, cancelInFlight: true)
  }

  private func summarizationFailure(
    for error: any Error,
    attemptCount: Int
  ) -> SummarizationFailure {
    let kind: SummarizationFailure.Kind
    let requiredAction: SummarizationFailure.RequiredAction

    if error is SummarizationPipelineError {
      kind = .transcriptUnavailable
      requiredAction = .contactSupport
    } else if let error = error as? ConversationServiceError {
      switch error {
      case .credentialsMissing:
        kind = .credentialsMissing
        requiredAction = .openSettings
      case .credentialsRejected:
        kind = .credentialsRejected
        requiredAction = .openSettings
      case .network:
        kind = .network
        requiredAction = .automaticRetry
      case .rateLimited:
        kind = .rateLimited
        requiredAction = .automaticRetry
      case .serviceUnavailable:
        kind = .serviceUnavailable
        requiredAction = .automaticRetry
      case .requestRejected:
        kind = .requestRejected
        requiredAction = .contactSupport
      case .invalidResponse:
        kind = .invalidResponse
        requiredAction = .contactSupport
      case .contentRefused:
        kind = .refusal
        requiredAction = .contactSupport
      case .responseTruncated:
        kind = .truncation
        requiredAction = .contactSupport
      case .unknown:
        kind = .unknown
        requiredAction = .retryNow
      }
    } else {
      kind = .unknown
      requiredAction = .retryNow
    }

    let nextRetryAt: Date?
    if requiredAction == .automaticRetry {
      let exponent = min(max(attemptCount - 1, 0), 6)
      let delay = min(TimeInterval(30 * (1 << exponent)), 1_800)
      nextRetryAt = self.now.addingTimeInterval(delay)
    } else {
      nextRetryAt = nil
    }
    return SummarizationFailure(
      kind: kind,
      attemptCount: attemptCount,
      nextRetryAt: nextRetryAt,
      requiredAction: requiredAction
    )
  }

  private func retrySummarization(state: inout State, id: Session.ID) -> Effect<Action> {
    guard state.sessions[id: id]?.state == .awaitingSummarization else { return .none }
    state.$sessions.withLock { sessions in
      if sessions[id: id]?.summarizationFailure == nil {
        sessions[id: id]?.summarizationFailure = SummarizationFailure(
          kind: .unknown,
          attemptCount: 0,
          nextRetryAt: self.now,
          requiredAction: .retryNow
        )
      } else {
        sessions[id: id]?.summarizationFailure?.nextRetryAt = self.now
        sessions[id: id]?.summarizationFailure?.requiredAction = .retryNow
      }
    }
    return .merge(.cancel(id: CancelID.retry), .send(.drainQueue))
  }

  private var offlineInterviewAlert: AlertState<Action.Alert> {
    AlertState {
      TextState("You're offline")
    } message: {
      TextState("The guided interview needs a connection. Try again when you're online.")
    }
  }

  private var microphoneDeniedAlert: AlertState<Action.Alert> {
    AlertState {
      TextState("Microphone access denied")
    } actions: {
      ButtonState(action: .openSystemSettings) { TextState("Open Settings") }
      ButtonState(role: .cancel) { TextState("Not Now") }
    } message: {
      TextState("Enable microphone access in System Settings before starting a new session.")
    }
  }

  private func startInterview(state: inout State, sessionID: Session.ID) -> Effect<Action> {
    guard
      let session = state.sessions[id: sessionID],
      session.state == .summaryReady,
      let summary = session.summary
    else { return .none }
    guard state.isConnected else {
      state.alert = AlertState {
        TextState("You're offline")
      } message: {
        TextState(
          "The interview needs a connection. It will be available from the session once you're back online."
        )
      }
      return .none
    }
    let interviewID = self.uuid()
    state.$sessions.withLock { sessions in
      sessions[id: sessionID]?.state = .interviewing
      sessions[id: sessionID]?.interviewID = interviewID
    }
    state.path.append(
      .interview(
        Interview.State(
          interviewID: interviewID,
          sessionID: sessionID,
          summary: summary
        )
      )
    )
    return .none
  }
}
extension AppFeature.Path.State: Equatable {}

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    NavigationStack(path: $store.scope(\.path, action: \.path)) {
      SessionsListView(store: store)
    } destination: { store in
      switch store.case {
      case .detail(let store):
        SessionDetailView(store: store)
      case .interview(let store):
        InterviewView(store: store)
      case .settings(let store):
        SettingsView(store: store)
      }
    }
    .fullScreenCover(
      item: $store.scope(\.activeSession, action: \.activeSession)
    ) { store in
      ActiveSessionView(store: store)
    }
    .alert($store.scope(\.alert, action: \.alert))
    .task {
      await store.send(.onLaunch).finish()
    }
  }
}

#Preview {
  @Shared(.sessions) var sessions = [
    Session(
      id: UUID(),
      startDate: Date(),
      duration: 1_260,
      state: .summaryReady,
      summary: "Discussed phase 3 efficacy data; the HCP asked about subgroup analyses.",
      consentUtterance: "Yes, that's fine, go ahead."
    ),
    Session(id: UUID(), startDate: Date().addingTimeInterval(-86_400), state: .lost),
  ]
  AppView(
    store: Store(initialState: AppFeature.State()) {
      AppFeature()
    }
  )
}
