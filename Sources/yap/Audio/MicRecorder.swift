import AVFoundation
import Foundation

/// The recording half's microphone track: records the default input device to
/// a file via AVAudioEngine, encoding AAC mono. Buffers stream straight to
/// disk — nothing is held in memory, so session length is unbounded.
///
/// Separate from `AudioCapture`, which taps the same mic for dictation, because
/// the two want opposite things from a tap. This one runs for an hour, encodes
/// as it goes and pairs with a system-audio track, so it needs voice processing
/// to keep the far side out of the mic; dictation runs for seconds, wants raw
/// 16 kHz Float32 in memory for the transcriber, and would only pay latency for
/// the echo canceller and the file. One type doing both would be the union of
/// both sets of constraints.
///
/// With voice processing on (the default), Apple's echo canceller subtracts
/// speaker playback from the mic so the system track doesn't bleed into the
/// mic track. VoiceProcessingIO is a duplex unit, not an input effect: it
/// needs a rendered output path and one explicit mono client format on both
/// sides, or it silently delivers zeroed buffers. A first-second liveness
/// check catches routes where even the correct graph stays silent and
/// restarts capture raw.
///
/// `@unchecked Sendable` because the tap callback and main touch the same
/// state from different threads: `lock` below is what makes that safe, not an
/// assumption that it never happens.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            }
        }
    }

    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var url: URL?
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?

    // Liveness check state (voice-processing path only). Written from the tap
    // callback, read on main when deciding to fall back.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false

    /// Guards every field a tap callback touches: `file`, `firstBufferAt` and
    /// the three liveness counters. Tap callbacks run on an AVAudioEngine
    /// internal thread while main is free to be inside `stop()` or
    /// `fallBackToRaw()`. Held across `file.write(from:)` on purpose — that is
    /// what makes `stop()` wait out an in-flight write instead of releasing
    /// the file underneath it. `isRecording` and `url` are main-only.
    private let lock = NSLock()

    /// Start capturing the mic, encoding AAC into `url` (use a .caf extension
    /// — CAF needs no finalization pass, so a crash loses nothing written).
    func start(writingTo url: URL, voiceProcessing: Bool = Config.micVoiceProcessing()) throws {
        guard !isRecording else { return }
        self.url = url
        // Same reason as dictation. Restored in stop(), or here if attach
        // throws, since stop() bails on !isRecording.
        InputGain.raiseIfQuiet()
        var started = false
        defer { if !started { InputGain.restorePrevious() } }

        try attach(voiceProcessing: voiceProcessing)
        isRecording = true
        started = true
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        InputGain.restorePrevious()
        // After removeTap, but a callback already dispatched can still be
        // mid-write; the lock waits it out before the file goes away.
        lock.lock()
        file = nil
        lock.unlock()
    }

    // MARK: -

    /// Build the engine graph, create the AAC file, and start capture. Called
    /// once at start, and a second time (voiceProcessing: false) if the
    /// liveness check trips.
    private func attach(voiceProcessing: Bool) throws {
        engine = AVAudioEngine()
        let input = engine.inputNode

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                warn("warning: mic voice processing unavailable (\(error)) — recording raw mic")
                voice = false
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)

        // One explicit mono client format. With voice processing this is the
        // Voice I/O boundary format on both sides of the duplex unit — never
        // accept the inherited multichannel route format (a 9-channel device
        // yielded digital silence). Raw capture downmixes to the same shape;
        // speech models want one channel anyway.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: monoFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            let created = try AVAudioFile(
                forWriting: url!,
                settings: settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
            lock.lock()
            file = created
            lock.unlock()
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            lock.lock()
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            lock.unlock()
            installVoiceTap(on: input, format: monoFormat)
        } else {
            try installRawTap(on: input, inputFormat: inputFormat, monoFormat: monoFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock()
            file = nil
            lock.unlock()
            throw RecorderError.engineStartFailed(error)
        }

        let report = "mic: voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat)"
        warn(report)
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the file. Tracks signal
    /// peak over the first second — an unsupported route (device pair, macOS
    /// AUVPAggregate defects) delivers callbacks full of digital zeros, and
    /// the only recovery is restarting raw.
    private func installVoiceTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let checkFrames = Int(format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Held for the whole callback, write included: main can be inside
            // stop() or fallBackToRaw() releasing `file` and resetting these
            // counters at any moment. fallBackToRaw is dispatched async below,
            // so the lock is never held while waiting on main.
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }

            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        self.livenessPeak = max(self.livenessPeak, abs(data[i]))
                    }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        DispatchQueue.main.async { self.fallBackToRaw() }
                        return
                    }
                }
            }

            do {
                try file.write(from: buffer)
            } catch {
                warn("mic track write failed: \(error)")
            }
        }
    }

    /// Raw path: tap at the device's native format and downmix to mono. Same
    /// sample rate on both sides, so the one-shot convert applies.
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        monoFormat: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Same contract as the voice tap: `file` is main-mutated.
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            guard let mono = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: buffer.frameCapacity
            ) else { return }
            do {
                try converter.convert(to: mono, from: buffer)
                try file.write(from: mono)
            } catch {
                warn("mic track write failed: \(error)")
            }
        }
    }

    /// The voice-processing route delivered a full second of digital silence:
    /// tear the engine down and restart raw, discarding the silent prefix so
    /// the track's timestamps start at real audio.
    private func fallBackToRaw() {
        guard isRecording else { return }
        warn("warning: voice processing delivered silence — restarting mic raw")
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        lock.lock()
        file = nil
        firstBufferAt = nil
        lock.unlock()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try attach(voiceProcessing: false)
        } catch {
            warn("mic raw fallback failed: \(error) — session continues without mic track")
            lock.lock()
            file = nil
            lock.unlock()
        }
    }
}
