import Foundation
import Testing

@testable import SpeechRecognition

/// `MXHistogram` has no public initializer, so the MetricKit glue itself cannot be tested — which
/// is the reason `LaunchDurationHistogram` exists as a plain value type. Everything with a
/// judgement call in it lives here; what is left in `LaunchMetricsClientLive` is a conversion.
struct LaunchMetricsTests {
  /// Roughly the shape MetricKit delivers for time-to-first-draw: a long tail of coarse buckets,
  /// most samples near the front.
  private let launchHistogram = LaunchDurationHistogram(buckets: [
    .init(start: 0, end: 500, count: 10),
    .init(start: 500, end: 1_000, count: 60),
    .init(start: 1_000, end: 1_500, count: 20),
    .init(start: 1_500, end: 2_500, count: 8),
    .init(start: 2_500, end: 5_000, count: 2),
  ])

  @Test
  func quantilesLandInTheBucketHoldingTheNthSample() {
    #expect(self.launchHistogram.sampleCount == 100)
    // 50th of 100 samples is the 40th within the 500–1000 bucket.
    #expect(self.launchHistogram.bucket(atQuantile: 0.5)?.start == 500)
    // 90th falls in 1000–1500, whose samples run from 71st to 90th.
    #expect(self.launchHistogram.bucket(atQuantile: 0.9)?.start == 1_000)
    // The boundary belongs to the bucket that contains it, not the next one along.
    #expect(self.launchHistogram.bucket(atQuantile: 0.7)?.start == 500)
    #expect(self.launchHistogram.bucket(atQuantile: 0.71)?.start == 1_000)
  }

  @Test
  func extremeQuantilesStayInsideTheHistogram() {
    #expect(self.launchHistogram.bucket(atQuantile: 0)?.start == 0)
    #expect(self.launchHistogram.bucket(atQuantile: 1)?.end == 5_000)
    // Rounding must not run off the end and return nil for a histogram that has samples.
    #expect(self.launchHistogram.bucket(atQuantile: 0.999)?.end == 5_000)
  }

  /// An empty histogram is the normal case for a metric the app never exercised — a resume
  /// histogram on a build nobody backgrounded, say. It must read as "nothing to report" rather
  /// than as a fast launch.
  @Test
  func anEmptyHistogramReportsNoSamplesRatherThanZero() {
    let empty = LaunchDurationHistogram()

    #expect(empty.sampleCount == 0)
    #expect(empty.bucket(atQuantile: 0.5) == nil)
    #expect(empty.summary == "no samples")
  }

  /// Buckets MetricKit sends with a zero count must not be mistaken for the tail; reporting
  /// `max <5000ms` when nothing landed above 1500ms would overstate the worst case.
  @Test
  func emptyTrailingBucketsDoNotSetTheReportedMaximum() {
    let histogram = LaunchDurationHistogram(buckets: [
      .init(start: 0, end: 500, count: 4),
      .init(start: 500, end: 1_500, count: 6),
      .init(start: 1_500, end: 5_000, count: 0),
    ])

    #expect(histogram.summary.hasSuffix("max <1500ms"))
  }

  @Test
  func theSummaryReadsAsOneLineOfLog() {
    #expect(self.launchHistogram.summary == "n=100  p50 500–1000ms  p90 1000–1500ms  max <5000ms")
  }
}
