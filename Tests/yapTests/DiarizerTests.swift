import AVFoundation
import XCTest

@testable import yap

/// The diarizer on real audio: two synthetic voices in turn must come out as
/// two clusters whose spans fall where each voice spoke. Needs the diarizer
/// models in the FluidAudio cache and `say`, so it skips on a bare runner.
final class DiarizerTests: XCTestCase {
    func testTwoVoicesInTurnAreTwoClusters() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yap-diar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let text = "The firewall change goes in on Thursday and the rollback plan is written up. "
            + "We moved the hot tier across and the dashboards are up but the alert rules still need porting."
        var parts: [URL] = []
        for (i, voice) in ["Samantha", "Daniel"].enumerated() {
            let url = dir.appendingPathComponent("part\(i).caf")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", voice, "-o", url.path, "--data-format=LEF32@16000", text]
            try say.run()
            say.waitUntilExit()
            guard say.terminationStatus == 0 else { throw XCTSkip("say voice \(voice) unavailable") }
            parts.append(url)
        }
        // Samantha, Daniel, Samantha, Daniel: four turns, two voices.
        let joined = dir.appendingPathComponent("system.caf")
        let format = try AVAudioFile(forReading: parts[0]).processingFormat
        let out = try AVAudioFile(forWriting: joined, settings: format.settings)
        var turns: [(voice: Int, start: Double, end: Double)] = []
        var cursor = 0.0
        for voice in [0, 1, 0, 1] {
            let file = try AVAudioFile(forReading: parts[voice])
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
            else { return }
            try file.read(into: buffer)
            try out.write(from: buffer)
            let seconds = Double(buffer.frameLength) / format.sampleRate
            turns.append((voice, cursor, cursor + seconds))
            cursor += seconds
        }

        let modelsDir = OfflineModelsProbe.directory
        guard FileManager.default.fileExists(atPath: modelsDir.path)
        else { throw XCTSkip("diarizer models not downloaded (\(modelsDir.path))") }

        let started = Date()
        let result = try await Diarizer.run(joined)
        let took = Date().timeIntervalSince(started)
        print("diarized \(Int(cursor)) s of audio in \(String(format: "%.1f", took)) s")

        let clusters = SpeakerLabeler.order(result.spans)
        XCTAssertEqual(clusters.count, 2, "two voices: \(result.spans)")
        XCTAssertEqual(result.centroids.count, 2)

        // Each turn's middle second lands in a cluster, and the two voices
        // never share one.
        var byVoice: [Int: Set<String>] = [:]
        for turn in turns {
            let mid = (turn.start + turn.end) / 2
            let cluster = try XCTUnwrap(
                SpeakerLabeler.cluster(covering: mid - 0.5, mid + 0.5, in: result.spans),
                "turn at \(turn.start)s has no cluster")
            byVoice[turn.voice, default: []].insert(cluster)
        }
        XCTAssertEqual(byVoice[0]?.count, 1, "Samantha's turns are one voice")
        XCTAssertEqual(byVoice[1]?.count, 1, "Daniel's turns are one voice")
        XCTAssertNotEqual(byVoice[0], byVoice[1])
    }
}

/// Where FluidAudio keeps the offline diarizer bundles, without importing its
/// internals into the test.
enum OfflineModelsProbe {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    }
}

/// Measure the pass on a real track: `YAP_DIARIZE_FILE=/path/system.caf swift test
/// --filter DiarizerMeasure`. Prints the timing and the voices found; asserts
/// only that it ran. The number for the PR comes from here, not from a guess.
final class DiarizerMeasure: XCTestCase {
    func testMeasureOnAFile() async throws {
        guard let path = ProcessInfo.processInfo.environment["YAP_DIARIZE_FILE"]
        else { throw XCTSkip("set YAP_DIARIZE_FILE to measure") }
        let url = URL(fileURLWithPath: path)
        let seconds = Double((try AVAudioFile(forReading: url)).length)
            / (try AVAudioFile(forReading: url)).processingFormat.sampleRate
        let started = Date()
        let result = try await Diarizer.run(url)
        let took = Date().timeIntervalSince(started)
        let order = SpeakerLabeler.order(result.spans)
        var speech: [String: TimeInterval] = [:]
        for span in result.spans { speech[span.cluster, default: 0] += span.end - span.start }
        print(String(format: "measure: %.0f s of audio, %.1f s to diarize, %d voice(s)",
                     seconds, took, order.count))
        for (i, cluster) in order.enumerated() {
            print(String(format: "  them-%d spoke %.0f s", i + 1, speech[cluster] ?? 0))
        }
        XCTAssertFalse(result.spans.isEmpty)
    }
}
