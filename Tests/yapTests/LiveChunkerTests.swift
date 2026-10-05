import XCTest

@testable import yap

/// `LiveChunker.cut` decides where a growing buffer of one speaker breaks.
/// Synthetic audio: a tone stands in for speech, zeros for a pause.
final class LiveChunkerTests: XCTestCase {
    private func tone(seconds: Double, amplitude: Float = 0.2) -> [Float] {
        let n = Int(seconds * Double(LiveChunker.rate))
        return (0..<n).map { amplitude * sin(Float($0) * 0.05) }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(LiveChunker.rate)))
    }

    func testUnderThreeSecondsWaits() {
        XCTAssertNil(LiveChunker.cut(tone(seconds: 2.9), final: false))
    }

    func testAPauseTakesEverything() {
        let samples = tone(seconds: 4) + silence(seconds: 0.7)
        XCTAssertEqual(LiveChunker.cut(samples, final: false), samples.count)
    }

    func testSpeechWithNoPauseWaitsForTenSeconds() {
        XCTAssertNil(LiveChunker.cut(tone(seconds: 8), final: false))
    }

    func testLongSpeechCutsAfterTheQuietestMoment() {
        // Ten seconds of speech with a 300 ms lull two seconds from the end.
        let before = tone(seconds: 7.7)
        let lull = silence(seconds: 0.3)
        let after = tone(seconds: 2.0)
        let samples = before + lull + after
        let cut = try! XCTUnwrap(LiveChunker.cut(samples, final: false))
        // After the lull, not in it: the window scan steps by half a window,
        // so the cut lands within half a window of the lull's end.
        let lullEnd = before.count + lull.count
        XCTAssertGreaterThanOrEqual(cut, lullEnd - Int(LiveChunker.windowSeconds * Double(LiveChunker.rate)) / 2)
        XCTAssertLessThanOrEqual(cut, lullEnd + Int(LiveChunker.windowSeconds * Double(LiveChunker.rate)) / 2)
    }

    func testFinalTakesWhateverIsThere() {
        XCTAssertEqual(LiveChunker.cut(tone(seconds: 0.5), final: true), Int(0.5 * Double(LiveChunker.rate)))
        XCTAssertNil(LiveChunker.cut([], final: true))
    }

    func testSilenceIsSkippedBeforeTheModel() {
        XCTAssertTrue(LiveChunker.isSilent(silence(seconds: 1)))
        XCTAssertFalse(LiveChunker.isSilent(tone(seconds: 1)))
    }
}
