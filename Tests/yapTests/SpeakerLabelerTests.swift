import Foundation
import XCTest

@testable import yap

/// The pure half of diarization: which span a line belongs to, what the
/// clusters are called, and how a voice is recognised across meetings.
final class SpeakerLabelerTests: XCTestCase {
    private let spans = [
        SpeakerSpan(cluster: "B", start: 10, end: 14),
        SpeakerSpan(cluster: "A", start: 0, end: 4),
        SpeakerSpan(cluster: "A", start: 20, end: 25),
    ]

    func testOrderIsFirstAppearance() {
        XCTAssertEqual(SpeakerLabeler.order(spans), ["A", "B"])
    }

    func testDominantOverlapWins() {
        // 3 s of A, 1 s of B
        XCTAssertEqual(SpeakerLabeler.cluster(covering: 1, 11, in: spans), "A")
        XCTAssertEqual(SpeakerLabeler.cluster(covering: 12, 13, in: spans), "B")
    }

    func testAGapTakesTheNearestSpanWithinTolerance() {
        XCTAssertEqual(SpeakerLabeler.cluster(covering: 14.5, 15, in: spans), "B")
        XCTAssertNil(SpeakerLabeler.cluster(covering: 16.5, 17.5, in: spans), "two seconds from anything")
        XCTAssertNil(SpeakerLabeler.cluster(covering: 1, 2, in: []))
    }

    // MARK: - voices

    private func print(_ a: Float, _ b: Float) -> [Float] { Voices.normalized([a, b, 0.1]) }

    func testAKnownVoiceIsRecognisedAndNudged() {
        let known = Voice(id: "aaaa", name: "Reddy", embedding: print(1, 0), meetings: 2,
                          lastHeard: "x", lastSession: nil)
        let (voices, byCluster) = Voices.resolve(
            centroids: ["S0": print(0.95, 0.1), "S1": print(0, 1)],
            session: "2026.10.05-1441", in: [known])
        XCTAssertEqual(byCluster["S0"]?.id, "aaaa")
        XCTAssertEqual(byCluster["S0"]?.label(fallback: "them-1"), "Reddy")
        XCTAssertEqual(voices.count, 2, "the unmatched cluster became a new voice")
        XCTAssertEqual(voices[0].meetings, 3)
        XCTAssertEqual(voices[0].lastSession, "2026.10.05-1441")
        XCTAssertNil(byCluster["S1"]?.name)
        XCTAssertEqual(byCluster["S1"]?.label(fallback: "them-2"), "them-2")
        XCTAssertEqual(byCluster["S1"]?.meetings, 1)
    }

    func testTwoClustersCannotClaimOneVoice() {
        let known = Voice(id: "aaaa", name: nil, embedding: print(1, 0), meetings: 1,
                          lastHeard: "x", lastSession: nil)
        let (voices, byCluster) = Voices.resolve(
            centroids: ["near": print(0.99, 0.05), "nearer": print(1, 0.01)],
            session: "s", in: [known])
        XCTAssertEqual(byCluster["nearer"]?.id, "aaaa")
        XCTAssertNotEqual(byCluster["near"]?.id, "aaaa")
        XCTAssertEqual(voices.count, 2)
    }

    func testVoicesFileRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yap-voices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let voices = [Voice(id: "bbbb", name: "Kledi", embedding: [0.6, 0.8], meetings: 4,
                            lastHeard: "2026-10-05T14:00:00Z", lastSession: "2026.10.05-1441")]
        Voices.save(voices, to: url)
        XCTAssertEqual(Voices.load(from: url), voices)
        XCTAssertEqual(Voices.load(from: url.appendingPathExtension("missing")), [])
    }

    func testCosineDistance() {
        XCTAssertEqual(Voices.cosineDistance([1, 0], [1, 0]), 0, accuracy: 1e-6)
        XCTAssertEqual(Voices.cosineDistance([1, 0], [0, 1]), 1, accuracy: 1e-6)
        XCTAssertEqual(Voices.cosineDistance([], [1]), 1)
    }
}
