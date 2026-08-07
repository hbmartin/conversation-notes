import ComposableArchitecture
import Foundation
import MetricKit
import os

extension LaunchMetricsClient: DependencyKey {
  static let liveValue = Self(
    start: { LaunchMetricsSubscriber.shared.start() }
  )
}

/// MetricKit delivers at most once a day, on a background queue, describing runs that already
/// finished — so this is a process-wide object with no relationship to any screen. It is a
/// singleton because `MXMetricManager` does not keep its subscribers alive, and because
/// subscribing twice would double every line in the log.
private final class LaunchMetricsSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable
{
  static let shared = LaunchMetricsSubscriber()

  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "SpeechRecognition",
    category: "launch-metrics"
  )
  private let isSubscribed = LockIsolated(false)

  func start() {
    let alreadySubscribed = self.isSubscribed.withValue { subscribed -> Bool in
      defer { subscribed = true }
      return subscribed
    }
    guard !alreadySubscribed else { return }
    MXMetricManager.shared.add(self)
  }

  // Every value logged below is an aggregate duration or a count, so all of it is `.public` —
  // redacting it would leave lines that say nothing. None of it derives from what was recorded.

  func didReceive(_ payloads: [MXMetricPayload]) {
    for payload in payloads {
      guard let launch = payload.applicationLaunchMetrics else { continue }
      let window = Self.dateFormatter.string(from: payload.timeStampBegin)
      let version =
        payload.includesMultipleApplicationVersions ? "mixed" : payload.latestApplicationVersion

      // Time to first draw is the number `docs/launch-performance.md` needs from hardware; the
      // optimized variant covers launches the system pre-warmed, which would otherwise flatter
      // the headline figure; extended launch runs past the first frame to interactive.
      for (name, histogram) in [
        ("timeToFirstDraw", launch.histogrammedTimeToFirstDraw),
        ("optimizedTimeToFirstDraw", launch.histogrammedOptimizedTimeToFirstDraw),
        ("extendedLaunch", launch.histogrammedExtendedLaunch),
        ("resume", launch.histogrammedApplicationResumeTime),
      ] {
        let summary = LaunchDurationHistogram(histogram).summary
        self.logger.log(
          """
          launch \(window, privacy: .public) v\(version, privacy: .public) \
          \(name, privacy: .public): \(summary, privacy: .public)
          """
        )
      }
    }
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    for payload in payloads {
      // The system raises one of these when a launch crossed its own slow-launch threshold, which
      // is the closest thing to a field alarm for the problem this whole document is about.
      for diagnostic in payload.appLaunchDiagnostics ?? [] {
        self.logger.error(
          """
          slow launch on device: \
          \(diagnostic.launchDuration.converted(to: .seconds).value, format: .fixed(precision: 2), privacy: .public)s \
          — call stack in Xcode Organizer
          """
        )
      }
      // A hang during launch reads to the operator as exactly the same complaint.
      for diagnostic in payload.hangDiagnostics ?? [] {
        self.logger.error(
          """
          hang on device: \
          \(diagnostic.hangDuration.converted(to: .seconds).value, format: .fixed(precision: 2), privacy: .public)s \
          — call stack in Xcode Organizer
          """
        )
      }
    }
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()
}

extension LaunchDurationHistogram {
  /// MetricKit picks its own unit per histogram, so convert rather than trusting the raw values.
  init(_ histogram: MXHistogram<UnitDuration>) {
    self.init(
      buckets: histogram.bucketEnumerator.compactMap { element in
        guard let bucket = element as? MXHistogramBucket<UnitDuration> else { return nil }
        return Bucket(
          start: bucket.bucketStart.converted(to: .milliseconds).value,
          end: bucket.bucketEnd.converted(to: .milliseconds).value,
          count: bucket.bucketCount
        )
      }
    )
  }
}
