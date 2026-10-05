import AVFoundation
import Foundation

/// The transcript while the recording is still going: `live.jsonl` in the
/// session folder, one JSON object per line, appended as each chunk lands.
///
/// Same model, same actor as dictation and the post-stop pass, so there is
/// still one loaded model. The recorders hand every buffer here as well as to
/// the track file; each track is resampled to 16 kHz mono and accumulated,
/// and a timer that only exists while a session is live cuts a chunk at the
/// quietest moment and transcribes it. A chunk is a few seconds of one
/// speaker, so each call to the model costs what a dictation press costs.
///
/// This is a view of the transcript, not the record. The post-stop pass still
/// runs over the whole track with word timings, and `transcript.md` is what
/// it writes; `live.jsonl` is for whatever wants to read along.
///
/// `@unchecked Sendable` because the audio threads and the timer touch the
/// same accumulators: `lock` is what makes that safe.
final class LiveTranscript: @unchecked Sendable {
    /// One line of `live.jsonl`. Property names are the schema.
    struct Line: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    private final class Track {
        let speaker: String
        var converter: AVAudioConverter?
        var samples: [Float] = []
        /// Samples already cut, so the next chunk knows where it starts.
        var consumed = 0
        /// Wall clock of the first buffer, so chunk times share the session's
        /// clock rather than each track's own.
        var firstBufferAt: Date?

        init(speaker: String) { self.speaker = speaker }
    }

    private let transcriber: any Transcriber
    private let startedAt: Date
    private let url: URL
    private let lock = NSLock()
    private var tracks: [String: Track] = [:]
    private var timer: Timer?
    private var handle: FileHandle?
    /// One transcription pass at a time. A tick that lands while the previous
    /// chunk is still on the ANE waits for the next tick rather than queuing.
    private var inFlight = false
    private var finished = false
    private let encoder = JSONEncoder()

    private static let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(LiveChunker.rate),
        channels: 1,
        interleaved: false
    )!
    /// How often the accumulators are looked at. The cost of a tick that
    /// finds nothing to cut is a lock and two integer compares.
    private static let tickSeconds: TimeInterval = 2

    init(transcriber: any Transcriber, dir: URL, startedAt: Date) {
        self.transcriber = transcriber
        self.startedAt = startedAt
        self.url = dir.appendingPathComponent("live.jsonl")
    }

    /// The buffer sink for one track. Called on that track's audio thread
    /// with buffers in the track's own format; resampled here, appended under
    /// the lock, nothing else.
    func sink(for speaker: String) -> (AVAudioPCMBuffer) -> Void {
        let track = Track(speaker: speaker)
        lock.lock()
        tracks[speaker] = track
        lock.unlock()
        return { [weak self] buffer in
            self?.ingest(buffer, into: track)
        }
    }

    /// Start the timer. After both tracks are recording, so the first tick
    /// has something to look at.
    func start() {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = FileHandle(forWritingAtPath: url.path)
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickSeconds, repeats: true) {
            [weak self] _ in self?.tick(final: false)
        }
    }

    /// Stop the timer and transcribe whatever is left. Called after the
    /// recorders have stopped, so no buffer can arrive behind the final cut.
    func finish() {
        timer?.invalidate()
        timer = nil
        lock.lock()
        finished = true
        lock.unlock()
        tick(final: true)
    }

    // MARK: -

    private func ingest(_ buffer: AVAudioPCMBuffer, into track: Track) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if track.firstBufferAt == nil { track.firstBufferAt = Date() }
        if track.converter?.inputFormat != buffer.format {
            track.converter = AVAudioConverter(from: buffer.format, to: Self.target)
        }
        guard let converter = track.converter else { return }

        let ratio = Self.target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else {
            return
        }
        var consumed = false
        let input: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        var error: NSError?
        let status = converter.convert(to: out, error: &error, withInputFrom: input)
        guard status != .error, let data = out.floatChannelData else { return }
        track.samples.append(
            contentsOf: UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    /// Cut what is ready on every track, then transcribe the cuts off the
    /// timer's thread. The lock is held only for the cut; the model runs
    /// without it so buffers keep landing while a chunk is on the ANE.
    private func tick(final: Bool) {
        lock.lock()
        if inFlight, !final {
            lock.unlock()
            return
        }
        var chunks: [(track: Track, samples: [Float], startMs: Int)] = []
        for track in tracks.values {
            guard let cut = LiveChunker.cut(track.samples, final: final) else { continue }
            let samples = Array(track.samples[..<cut])
            track.samples.removeFirst(cut)
            let origin = track.firstBufferAt ?? startedAt
            let offsetMs = Int(origin.timeIntervalSince(startedAt) * 1000)
            let startMs = offsetMs + track.consumed * 1000 / LiveChunker.rate
            track.consumed += cut
            chunks.append((track, samples, startMs))
        }
        guard !chunks.isEmpty else {
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()

        Task { [self] in
            for chunk in chunks.sorted(by: { $0.startMs < $1.startMs }) {
                let endMs = chunk.startMs + chunk.samples.count * 1000 / LiveChunker.rate
                // Digital silence — the far side while you talk — costs an
                // inference and returns nothing. Skip it before the model.
                guard !LiveChunker.isSilent(chunk.samples) else { continue }
                let text: String
                do {
                    text = try await transcriber.transcribe(chunk.samples)
                } catch {
                    warn("live transcript: chunk failed: \(error)")
                    continue
                }
                guard !text.isEmpty else { continue }
                append(Line(
                    speaker: chunk.track.speaker, start_ms: chunk.startMs, end_ms: endMs, text: text))
            }
            clearInFlight()
        }
    }

    /// Synchronous on purpose: `NSLock` is off limits inside an async
    /// context, and this is the one touch the transcription task makes.
    private func clearInFlight() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }

    private func append(_ line: Line) {
        guard let data = try? encoder.encode(line) else { return }
        lock.lock()
        defer { lock.unlock() }
        handle?.write(data + Data("\n".utf8))
    }
}

/// Where to cut a growing buffer of one speaker. Pure, so it can be tested
/// on arrays rather than on a microphone.
///
/// Three rules, in order. Under three seconds, nothing: the model pads every
/// clip to a fixed window anyway, and a chunk that short is not worth a trip
/// to the ANE. A quiet tail — the speaker paused — takes everything, which is
/// what makes a question land in the transcript as soon as it is asked. Past
/// ten seconds with no pause, the quietest 300 ms in the last three seconds
/// is the least bad place to break a word, and it is where the break goes.
enum LiveChunker {
    static let rate = 16_000
    static let minSeconds = 3.0
    static let targetSeconds = 10.0
    /// A tail this long under `pauseRMS` is a pause, not a breath.
    static let pauseSeconds = 0.6
    /// Room noise on a voice-processed mic sits an order of magnitude below
    /// this; speech an order of magnitude above. A raw mic in a loud room
    /// never pauses by this measure and falls through to the ten-second cut,
    /// which is a worse split, not a lost chunk.
    static let pauseRMS: Float = 0.005
    static let windowSeconds = 0.3
    static let searchSeconds = 3.0
    /// Below this peak a chunk carries nothing the model could hear.
    static let silentPeak: Float = 0.003

    static func cut(_ samples: [Float], final: Bool) -> Int? {
        let n = samples.count
        if final { return n > 0 ? n : nil }
        guard n >= Int(minSeconds * Double(rate)) else { return nil }

        let tail = Int(pauseSeconds * Double(rate))
        if rms(samples[(n - tail)...]) < pauseRMS { return n }

        guard n >= Int(targetSeconds * Double(rate)) else { return nil }
        return quietestWindowEnd(samples)
    }

    /// The end of the quietest `windowSeconds` span inside the last
    /// `searchSeconds`, so the cut lands after the lull rather than in it.
    static func quietestWindowEnd(_ samples: [Float]) -> Int {
        let n = samples.count
        let window = Int(windowSeconds * Double(rate))
        let from = max(0, n - Int(searchSeconds * Double(rate)))
        var best = n
        var bestEnergy = Float.greatestFiniteMagnitude
        var start = from
        while start + window <= n {
            let energy = rms(samples[start..<(start + window)])
            if energy < bestEnergy {
                bestEnergy = energy
                best = start + window
            }
            start += window / 2
        }
        return best
    }

    static func isSilent(_ samples: [Float]) -> Bool {
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        return peak < silentPeak
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for s in samples { sum += Double(s * s) }
        return Float((sum / Double(samples.count)).squareRoot())
    }
}
