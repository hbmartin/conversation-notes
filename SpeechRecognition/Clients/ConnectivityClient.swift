import ComposableArchitecture
import Foundation
import Network

@DependencyClient
struct ConnectivityClient: Sendable {
  var isConnected: @Sendable () async -> Bool = { false }
  var observe: @Sendable () -> AsyncStream<Bool> = { .finished }
}

extension ConnectivityClient: TestDependencyKey {
  static let previewValue = Self(
    isConnected: { true },
    observe: {
      AsyncStream { continuation in
        continuation.yield(true)
      }
    }
  )

  static let testValue = Self()
}

extension ConnectivityClient: DependencyKey {
  static var liveValue: Self {
    Self(
      isConnected: {
        await withCheckedContinuation { continuation in
          let monitor = NWPathMonitor()
          let hasResumed = LockIsolated(false)
          monitor.pathUpdateHandler = { path in
            let shouldResume = hasResumed.withValue { resumed -> Bool in
              guard !resumed else { return false }
              resumed = true
              return true
            }
            guard shouldResume else { return }
            continuation.resume(returning: path.status == .satisfied)
            monitor.cancel()
          }
          monitor.start(queue: DispatchQueue(label: "msl-capture.connectivity.one-shot"))
        }
      },
      observe: {
        AsyncStream { continuation in
          let monitor = NWPathMonitor()
          let lastValue = LockIsolated<Bool?>(nil)
          monitor.pathUpdateHandler = { path in
            let connected = path.status == .satisfied
            let isNew = lastValue.withValue { last -> Bool in
              guard last != connected else { return false }
              last = connected
              return true
            }
            if isNew {
              continuation.yield(connected)
            }
          }
          continuation.onTermination = { _ in monitor.cancel() }
          monitor.start(queue: DispatchQueue(label: "msl-capture.connectivity.monitor"))
        }
      }
    )
  }
}

extension DependencyValues {
  var connectivity: ConnectivityClient {
    get { self[ConnectivityClient.self] }
    set { self[ConnectivityClient.self] = newValue }
  }
}
