import AVFoundation
import XCTest

@testable import yap

/// The whole live path on real speech: buffers in through the recorder sink,
/// the timer cutting chunks, the model transcribing them, lines landing in
/// `live.jsonl` while audio is still arriving.
///
/// Needs the default model on disk and `say` for the speech, so it skips on
/// a runner that has neither. Everything else in the suite runs without a
/// model; this one is the proof that the pieces fit.
final class LiveTranscriptTests: XCTestCase {
    func testChunksLandWhileAudioIsStillArriving() throws {
        guard let model = ModelRegistry.find("parakeet-tdt-ctc-110m"), ModelStore.isDownloaded(model)
        else { throw XCTSkip("default model not downloaded") }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yap-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let speech = dir.appendingPathComponent("speech.caf")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-o", speech.path, "--data-format=LEF32@16000",
            "Right, so the main thing from my side this week is the migration. "
                + "We have moved the hot tier across and the dashboards are up, "
                + "but the alert rules still need porting and that is next sprint. "
                + "The one risk is the index moves, which need a change window.",
        ]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("say unavailable") }

        let file = try AVAudioFile(forReading: speech)
        let transcriber = model.makeTranscriber()
        let warm = expectation(description: "model warm")
        Task {
            try await transcriber.warmUp()
            warm.fulfill()
        }
        wait(for: [warm], timeout: 120)

        let live = LiveTranscript(transcriber: transcriber, dir: dir, startedAt: Date())
        let sink = live.sink(for: "me")
        live.start()

        // Feed a second at a time, the way a tap would, and let the timer run
        // between helpings. Twelve seconds in, a chunk must already be on
        // disk — that is the whole point of the feature.
        let second = AVAudioFrameCount(file.processingFormat.sampleRate)
        func feed(seconds: Int) throws {
            for _ in 0..<seconds where file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: second)
                else { return }
                try file.read(into: buffer, frameCount: second)
                guard buffer.frameLength > 0 else { return }
                sink(buffer)
            }
        }
        let url = dir.appendingPathComponent("live.jsonl")
        func lines() -> [LiveTranscript.Line] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap {
                try? JSONDecoder().decode(LiveTranscript.Line.self, from: Data($0.utf8))
            }
        }
        func spin(until done: () -> Bool, limit: TimeInterval) {
            let deadline = Date().addingTimeInterval(limit)
            while !done(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }

        try feed(seconds: 12)
        spin(until: { !lines().isEmpty }, limit: 15)
        let early = lines()
        XCTAssertFalse(early.isEmpty, "a chunk lands before the audio has finished arriving")

        try feed(seconds: 30)
        live.finish()
        spin(until: { lines().count > early.count }, limit: 15)

        let all = lines()
        XCTAssertGreaterThan(all.count, early.count, "the final flush adds the tail")
        XCTAssertTrue(all.allSatisfy { $0.speaker == "me" })
        XCTAssertEqual(all.map(\.start_ms), all.map(\.start_ms).sorted())
        XCTAssertTrue(all.allSatisfy { $0.end_ms > $0.start_ms })
        let text = all.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("migration"), "heard the speech: \(text)")
        XCTAssertTrue(text.contains("change window"), "heard the tail: \(text)")

        let release = expectation(description: "model released")
        Task {
            await transcriber.release()
            release.fulfill()
        }
        wait(for: [release], timeout: 30)
    }
}
