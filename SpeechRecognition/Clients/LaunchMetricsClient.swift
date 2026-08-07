import ComposableArchitecture
import Foundation

/// Field launch measurements, from MetricKit.
///
/// `docs/launch-performance.md` records launch as ~1.8 CPU-seconds measured in the Simulator,
/// where nearly half of main-thread startup is an accessibility-bundle `dlopen` storm that does
/// not exist on device. Nothing local can correct for that. This is the only source of numbers
/// from real hardware, so it is the instrument for followup 1.
///
/// **Nothing here leaves the device.** Payloads are summarised into the unified log and dropped:
/// no network call, no file written, no user content involved — MetricKit reports aggregate
/// durations and call stacks, never anything the operator recorded. If those summaries ever do
/// need to go somewhere, this client is the seam to do it in.
@DependencyClient
struct LaunchMetricsClient: Sendable {
  /// Subscribes for the life of the process. Calling it more than once is a no-op.
  var start: @Sendable () -> Void
}

extension LaunchMetricsClient: TestDependencyKey {
  static let previewValue = Self(start: {})

  /// Left unimplemented, unlike `FeatureFlagsClient`: subscribing is an effect, and a test that
  /// runs launch should have to say that it expects launch to subscribe.
  static let testValue = Self()
}

extension DependencyValues {
  var launchMetrics: LaunchMetricsClient {
    get { self[LaunchMetricsClient.self] }
    set { self[LaunchMetricsClient.self] = newValue }
  }
}

/// A MetricKit duration histogram flattened to plain numbers.
///
/// `MXHistogram` has no public initializer, so nothing that takes one can be unit tested.
/// Flattening at the boundary leaves the part with judgement in it — locating a quantile in
/// bucketed data — testable, and the MetricKit glue thin enough to read.
struct LaunchDurationHistogram: Equatable, Sendable {
  struct Bucket: Equatable, Sendable {
    /// Milliseconds. MetricKit's bucket bounds are exclusive at both ends.
    var start: Double
    var end: Double
    var count: Int
  }

  /// Ascending by `start`, the order MetricKit delivers them in.
  var buckets: [Bucket] = []

  var sampleCount: Int {
    self.buckets.reduce(0) { $0 + $1.count }
  }

  /// The bucket a quantile falls in, or `nil` when there are no samples.
  ///
  /// A histogram cannot answer "what is p50", only "which range is p50 in". Returning the bucket
  /// instead of interpolating a point inside it keeps that honest: MetricKit's launch buckets run
  /// hundreds of milliseconds wide, and a reported `p50 = 843ms` would be precision that does not
  /// exist.
  func bucket(atQuantile quantile: Double) -> Bucket? {
    let total = self.sampleCount
    guard total > 0 else { return nil }
    let target = min(total, max(1, Int((Double(total) * quantile).rounded(.up))))
    var seen = 0
    for bucket in self.buckets {
      seen += bucket.count
      if seen >= target { return bucket }
    }
    return self.buckets.last
  }

  /// e.g. `n=214  p50 700–800ms  p90 1400–1600ms  max <2000ms`
  var summary: String {
    guard self.sampleCount > 0 else { return "no samples" }
    var parts = ["n=\(self.sampleCount)"]
    for (label, quantile) in [("p50", 0.5), ("p90", 0.9)] {
      guard let bucket = self.bucket(atQuantile: quantile) else { continue }
      parts.append("\(label) \(Self.milliseconds(bucket.start))–\(Self.milliseconds(bucket.end))ms")
    }
    if let highest = self.buckets.last(where: { $0.count > 0 }) {
      parts.append("max <\(Self.milliseconds(highest.end))ms")
    }
    return parts.joined(separator: "  ")
  }

  private static func milliseconds(_ value: Double) -> String {
    String(Int(value.rounded()))
  }
}
