import Darwin
import XCTest

@testable import yap

@MainActor
final class MeetingDetectorTests: XCTestCase {
    func testAcceptedMeetingEndsWhenOnlyAnotherInputClientRemains() {
        let teamsPID = pid_t(10_001)
        let corespeechPID = pid_t(10_002)
        var active = Set([teamsPID])
        let detector = MeetingDetector { preferred in
            if let preferred {
                return active.contains(preferred) ? preferred : nil
            }
            return active.first
        }
        var starts = 0
        var ends = 0
        detector.onMeetingStart = { _, _ in starts += 1 }
        detector.onMeetingEnd = { ends += 1 }

        detector.poll()
        detector.poll()
        XCTAssertEqual(starts, 1)
        // The prompt survives one quiet poll. Accepting during that window
        // must still bind the recording to the client that raised it.
        active = []
        detector.poll()
        detector.acceptCurrentMeeting()

        // Starting yap's recorder can wake corespeechd. It must not stand in
        // for the Teams client after that client releases the microphone.
        active = [corespeechPID]
        for _ in 0..<14 { detector.poll() }
        XCTAssertEqual(ends, 0)
        detector.poll()
        XCTAssertEqual(ends, 1)
    }

    func testQuietGapThenSameClientAsksAgain() {
        let pid = pid_t(10_001)
        var active = true
        let detector = MeetingDetector { preferred in
            guard active else { return nil }
            return preferred == nil || preferred == pid ? pid : nil
        }
        var starts = 0
        var quiets = 0
        var ends = 0
        detector.onMeetingStart = { _, _ in starts += 1 }
        detector.onMeetingQuiet = { quiets += 1 }
        detector.onMeetingEnd = { ends += 1 }

        detector.poll()
        detector.poll()
        XCTAssertEqual(starts, 1)
        detector.acceptCurrentMeeting()

        active = false
        detector.poll()
        detector.poll()
        XCTAssertEqual(quiets, 1)

        active = true
        detector.poll()
        detector.poll()
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(ends, 0)
    }
}
