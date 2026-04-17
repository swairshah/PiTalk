import XCTest
@testable import PiTalk

final class SpeechPlaybackCoordinatorTests: XCTestCase {
    func testLocalAutoVoiceAssignmentUsesConfiguredOrderAndCycles() {
        let previousProvider = UserDefaults.standard.string(forKey: "ttsProvider")
        UserDefaults.standard.set("local", forKey: "ttsProvider")
        defer {
            if let previousProvider {
                UserDefaults.standard.set(previousProvider, forKey: "ttsProvider")
            } else {
                UserDefaults.standard.removeObject(forKey: "ttsProvider")
            }
        }

        let coordinator = SpeechPlaybackCoordinator(defaultVoiceProvider: { "fallback" })

        let expectedVoices = [
            "fantine",
            "eponine",
            "cosette",
            "azelma",
            "alba",
            "fantine",
            "eponine",
        ]

        let assignedVoices = expectedVoices.indices.map { index in
            coordinator.assignAutoVoiceForQueueForTesting(
                sourceApp: "test-app-\(index)",
                sessionId: "session-\(index)"
            )
        }

        XCTAssertEqual(assignedVoices, expectedVoices)
    }
}
