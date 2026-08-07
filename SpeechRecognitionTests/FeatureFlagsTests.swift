import Foundation
import Testing

@testable import SpeechRecognition

struct ConversationCaptureFlagTests {
  @Test
  func enabledForAffirmativeBuildSettingValues() {
    for raw in ["YES", "1", "true", " YES "] {
      #expect(ConversationCaptureFlag.isEnabled(from: ["ConversationCaptureEnabled": raw]))
    }
  }

  @Test
  func failsClosedForEverythingElse() {
    // An unsubstituted build setting is the realistic typo: the key stays literal in Info.plist.
    for raw in ["NO", "", "0", "false", "$(CONVERSATION_CAPTURE_ENABLED)", "yes please"] {
      #expect(!ConversationCaptureFlag.isEnabled(from: ["ConversationCaptureEnabled": raw]))
    }
    #expect(!ConversationCaptureFlag.isEnabled(from: [:]))
    #expect(!ConversationCaptureFlag.isEnabled(from: ["ConversationCaptureEnabled": true]))
  }
}
