import ComposableArchitecture
import Foundation
import Testing

@testable import SpeechRecognition

/// These tests run non-exhaustively: the capture pipeline's effects complete synchronously with
/// test dependencies, so `@Shared` session mutations land ahead of per-action assertion
/// boundaries. The load-bearing invariants — destruction ordering and final states — are
/// asserted directly against the spy event log and final state.
@MainActor
struct ActiveSessionTests {
  /// Builds a store around a freshly-recorded session, with a controllable recorder and an
  /// event log spying on every destruction-relevant endpoint.
  private func makeStore(
    session: Session,
    events: LockIsolated<[String]>,
    recorderFinish: (
      stream: AsyncStream<Bool>, continuation: AsyncStream<Bool>.Continuation
    ),
    configure: @escaping (inout DependencyValues) -> Void = { _ in }
  ) -> TestStore<ActiveSession.State, ActiveSession.Action> {
    @Shared(.sessions) var sessions = [session]
    let store = TestStore(
      initialState: ActiveSession.State(session: Shared($sessions[id: session.id])!)
    ) {
      ActiveSession()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.audioRecorder.requestRecordPermission = { true }
      $0.audioRecorder.currentTime = { 42 }
      $0.audioRecorder.startRecording = { _ in
        for await didFinish in recorderFinish.stream {
          return didFinish
        }
        throw CancellationError()
      }
      $0.audioRecorder.stopRecording = {
        events.withValue { $0.append("recorder.stop") }
        recorderFinish.continuation.yield(true)
        recorderFinish.continuation.finish()
      }
      $0.audioRecorder.pauseRecording = { events.withValue { $0.append("recorder.pause") } }
      $0.audioRecorder.resumeRecording = { events.withValue { $0.append("recorder.resume") } }
      $0.audioStorage.recordingURL = { _ in URL(fileURLWithPath: "/dev/null/recording.m4a") }
      $0.audioStorage.destroyRecording = { id in
        events.withValue { $0.append("audio.destroy(\(id))") }
      }
      $0.transcriptVault.store = { id, _ in
        events.withValue { $0.append("vault.store(\(id))") }
      }
      $0.transcriptVault.destroy = { id in
        events.withValue { $0.append("vault.destroy(\(id))") }
      }
      $0.transcriptionClient.prepare = { _ in }
      $0.transcriptionClient.transcribe = { _ in Transcript(fullText: "hello world") }
      $0.powerState.powerStatus = { PowerStatus(isOnExternalPower: true, batteryLevel: 1) }
      configure(&$0)
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  func happyPathDestroysAudioOnlyAfterVaultStore() async {
    let id = UUID(0)
    let session = Session(id: id, startDate: Date(timeIntervalSince1970: 0), state: .recording)
    let events = LockIsolated<[String]>([])
    let recorderFinish = AsyncStream.makeStream(of: Bool.self)
    let store = makeStore(session: session, events: events, recorderFinish: recorderFinish)

    let task = await store.send(.onTask)
    await store.send(.stopTapped)
    await store.receive(\.delegate.transcriptReady)

    #expect(store.state.phase == .pipeline)
    #expect(store.state.session.state == .awaitingSummarization)
    #expect(store.state.session.duration == 42)

    // The privacy invariant: the transcript is vaulted strictly before the audio is destroyed,
    // and the vault is never touched for destruction on the happy path.
    #expect(
      events.value == ["recorder.stop", "vault.store(\(id))", "audio.destroy(\(id))"]
    )

    await task.cancel()
  }

  @Test
  func powerGateBlocksTranscriptionUntilRetry() async {
    let session = Session(id: UUID(0), startDate: Date(timeIntervalSince1970: 0), state: .recording)
    let events = LockIsolated<[String]>([])
    let recorderFinish = AsyncStream.makeStream(of: Bool.self)
    let lowBattery = PowerStatus(isOnExternalPower: false, batteryLevel: 0.2)
    let store = makeStore(session: session, events: events, recorderFinish: recorderFinish) {
      $0.powerState.powerStatus = { lowBattery }
      // Transcription must not run while gated; an unimplemented endpoint fails the test if hit.
      $0.transcriptionClient.transcribe = TranscriptionClient.testValue.transcribe
    }

    let task = await store.send(.onTask)
    await store.send(.stopTapped)
    await store.receive(\.powerStatusResponse)

    #expect(store.state.phase == .waitingForPower(lowBattery))
    #expect(store.state.session.state == .stopped)
    #expect(!events.value.contains { $0.hasPrefix("vault.store") })

    // Operator plugs in and retries.
    store.dependencies.powerState.powerStatus = {
      PowerStatus(isOnExternalPower: true, batteryLevel: 0.2)
    }
    store.dependencies.transcriptionClient.transcribe = { _ in Transcript(fullText: "ok") }
    await store.send(.retryTranscriptionTapped)
    await store.receive(\.delegate.transcriptReady)

    #expect(store.state.phase == .pipeline)
    #expect(store.state.session.state == .awaitingSummarization)

    await task.cancel()
  }

  @Test
  func transcriptionFailureKeepsAudio() async {
    struct TranscribeError: Error {}
    let session = Session(id: UUID(0), startDate: Date(timeIntervalSince1970: 0), state: .recording)
    let events = LockIsolated<[String]>([])
    let recorderFinish = AsyncStream.makeStream(of: Bool.self)
    let store = makeStore(session: session, events: events, recorderFinish: recorderFinish) {
      $0.transcriptionClient.transcribe = { _ in throw TranscribeError() }
    }

    let task = await store.send(.onTask)
    await store.send(.stopTapped)
    await store.receive(\.transcriptionResponse)

    guard case .failed = store.state.phase else {
      Issue.record("Expected the failed phase, got \(store.state.phase)")
      return
    }
    #expect(store.state.session.state == .stopped)
    // Audio must survive a transcription failure so it can be retried.
    #expect(!events.value.contains { $0.hasPrefix("audio.destroy") })
    #expect(!events.value.contains { $0.hasPrefix("vault.store") })

    await task.cancel()
  }

  @Test
  func pauseAndResumeControlTimerAndRecorder() async {
    let session = Session(id: UUID(0), startDate: Date(timeIntervalSince1970: 0), state: .recording)
    let events = LockIsolated<[String]>([])
    let recorderFinish = AsyncStream.makeStream(of: Bool.self)
    let clock = TestClock()
    let store = makeStore(session: session, events: events, recorderFinish: recorderFinish) {
      $0.continuousClock = clock
    }

    let task = await store.send(.onTask)
    await clock.advance(by: .seconds(2))
    await store.receive(\.timerTicked)
    await store.receive(\.timerTicked)
    #expect(store.state.elapsed == 2)

    await store.send(.pauseTapped)
    #expect(store.state.phase == .recording(paused: true))
    await clock.advance(by: .seconds(2))
    await store.receive(\.timerTicked)
    await store.receive(\.timerTicked)
    // Ticks while paused do not accrue elapsed time.
    #expect(store.state.elapsed == 2)

    await store.send(.resumeTapped)
    #expect(store.state.phase == .recording(paused: false))
    await clock.advance(by: .seconds(1))
    await store.receive(\.timerTicked)
    #expect(store.state.elapsed == 3)

    #expect(events.value.contains("recorder.pause"))
    #expect(events.value.contains("recorder.resume"))

    await task.cancel()
  }

  @Test
  func discardDestroysEverythingAndDelegates() async {
    let id = UUID(0)
    let session = Session(id: id, startDate: Date(timeIntervalSince1970: 0), state: .recording)
    let events = LockIsolated<[String]>([])
    let recorderFinish = AsyncStream.makeStream(of: Bool.self)
    let store = makeStore(session: session, events: events, recorderFinish: recorderFinish)

    let task = await store.send(.onTask)
    await store.send(.discardTapped)
    #expect(store.state.alert != nil)

    await store.send(.alert(.presented(.confirmDiscard)))
    await store.receive(\.delegate.discarded)

    #expect(store.state.isDiscarding)
    // The session was never marked lost: the recorder's clean-stop callback is ignored while
    // discarding.
    #expect(store.state.session.state == .recording)
    #expect(events.value.contains("audio.destroy(\(id))"))
    #expect(events.value.contains("vault.destroy(\(id))"))

    await task.cancel()
  }

  @Test
  func interruptionMarksSessionLostAndPurges() async {
    let id = UUID(0)
    let session = Session(id: id, startDate: Date(timeIntervalSince1970: 0), state: .recording)
    let events = LockIsolated<[String]>([])
    let recorderFinish = AsyncStream.makeStream(of: Bool.self)
    let store = makeStore(session: session, events: events, recorderFinish: recorderFinish)

    let task = await store.send(.onTask)

    // A phone call preempts the microphone: the recorder finishes unsuccessfully.
    recorderFinish.continuation.yield(false)
    recorderFinish.continuation.finish()
    await store.receive(\.recorderDidFinish)

    #expect(store.state.session.state == .lost)
    #expect(store.state.session.lossReason != nil)
    #expect(store.state.alert != nil)
    #expect(events.value.contains("audio.destroy(\(id))"))
    #expect(events.value.contains("vault.destroy(\(id))"))

    await store.send(.alert(.presented(.acknowledgeLost)))
    await store.receive(\.delegate.closed)

    await task.cancel()
  }
}
