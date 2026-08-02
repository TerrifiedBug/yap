import AVFoundation
import FluidAudio
import Foundation

/// Parakeet TDT via FluidAudio's Core ML port, running on the ANE.
///
/// One actor, one loaded `AsrManager`, both halves of yap: dictation hands it
/// samples straight off the mic ring buffer and wants finished text, a
/// recorded session hands it a file and wants timed segments. Two separate
/// tools used to mean two daemons each holding their own copy of the same
/// few-hundred-megabyte model; sharing this load is the reason they became one
/// binary.
///
/// Unlike Whisper this is a transducer: it emits blank frames for silence
/// rather than hallucinating `[BLANK_AUDIO]` or `(music playing)`, so there is
/// no output sanitizing to do here.
///
/// Models resolve to FluidAudio's machine-global cache, shared with every
/// other FluidAudio client on the machine, so the download happens once per
/// machine rather than once per app.
actor ParakeetTranscriber: Transcriber {
    nonisolated let engineName = "parakeet"
    nonisolated let modelID: String

    private let model: TranscriptionModel
    private var manager: AsrManager?

    init(model: TranscriptionModel) {
        self.modelID = model.id
        self.model = model
    }

    /// FluidAudio rejects anything shorter than
    /// `ASRConstants.minimumAudioDurationSeconds` (0.3 s, 4800 samples at
    /// 16 kHz) with `ASRError.invalidAudioData`. A stray brush of the hotkey
    /// isn't an error — it just has nothing to say. Asking FluidAudio for the
    /// threshold rather than hardcoding it keeps the two in step.
    private static let minimumSamples = ASRConstants.minimumRequiredSamples(
        forSampleRate: ASRConstants.sampleRate
    )

    func warmUp() async throws {
        if manager != nil { return }
        warn("loading \(model.id)...")
        let models = try await AsrModels.downloadAndLoad(version: model.version)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
        await Self.prewarm(manager)
        warn("✓ \(model.id) ready")
    }

    /// Loading the models is not the same as being ready to use them: the
    /// first inference is what finishes the lazy ANE setup, which is exactly
    /// why `yap bench` reports "first" in its own column — it runs 10-60 ms
    /// over the steady-state p50. Without this the daemon prints "ready" and
    /// then charges that cost to the user's first hotkey press.
    ///
    /// Silence of the shortest length FluidAudio accepts: the encoder pads
    /// every clip under 15 s to the same fixed window, so a 0.3 s buffer
    /// exercises precisely the graph a real press will.
    ///
    /// Best-effort. A failure here leaves a perfectly usable loaded model, and
    /// refusing to start over a warm-up would be worse than being slow once.
    ///
    /// `decoderLayers` comes from the loaded model, never the default. The
    /// TDT decoder state is a fixed-shape MLMultiArray sized by layer count —
    /// 2 for the 0.6B checkpoints, 1 for the 110M hybrid — and a mismatch is
    /// not a graceful degradation: CoreML rejects the whole inference with
    /// "MultiArray shape (2 x 1 x 640) does not match the shape (1 x 1 x 640)
    /// specified in the model description". `TdtDecoderState()` defaults to 2,
    /// so hardcoding it silently works until the day a 1-layer model is added
    /// and then fails every single call.
    private static func prewarm(_ manager: AsrManager) async {
        guard var state = try? await TdtDecoderState(decoderLayers: manager.decoderLayerCount)
        else { return }
        _ = try? await manager.transcribe(
            [Float](repeating: 0, count: minimumSamples), decoderState: &state)
    }

    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
    }

    // MARK: - Dictation

    func transcribe(_ audio: [Float]) async throws -> String {
        if manager == nil { try await warmUp() }
        guard let manager else { throw TranscriberError.notLoaded }
        guard audio.count >= Self.minimumSamples else { return "" }

        var state = try await TdtDecoderState(decoderLayers: manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Recorded sessions

    func transcribe(_ file: URL) async throws -> [TranscriptSegment] {
        if manager == nil { try await warmUp() }
        guard let manager else { throw TranscriberError.notLoaded }

        // A track with no frames (recorder died before its first buffer)
        // makes AVFoundation raise an ObjC exception deep inside the
        // resampler — uncatchable from Swift, so it takes the whole daemon
        // down. Check readability up front instead.
        do {
            let probe = try AVAudioFile(forReading: file)
            guard probe.length > 0 else { throw TranscriberError.unreadableAudio(file, nil) }
        } catch let error as TranscriberError {
            throw error
        } catch {
            throw TranscriberError.unreadableAudio(file, error)
        }

        var state = try await TdtDecoderState(decoderLayers: manager.decoderLayerCount)
        let result = try await manager.transcribe(file, decoderState: &state)

        let words = buildWordTimings(from: result.tokenTimings ?? [])
        guard !words.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return [] }
            // Text but no timings. One track collapsing to a single
            // 0..duration span is harmless on its own — that really is all we
            // know — but `TranscriptionCoordinator` orders two tracks against
            // each other by timestamp, so a meeting comes out as one block per
            // speaker instead of a conversation.
            //
            // Said out loud rather than thrown: a throw would fail every track,
            // write no transcript.json, and `resumePending` would then requeue
            // the session at every launch forever. Keeping the text and naming
            // the defect beats losing the recording to a retry loop. A model
            // that can *never* emit timings is a different problem, and belongs
            // in a capability check at selection time.
            //
            // Track name and model id only. Transcripts do not go in logs.
            let warning = "warning: \(modelID) returned no word timings for "
                + "\(file.lastPathComponent) — that track becomes one segment"
            warn(warning)
            return [TranscriptSegment(start: 0, end: result.duration, text: text)]
        }
        return Self.segments(from: words)
    }

    /// Group word timings into readable segments: break on sentence-ending
    /// punctuation (parakeet emits punctuation), a silence gap, or a hard
    /// length cap so a run-on speaker still wraps.
    private static func segments(from words: [WordTiming]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(TranscriptSegment(
                start: first.startTime,
                end: last.endTime,
                text: current.map(\.word).joined(separator: " ")
            ))
            current = []
        }

        for word in words {
            if let last = current.last, word.startTime - last.endTime > 1.0 {
                flush()
            }
            current.append(word)
            let endsSentence = word.word.hasSuffix(".")
                || word.word.hasSuffix("?")
                || word.word.hasSuffix("!")
            if endsSentence || current.count >= 60 {
                flush()
            }
        }
        flush()
        return out
    }
}
