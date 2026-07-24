import Foundation

// MARK: - Structured extraction

/// The fixed required-field schema for the post-conversation interview (spec §10). All
/// structured medical-affairs data derives from the operator interview — never from the
/// (destroyed) conversation transcript.
struct InterviewExtraction: Codable, Equatable, Sendable {
  var hcpSpecialty: String
  var topicsDiscussed: [String]
  var keyScientificQuestions: String
  var unansweredFollowUps: String
  var medInfoRequests: String
  var adverseEventReported: Bool
  var adverseEventDetail: String
  var offLabelDiscussed: Bool
  var offLabelDetail: String
  var hcpSentiment: HCPSentiment
  var commitmentsNextSteps: String
  var followUpNeeded: Bool

  enum HCPSentiment: String, Codable, Equatable, Sendable, CaseIterable {
    case positive
    case neutral
    case negative
  }

  private enum CodingKeys: String, CodingKey {
    case hcpSpecialty = "hcp_specialty"
    case topicsDiscussed = "topics_discussed"
    case keyScientificQuestions = "key_scientific_questions"
    case unansweredFollowUps = "unanswered_follow_ups"
    case medInfoRequests = "med_info_requests"
    case adverseEventReported = "adverse_event_reported"
    case adverseEventDetail = "adverse_event_detail"
    case offLabelDiscussed = "off_label_discussed"
    case offLabelDetail = "off_label_detail"
    case hcpSentiment = "hcp_sentiment"
    case commitmentsNextSteps = "commitments_next_steps"
    case followUpNeeded = "follow_up_needed"
  }
}

// MARK: - Retained interview artifacts

/// Everything the interview retains (unlike the conversation, nothing here is destroyed):
/// the Q&A transcript, references to per-answer audio files, and the structured extraction.
/// `operatorEdits` is the v2 correction-screen seam — an append-only audit list.
struct InterviewRecord: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var sessionID: UUID
  var startedAt: Date
  var endedAt: Date?
  var summaryUsed: String?
  var turns: [InterviewTurn]
  var extraction: InterviewExtraction?
  var model: String
  var schemaVersion = 1
  var operatorEdits: [FieldEdit]?
  /// Optional for backward-compatible decoding of records written before service auditing.
  var serviceAuditTrail: [ServiceAuditMetadata]? = nil
}

struct InterviewTurn: Codable, Equatable, Sendable {
  var index: Int
  var question: String
  var answerTranscript: String
  /// Relative to the interview directory, e.g. "answer-0.caf".
  var audioFileName: String?
  var askedAt: Date
}

struct FieldEdit: Codable, Equatable, Sendable {
  var field: String
  var oldValue: String
  var newValue: String
  var editedAt: Date
}

// MARK: - Agent configuration

enum InterviewAgent {
  static let toolName = "record_interview"

  static let recordInterviewTool = AnthropicTool(
    name: toolName,
    description: """
      Record the completed post-interaction interview. Call this EXACTLY ONCE, only after every \
      field below has been gathered from the operator AND you have explicitly asked about \
      (a) adverse events or product complaints and (b) off-label discussion. Until you call \
      this tool, your plain-text reply is the next question to ask.
      """,
    inputSchema: {
      do {
        return try JSONValue(
          parsing: """
            {
              "type": "object",
              "properties": {
                "hcp_specialty": {"type": "string"},
                "topics_discussed": {"type": "array", "items": {"type": "string"}},
                "key_scientific_questions": {"type": "string"},
                "unanswered_follow_ups": {"type": "string"},
                "med_info_requests": {"type": "string"},
                "adverse_event_reported": {"type": "boolean"},
                "adverse_event_detail": {
                  "type": "string",
                  "description": "Details of the adverse event or product complaint; empty string if none"
                },
                "off_label_discussed": {"type": "boolean"},
                "off_label_detail": {
                  "type": "string",
                  "description": "Details of the off-label discussion; empty string if none"
                },
                "hcp_sentiment": {"type": "string", "enum": ["positive", "neutral", "negative"]},
                "commitments_next_steps": {"type": "string"},
                "follow_up_needed": {"type": "boolean"}
              },
              "required": [
                "hcp_specialty", "topics_discussed", "key_scientific_questions",
                "unanswered_follow_ups", "med_info_requests", "adverse_event_reported",
                "adverse_event_detail", "off_label_discussed", "off_label_detail",
                "hcp_sentiment", "commitments_next_steps", "follow_up_needed"
              ],
              "additionalProperties": false
            }
            """)
      } catch {
        preconditionFailure("Invalid interview schema: \(error)")
      }
    }()
  )

  static func systemPrompt(summary: String?) -> String {
    let context: String
    if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      context = """
        Use the conversation summary below to pre-fill your understanding and skip questions whose \
        answers are already unambiguous from the summary.

        Conversation summary (context, already scrubbed of patient identifiers):
        ```
        \(summary)
        ```
        """
    } else {
      context = """
        This is a standalone interview with no conversation summary. Gather every required field \
        directly from the operator; do not assume or pre-fill any answer.
        """
    }

    return """
      You are a structured debrief interviewer for a Medical Science Liaison (MSL) who has just \
      finished a conversation with a healthcare professional (HCP). Interview the MSL by voice, \
      one question at a time.

      Rules:
      - Your plain-text output is spoken aloud verbatim. Ask exactly ONE short, conversational \
      question per turn — no lists, no markdown, no preamble.
      - You must gather every field of the `record_interview` tool before finishing. You MUST \
      explicitly ask these two \
      questions in some form, even if other context seems to answer them: (1) "Were any adverse \
      events or product complaints mentioned?" (2) "Was there any off-label discussion?"
      - You may ask follow-ups to clarify vague answers. Keep the whole interview under about \
      ten questions.
      - When — and only when — all fields are gathered and both mandatory questions have been \
      explicitly asked and answered, call `record_interview` exactly once. Do not call it \
      earlier; do not produce a question and the tool call in the same turn.

      \(context)
      """
  }

  static let openingUserMessage = AnthropicMessage(
    role: .user,
    content: [.text("Please begin the interview.")]
  )

  static let closingRemark = "Thanks — the interview is recorded."
}
