import ComposableArchitecture
import SwiftUI

struct SessionsListView: View {
  let store: StoreOf<AppFeature>
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    AuroraScreen {
      ScrollView {
        VStack(alignment: .leading, spacing: 30) {
          header
          captureActions
          recentActivity
        }
        .frame(maxWidth: 920)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 40)
      }
      .scrollIndicators(.hidden)
    }
    .navigationTitle("MSL Capture")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          store.send(.settingsButtonTapped)
        } label: {
          Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Capture your next interaction")
        .font(.system(.largeTitle, design: .rounded, weight: .bold))
      Text("Record an HCP conversation or begin a guided voice debrief—each whenever you need it.")
        .font(.title3)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var captureActions: some View {
    GlassEffectContainer(spacing: 18) {
      if self.horizontalSizeClass == .regular {
        HStack(spacing: 18) {
          conversationButton
          interviewButton
        }
      } else {
        VStack(spacing: 16) {
          conversationButton
          interviewButton
        }
      }
    }
  }

  private var conversationButton: some View {
    CaptureActionButton(
      title: "Record Conversation",
      description: "Transcribed on this device. Source audio is deleted after processing.",
      systemImage: "waveform.badge.mic",
      tint: AppTheme.conversation,
      isEnabled: !store.isRequestingMicrophonePermission,
      action: { store.send(.newConversationButtonTapped) }
    )
    .accessibilityHint("Starts a new conversation recording")
  }

  private var interviewButton: some View {
    CaptureActionButton(
      title: "Start Interview",
      description: "Answer a guided voice debrief. No conversation recording is required.",
      systemImage: "text.bubble.fill",
      tint: AppTheme.interview,
      isEnabled: true,
      action: { store.send(.newInterviewButtonTapped) }
    )
    .accessibilityHint("Starts a standalone guided interview")
  }

  private var recentActivity: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Recent Activity")
          .font(.title2.bold())
        Spacer()
        if !store.sessions.isEmpty {
          Text("\(store.sessions.count)")
            .font(.caption.bold())
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: .capsule)
            .accessibilityLabel("\(store.sessions.count) sessions")
        }
      }

      if store.sessions.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "waveform.path.ecg.rectangle")
            .font(.system(size: 34))
            .foregroundStyle(AppTheme.conversation)
          Text("Your captured interactions will appear here.")
            .font(.headline)
          Text("Choose either action above to begin.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .padding(.horizontal, 20)
        .auroraPanel()
      } else {
        LazyVStack(spacing: 12) {
          ForEach(store.sessions.elements.reversed()) { session in
            Button {
              store.send(.sessionTapped(session.id))
            } label: {
              SessionRow(session: session)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .auroraPanel()
            .accessibilityHint("Opens session details")
          }
        }
      }
    }
  }
}

private struct CaptureActionButton: View {
  let title: String
  let description: String
  let systemImage: String
  let tint: Color
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: self.action) {
      VStack(alignment: .leading, spacing: 18) {
        Image(systemName: self.systemImage)
          .font(.system(size: 34, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
        Spacer(minLength: 4)
        VStack(alignment: .leading, spacing: 7) {
          Text(self.title)
            .font(.title2.bold())
          Text(self.description)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
      .padding(24)
      .contentShape(.rect(cornerRadius: 30))
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.tint(self.tint.opacity(0.28)).interactive(), in: .rect(cornerRadius: 30))
    .disabled(!self.isEnabled)
    .opacity(self.isEnabled ? 1 : 0.58)
    .accessibilityLabel(self.title)
  }
}

private struct SessionRow: View {
  let session: Session

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: session.kind == .conversation ? "waveform" : "text.bubble.fill")
        .font(.title3.bold())
        .foregroundStyle(session.kind == .conversation ? AppTheme.conversation : AppTheme.interview)
        .frame(width: 44, height: 44)
        .background(
          (session.kind == .conversation ? AppTheme.conversation : AppTheme.interview).opacity(
            0.13),
          in: .circle
        )

      VStack(alignment: .leading, spacing: 6) {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline) {
            Text(session.kind == .conversation ? "Conversation" : "Guided Interview")
              .font(.headline)
            Spacer(minLength: 12)
            stateBadge
          }
          VStack(alignment: .leading, spacing: 6) {
            Text(session.kind == .conversation ? "Conversation" : "Guided Interview")
              .font(.headline)
            stateBadge
          }
        }
        Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
          .font(.caption)
          .foregroundStyle(.secondary)
        if let summary = session.summary {
          Text(summary)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        } else if let lossReason = session.lossReason {
          Text(lossReason)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        } else if session.kind == .interview {
          Text(
            session.state == .saved ? "Structured debrief captured" : "Guided debrief in progress"
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        }
      }
    }
    .padding(16)
  }

  @ViewBuilder
  private var stateBadge: some View {
    switch session.state {
    case .recording, .stopped, .transcribing:
      badge("In progress", color: .blue)
    case .awaitingSummarization:
      switch session.summarizationFailure?.requiredAction {
      case .openSettings:
        badge("Needs credentials", color: .red)
      case .contactSupport:
        badge("Needs attention", color: .red)
      case .automaticRetry:
        badge("Retry scheduled", color: .orange)
      case .retryNow:
        badge(
          session.summarizationFailure?.nextRetryAt == nil ? "Retry required" : "Retrying",
          color: .orange
        )
      case nil:
        badge("Queued", color: .orange)
      }
    case .summaryReady:
      badge("Needs interview", color: .purple)
    case .interviewing:
      badge("Interviewing", color: .purple)
    case .saved:
      badge(session.kind == .interview ? "Recorded" : "Saved", color: .green)
    case .permissionDenied:
      badge("Permission denied", color: .orange)
    case .lost:
      badge("Lost", color: .red)
    }
  }

  private func badge(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.caption.bold())
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color.opacity(0.15), in: Capsule())
      .foregroundStyle(color)
  }
}
