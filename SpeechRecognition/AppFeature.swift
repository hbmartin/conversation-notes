import ComposableArchitecture
import SwiftUI

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
    var summarizeAttempt = 0
  }

  enum Action {
    case onLaunch
    case newSessionButtonTapped
    case settingsButtonTapped
    case sessionTapped(Session.ID)
    case connectivityChanged(Bool)
    case drainQueue
    case summarizationResponse(Session.ID, Result<SummarizationResult, any Error>)
    case transcriptDestroyed(Session.ID)
    case path(StackActionOf<Path>)
    case activeSession(PresentationAction<ActiveSession.Action>)
    case alert(PresentationAction<Alert>)

    enum Alert: Equatable {}
  }

  @Dependency(\.audioStorage) var audioStorage
  @Dependency(\.transcriptVault) var transcriptVault
  @Dependency(\.connectivity) var connectivity
  @Dependency(\.anthropicClient) var anthropic
  @Dependency(\.continuousClock) var clock
  @Dependency(\.uuid) var uuid
  @Dependency(\.date.now) var now

  private enum CancelID {
    case connectivity
    case drain
    case retry
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
          // A crash mid-interview leaves the summary intact; the interview can simply be redone.
          for id in sessions.ids where sessions[id: id]?.state == .interviewing {
            sessions[id: id]?.state = .summaryReady
          }
        }
        let validIDs = Set(state.sessions.ids)
        return .merge(
          .run { send in
            try? await self.audioStorage.purgeAllRecordings()
            for id in lostIDs {
              try? await self.transcriptVault.destroy(id)
            }
            // Orphan sweep: vault files with no matching session.
            for id in await self.transcriptVault.pendingIDs() where !validIDs.contains(id) {
              try? await self.transcriptVault.destroy(id)
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

      case .newSessionButtonTapped:
        let session = Session(id: self.uuid(), startDate: self.now, state: .recording)
        state.$sessions.withLock { _ = $0.append(session) }
        guard let sharedSession = Shared(state.$sessions[id: session.id]) else { return .none }
        state.activeSession = ActiveSession.State(session: sharedSession)
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
          state.summarizeAttempt = 0
          return .send(.drainQueue)
        }
        return .none

      case .drainQueue:
        guard
          state.isConnected,
          let session = state.sessions.first(where: { $0.state == .awaitingSummarization })
        else { return .none }
        return .run { [id = session.id] send in
          await send(
            .summarizationResponse(
              id,
              Result {
                let transcript = try await self.transcriptVault.load(id)
                return try await self.anthropic.summarize(transcript)
              }
            )
          )
        }
        .cancellable(id: CancelID.drain, cancelInFlight: true)

      case .summarizationResponse(let id, .success(let result)):
        state.summarizeAttempt = 0
        state.$sessions.withLock { sessions in
          sessions[id: id]?.summary = result.summary
          sessions[id: id]?.consentUtterance = result.consentUtterance
          sessions[id: id]?.state = .summaryReady
        }
        // Destroy the transcript only after the summary is durably in shared state.
        return .run { send in
          try? await self.transcriptVault.destroy(id)
          await send(.transcriptDestroyed(id))
        }

      case .summarizationResponse(_, .failure):
        // The transcript is intact in the vault; retry with capped exponential backoff.
        state.summarizeAttempt += 1
        let exponent = min(state.summarizeAttempt - 1, 6)
        let delay = min(Duration.seconds(30 * (1 << exponent)), Duration.seconds(1800))
        return .run { send in
          try await self.clock.sleep(for: delay)
          await send(.drainQueue)
        }
        .cancellable(id: CancelID.retry, cancelInFlight: true)

      case .transcriptDestroyed:
        // Continue with the next queued session, if any.
        return .send(.drainQueue)

      case .activeSession(.presented(.delegate(let delegateAction))):
        switch delegateAction {
        case .transcriptReady:
          return .send(.drainQueue)
        case .retrySummarization:
          state.summarizeAttempt = 0
          return .send(.drainQueue)
        case .discarded(let id):
          state.activeSession = nil
          state.$sessions.withLock { _ = $0.remove(id: id) }
          return .none
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
        case .retrySummarization:
          state.summarizeAttempt = 0
          return .send(.drainQueue)
        case .delete(let id):
          state.path.removeAll()
          state.$sessions.withLock { _ = $0.remove(id: id) }
          return .run { _ in
            try? await self.audioStorage.destroyRecording(id)
            try? await self.transcriptVault.destroy(id)
          }
        }

      case .path(.element(let pathID, action: .interview(.delegate(.interviewFinished(let record))))):
        state.$sessions.withLock { sessions in
          sessions[id: record.sessionID]?.interviewID = record.id
          sessions[id: record.sessionID]?.state = .saved
        }
        state.path.pop(from: pathID)
        return .none

      case .path:
        return .none

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

  private func startInterview(state: inout State, sessionID: Session.ID) -> Effect<Action> {
    guard
      let session = state.sessions[id: sessionID],
      let summary = session.summary
    else { return .none }
    guard state.isConnected else {
      state.alert = AlertState {
        TextState("You're offline")
      } message: {
        TextState("The interview needs a connection. It will be available from the session once you're back online.")
      }
      return .none
    }
    state.path.append(
      .interview(
        Interview.State(
          interviewID: self.uuid(),
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
