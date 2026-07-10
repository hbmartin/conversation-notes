import ComposableArchitecture
import UIKit

struct PowerStatus: Equatable, Sendable {
  var isOnExternalPower: Bool
  var batteryLevel: Float

  /// The power gate for on-device transcription: up-to-an-hour of audio is a sustained thermal
  /// load, so transcription requires external power or a healthy battery. The threshold lives
  /// here so there is exactly one place to tune it.
  var allowsTranscription: Bool {
    isOnExternalPower || batteryLevel > 0.3
  }
}

@DependencyClient
struct PowerStateClient: Sendable {
  var powerStatus: @Sendable () async -> PowerStatus = {
    PowerStatus(isOnExternalPower: true, batteryLevel: 1)
  }
}

extension PowerStateClient: TestDependencyKey {
  static let previewValue = Self(
    powerStatus: { PowerStatus(isOnExternalPower: true, batteryLevel: 1) }
  )

  static let testValue = Self()
}

extension PowerStateClient: DependencyKey {
  static let liveValue = Self(
    powerStatus: {
      await MainActor.run {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        return PowerStatus(
          // The simulator reports `.unknown` with a level of -1; treat that as powered so the
          // gate never blocks development.
          isOnExternalPower: device.batteryState == .charging
            || device.batteryState == .full
            || device.batteryState == .unknown,
          batteryLevel: level < 0 ? 1 : level
        )
      }
    }
  )
}

extension DependencyValues {
  var powerState: PowerStateClient {
    get { self[PowerStateClient.self] }
    set { self[PowerStateClient.self] = newValue }
  }
}
