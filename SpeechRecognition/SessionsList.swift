import ComposableArchitecture
import SwiftUI

struct SessionsListView: View {
  let store: StoreOf<AppFeature>

  var body: some View {
    Group {
      if store.sessions.isEmpty {
        ContentUnavailableView(
          "No sessions yet",
          systemImage: "waveform.badge.mic",
          description: Text("Tap the record button to capture an HCP interaction.")
        )
      } else {
        List {
          ForEach(store.sessions.elements.reversed()) { session in
            Button {
              store.send(.sessionTapped(session.id))
            } label: {
              SessionRow(session: session)
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .navigationTitle("MSL Capture")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          store.send(.settingsButtonTapped)
        } label: {
          Image(systemName: "gearshape")
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          store.send(.newSessionButtonTapped)
        } label: {
          Label("New Session", systemImage: "record.circle.fill")
        }
        .tint(.red)
        .disabled(store.isRequestingMicrophonePermission)
      }
    }
  }
}

private struct SessionRow: View {
  let session: Session

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
          .font(.headline)
        Spacer()
        stateBadge
      }
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
      }
    }
    .padding(.vertical, 4)
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
        badge("Retrying", color: .orange)
      case nil:
        badge("Queued", color: .orange)
      }
    case .summaryReady:
      badge("Needs interview", color: .purple)
    case .interviewing:
      badge("Interviewing", color: .purple)
    case .saved:
      badge("Saved", color: .green)
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
