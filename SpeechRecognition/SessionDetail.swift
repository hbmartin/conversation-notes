import ComposableArchitecture
import SwiftUI

@Reducer
struct SessionDetail {
  @ObservableState
  struct State: Equatable {
    @Shared var session: Session
    var interviewRecord: InterviewRecord?
  }

  enum Action {
    case onAppear
    case interviewRecordLoaded(InterviewRecord?)
    case startInterviewTapped
    case retrySummarizationTapped
    case deleteTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate {
      case startInterview(Session.ID)
      case retrySummarization
      case delete(Session.ID)
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
        return .send(.delegate(.retrySummarization))

      case .deleteTapped:
        return .send(.delegate(.delete(state.session.id)))

      case .delegate:
        return .none
      }
    }
  }
}

struct SessionDetailView: View {
  let store: StoreOf<SessionDetail>

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
          Label(
            "Waiting to summarize. The encrypted transcript is queued and will be processed automatically when online.",
            systemImage: "clock"
          )
          Button("Retry Now") {
            store.send(.retrySummarizationTapped)
          }
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
    .onAppear {
      store.send(.onAppear)
    }
  }
}
