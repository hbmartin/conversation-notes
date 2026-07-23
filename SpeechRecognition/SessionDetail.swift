import ComposableArchitecture
import SwiftUI
import UIKit

@Reducer
struct SessionDetail {
  @ObservableState
  struct State: Equatable {
    @Shared var session: Session
    var interviewRecord: InterviewRecord?
    @Presents var alert: AlertState<Action.Alert>?
  }

  enum Action {
    case onAppear
    case interviewRecordLoaded(InterviewRecord?)
    case startInterviewTapped
    case retrySummarizationTapped
    case openSettingsTapped
    case deleteTapped
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)

    @CasePathable
    enum Delegate {
      case startInterview(Session.ID)
      case retrySummarization(Session.ID)
      case openSettings
      case delete(Session.ID)
    }

    enum Alert: Equatable {
      case confirmDelete
    }
  }

  @Dependency(\.interviewArtifacts) var artifacts

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        guard let interviewID = state.session.interviewID else { return .none }
        return .run { send in
          await send(.interviewRecordLoaded(try? self.artifacts.load(interviewID)))
        }

      case .interviewRecordLoaded(let record):
        state.interviewRecord = record
        return .none

      case .startInterviewTapped:
        return .send(.delegate(.startInterview(state.session.id)))

      case .retrySummarizationTapped:
        return .send(.delegate(.retrySummarization(state.session.id)))

      case .openSettingsTapped:
        return .send(.delegate(.openSettings))

      case .deleteTapped:
        state.alert = AlertState {
          TextState("Delete this session?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmDelete) { TextState("Delete") }
          ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
          TextState("This permanently deletes the session and cannot be undone.")
        }
        return .none

      case .alert(.presented(.confirmDelete)):
        return .send(.delegate(.delete(state.session.id)))

      case .alert:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }
}

struct SessionDetailView: View {
  @Bindable var store: StoreOf<SessionDetail>

  var body: some View {
    List {
      Section("Session") {
        LabeledContent(
          "Date", value: store.session.startDate.formatted(date: .abbreviated, time: .shortened)
        )
        if store.session.duration > 0 {
          LabeledContent(
            "Duration",
            value: Duration.seconds(store.session.duration)
              .formatted(.time(pattern: .minuteSecond))
          )
        }
      }

      switch store.session.state {
      case .awaitingSummarization:
        Section {
          SummarizationStatusView(
            failure: store.session.summarizationFailure,
            retry: { store.send(.retrySummarizationTapped) },
            openSettings: { store.send(.openSettingsTapped) }
          )
        }

      case .permissionDenied:
        Section {
          Label(
            store.session.lossReason ?? "Microphone access was denied before recording began.",
            systemImage: "mic.slash"
          )
          .foregroundStyle(.orange)
          Link(
            "Open System Settings",
            destination: URL(string: UIApplication.openSettingsURLString)!
          )
        }

      case .lost:
        Section {
          Label(
            store.session.lossReason ?? "This session was lost before transcription completed.",
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.red)
        }

      default:
        if let summary = store.session.summary {
          Section("Summary") {
            Text(summary)
          }
          Section("Consent") {
            if let consent = store.session.consentUtterance {
              Text("“\(consent)”").italic()
            } else {
              Label(
                "No consent statement was found in the conversation.",
                systemImage: "exclamationmark.triangle"
              )
              .foregroundStyle(.orange)
            }
          }
        }
      }

      if store.session.state == .summaryReady {
        Section {
          Button("Start Interview") {
            store.send(.startInterviewTapped)
          }
        }
      }

      if let extraction = store.interviewRecord?.extraction {
        Section("Interview") {
          LabeledContent("HCP specialty", value: extraction.hcpSpecialty)
          LabeledContent("Topics", value: extraction.topicsDiscussed.joined(separator: ", "))
          LabeledContent("Key questions", value: extraction.keyScientificQuestions)
          LabeledContent("Unanswered follow-ups", value: extraction.unansweredFollowUps)
          LabeledContent("Med-info requests", value: extraction.medInfoRequests)
          LabeledContent(
            "Adverse event / complaint",
            value: extraction.adverseEventReported
              ? "Yes — \(extraction.adverseEventDetail)" : "No"
          )
          LabeledContent(
            "Off-label discussion",
            value: extraction.offLabelDiscussed ? "Yes — \(extraction.offLabelDetail)" : "No"
          )
          LabeledContent("HCP sentiment", value: extraction.hcpSentiment.rawValue.capitalized)
          LabeledContent("Next steps", value: extraction.commitmentsNextSteps)
          LabeledContent("Follow-up needed", value: extraction.followUpNeeded ? "Yes" : "No")
        }
        if extraction.adverseEventReported {
          Section {
            Label(
              "An adverse event or product complaint was captured. Reporting it through your pharmacovigilance process is your responsibility — this app does not transmit reports.",
              systemImage: "exclamationmark.shield"
            )
            .foregroundStyle(.red)
          }
        }
      }

      Section {
        Button("Delete Session", role: .destructive) {
          store.send(.deleteTapped)
        }
      }
    }
    .navigationTitle("Session")
    .navigationBarTitleDisplayMode(.inline)
    .alert($store.scope(state: \.alert, action: \.alert))
    .onAppear {
      store.send(.onAppear)
    }
  }
}

struct SummarizationStatusView: View {
  let failure: SummarizationFailure?
  let retry: () -> Void
  let openSettings: () -> Void

  var body: some View {
    if let failure {
      Label(failure.userMessage, systemImage: "exclamationmark.triangle")
        .foregroundStyle(failure.requiredAction == .contactSupport ? .red : .orange)

      Text("Failed attempt \(failure.attemptCount)")
        .font(.footnote)
        .foregroundStyle(.secondary)

      switch failure.requiredAction {
      case .automaticRetry:
        if let nextRetryAt = failure.nextRetryAt {
          LabeledContent(
            "Next retry",
            value: nextRetryAt.formatted(date: .abbreviated, time: .shortened)
          )
        }
      case .openSettings:
        Button("Open Settings", action: self.openSettings)
          .buttonStyle(.borderedProminent)
      case .retryNow:
        Label("Retry requested", systemImage: "arrow.clockwise")
          .foregroundStyle(.secondary)
      case .contactSupport:
        Label("Contact your administrator or support team.", systemImage: "person.crop.circle.badge.questionmark")
          .foregroundStyle(.secondary)
      }
    } else {
      Label(
        "Waiting to summarize. The encrypted transcript remains queued until processing succeeds.",
        systemImage: "clock"
      )
    }

    Button("Retry This Session", action: self.retry)
      .disabled(failure?.requiredAction == .retryNow)
  }
}
