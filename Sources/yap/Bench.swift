import AVFoundation
import ArgumentParser
import Foundation

/// Measure post-release transcription latency — the number that actually
/// matters for push-to-talk, and the one no public benchmark reports.
///
/// Published RTFx figures describe long-audio throughput over hours of
/// LibriSpeech. A dictation press is 2-10 seconds, and the encoder pads short
/// clips out to a fixed window (15 s in FluidAudio's Parakeet port, see
/// `ASRConstants.maxModelSamples`), so throughput tells you almost nothing
/// about the delay you feel between releasing the hotkey and seeing text land
/// at the cursor. This measures that delay directly, feeding every model
/// byte-identical audio so the comparison is between models and nothing else.
struct Bench: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Time transcription latency across models on identical audio."
    )

    @Option(
        name: .long,
        help: "Audio file to transcribe. One of --audio or --corpus is required.")
    var audio: String?

    @Option(
        name: .long,
        help: """
            LibriSpeech-layout directory (*.flac beside *.trans.txt). Scores \
            word error rate against the reference transcripts instead of \
            timing one clip repeatedly.
            """
    )
    var corpus: String?

    @Option(name: .long, help: "Cap how many corpus files are scored.")
    var maxFiles: Int?

    @Option(name: .long, help: "Timed runs per model, after one untimed warm-up run.")
    var iterations: Int = 5

    @Option(name: .long, help: "Comma-separated model ids. Defaults to every downloaded model.")
    var models: String?


    func run() throws {
        if let corpus {
            try runCorpus(directory: corpus)
            return
        }
        guard let audio else {
            throw ValidationError("pass --audio FILE or --corpus DIR")
        }
        try runSingle(audio: audio)
    }

    private func runSingle(audio: String) throws {
        let samples = try AudioFileLoader.load(path: audio)
        let seconds = Double(samples.count) / AudioCapture.targetSampleRate
        let selected = try resolveModels()

        print(
            String(
                format: "audio   %@  (%.2fs, %d samples @ 16 kHz)",
                (audio as NSString).lastPathComponent, seconds, samples.count
            ))
        print("runs    \(iterations) timed per model, after 1 untimed warm-up")
        print("")
        print("model                       load    first    min     p50     max    xRT")
        print("-------------------------------------------------------------------------")

        let iterations = self.iterations
        try runBlocking {
            for model in selected {
                try await Self.measure(
                    model.id, model.makeTranscriber(),
                    samples: samples, iterations: iterations, audioSeconds: seconds)
            }
        }
    }

    // MARK: - Corpus scoring

    /// Score every model against reference transcripts. Latency on one clip
    /// says nothing about whether a model heard the words correctly, and a
    /// single misheard proper noun is an anecdote, so accuracy needs a corpus
    /// with ground truth behind it.
    private func runCorpus(directory: String) throws {
        var files = try Self.libriSpeechFiles(in: URL(fileURLWithPath: directory))
        guard !files.isEmpty else {
            throw ValidationError("no *.trans.txt with matching audio under \(directory)")
        }
        files.sort { $0.id < $1.id }
        if let maxFiles, files.count > maxFiles {
            files = Array(files.prefix(maxFiles))
        }

        let scored = files
        let totalAudio = scored.reduce(0.0) { $0 + $1.seconds }
        print("corpus  \(scored.count) files, \(String(format: "%.1f", totalAudio / 60)) min of audio")
        print("")
        print("model                        WER     errors/words    audio/s    xRT")
        print("----------------------------------------------------------------------")

        let selected = try resolveModels()
        try runBlocking {
            for model in selected {
                try await Self.score(model.id, model.makeTranscriber(), files: scored)
            }
        }
    }

    private struct Reference {
        let id: String
        let path: URL
        let words: [String]
        let seconds: Double
    }

    private static func score(
        _ label: String, _ transcriber: any Transcriber, files: [Reference]
    ) async throws {
        try await transcriber.warmUp()

        var edits = 0
        var words = 0
        var elapsed = 0.0
        var audio = 0.0
        // (clip seconds, transcribe seconds) per file, so latency can be
        // reported across independent recordings rather than as repeats of
        // one clip. Timing the same prefix seven times measures jitter; this
        // measures how the model behaves on audio it has not seen.
        var timings: [(seconds: Double, took: Double)] = []
        timings.reserveCapacity(files.count)

        for file in files {
            let samples = try AudioFileLoader.load(path: file.path.path)
            let start = Date()
            let text = try await transcriber.transcribe(samples)
            let took = Date().timeIntervalSince(start)
            elapsed += took
            audio += file.seconds
            timings.append((file.seconds, took))

            edits += Self.editDistance(normalize(text), file.words)
            words += file.words.count
        }
        await transcriber.release()

        let wer = words == 0 ? 0 : Double(edits) / Double(words) * 100
        print(
            String(
                format: "%@ %6.2f%%  %6d/%-7d  %8.1f  %6.1fx",
                pad(label, 26),
                wer, edits, words, elapsed, audio / elapsed
            ))
        printBuckets(timings)
    }

    /// Median and p95 transcribe time per clip-length bucket, each drawn from
    /// different recordings.
    private static func printBuckets(_ timings: [(seconds: Double, took: Double)]) {
        let bounds: [(String, Range<Double>)] = [
            ("  0-5s", 0..<5), ("  5-10s", 5..<10), (" 10-15s", 10..<15),
            (" 15-20s", 15..<20), (" 20-30s", 20..<30), ("   30s+", 30..<Double.infinity),
        ]
        for (name, range) in bounds {
            let hits = timings.filter { range.contains($0.seconds) }.map { $0.took }.sorted()
            guard hits.count >= 3 else { continue }
            let median = hits[hits.count / 2] * 1000
            let p95 = hits[min(hits.count - 1, Int(Double(hits.count) * 0.95))] * 1000
            print(
                String(
                    format: "    %@  n=%-4d  p50 %5.0f ms   p95 %5.0f ms",
                    name, hits.count, median, p95))
        }
    }

    /// Uppercase, drop everything that is not a letter, digit or space, and
    /// split. LibriSpeech references are already written that way, so this
    /// only has to bring the hypothesis in line: the models emit punctuation
    /// and casing that the reference does not have, and scoring those as
    /// errors would measure formatting rather than recognition.
    private static func normalize(_ text: String) -> [String] {
        text.uppercased()
            .map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map(String.init)
    }

    /// Levenshtein over words, two rows rather than a full matrix.
    private static func editDistance(_ hypothesis: [String], _ reference: [String]) -> Int {
        if reference.isEmpty { return hypothesis.count }
        if hypothesis.isEmpty { return reference.count }

        var previous = Array(0...reference.count)
        var current = [Int](repeating: 0, count: reference.count + 1)

        for (i, hypothesisWord) in hypothesis.enumerated() {
            current[0] = i + 1
            for (j, referenceWord) in reference.enumerated() {
                let substitution = previous[j] + (hypothesisWord == referenceWord ? 0 : 1)
                current[j + 1] = min(substitution, previous[j + 1] + 1, current[j] + 1)
            }
            swap(&previous, &current)
        }
        return previous[reference.count]
    }

    /// Walk a LibriSpeech tree: each `*.trans.txt` holds `ID TRANSCRIPT` per
    /// line, with the audio beside it as `ID.flac`.
    private static func libriSpeechFiles(in root: URL) throws -> [Reference] {
        var out: [Reference] = []
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return out
        }

        for case let url as URL in walker where url.lastPathComponent.hasSuffix(".trans.txt") {
            let contents = try String(contentsOf: url, encoding: .utf8)
            for line in contents.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let id = String(parts[0])
                let audio = url.deletingLastPathComponent().appendingPathComponent("\(id).flac")
                guard manager.fileExists(atPath: audio.path) else { continue }
                guard let handle = try? AVAudioFile(forReading: audio) else { continue }
                out.append(
                    Reference(
                        id: id,
                        path: audio,
                        words: normalize(String(parts[1])),
                        seconds: Double(handle.length) / handle.fileFormat.sampleRate
                    ))
            }
        }
        return out
    }

    private func resolveModels() throws -> [TranscriptionModel] {
        guard let models else {
            let downloaded = ModelRegistry.shared.filter { ModelStore.isDownloaded($0) }
            guard !downloaded.isEmpty else {
                throw ValidationError("no models downloaded — run `yap models download <id>`")
            }
            return downloaded
        }
        return try models.split(separator: ",").map {
            let id = $0.trimmingCharacters(in: .whitespaces)
            guard let model = ModelRegistry.find(id) else {
                throw ValidationError("unknown model: \(id)")
            }
            return model
        }
    }

    private static func measure(
        _ label: String,
        _ transcriber: any Transcriber,
        samples: [Float],
        iterations: Int,
        audioSeconds: Double
    ) async throws {

        let loadStart = Date()
        try await transcriber.warmUp()
        let load = Date().timeIntervalSince(loadStart)

        // The first inference finishes lazy ANE setup, so it is reported
        // separately rather than polluting the steady-state sample.
        let firstStart = Date()
        let text = try await transcriber.transcribe(samples)
        let first = Date().timeIntervalSince(firstStart)

        var timings: [TimeInterval] = []
        timings.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = Date()
            _ = try await transcriber.transcribe(samples)
            timings.append(Date().timeIntervalSince(start))
        }
        timings.sort()

        // Each model is a few hundred MB on the ANE; hold one at a time or a
        // multi-model run measures memory pressure as much as latency.
        await transcriber.release()

        let median = timings[timings.count / 2]
        let name = pad(label, 24)
        print(
            String(
                format: "%@ %6.2fs %6.0fms %6.0fms %6.0fms %6.0fms %5.1fx",
                name, load, first * 1000, timings[0] * 1000, median * 1000,
                timings[timings.count - 1] * 1000, audioSeconds / median
            ))
        print("    \u{201C}\(text)\u{201D}")
    }
}

enum AudioFileLoader {
    enum LoadError: Error, CustomStringConvertible {
        case unsupported(String)

        var description: String {
            switch self {
            case .unsupported(let path): return "cannot decode audio at \(path)"
            }
        }
    }

    /// Decode any AVFoundation-readable file to the 16 kHz mono Float32 the
    /// engine expects, so each model sees byte-identical input.
    static func load(path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioCapture.targetSampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { throw LoadError.unsupported(path) }

        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(file.length) * ratio) + 4096
        guard
            let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity),
            let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else { throw LoadError.unsupported(path) }

        try file.read(into: input)

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }

        guard let channel = output.floatChannelData?[0] else { throw LoadError.unsupported(path) }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
