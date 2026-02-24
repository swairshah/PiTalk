import ActivityKit
import Foundation

/// ActivityAttributes for PiTalk Live Activities.
/// One Live Activity per active/speaking session.
/// This file must be added to BOTH the main app target and the widget extension target.
struct PiTalkActivityAttributes: ActivityAttributes {
    // Static context — set when the activity starts.
    var sessionKey: String
    var agentName: String
    var projectName: String
    var serverName: String

    /// Dynamic state that updates as the session progresses.
    struct ContentState: Codable, Hashable {
        var activity: String          // "speaking", "queued", "waiting"
        var activityLabel: String
        var currentText: String?      // what's currently being spoken
        var lastSpokenText: String?   // last completed utterance
        var queuedCount: Int
        var updatedAtMs: Int64
        var isFinished: Bool          // session ended / went idle after speaking
    }
}
