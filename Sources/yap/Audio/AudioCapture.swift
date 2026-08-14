import AVFoundation
import Foundation

/// Dictation's microphone tap: captures while the hotkey is held and returns
/// the whole press as one 16 kHz mono Float32 buffer when released.
/// Format-converts on the fly so callers don't have to worry about the input
/// device's native rate.
///
/// Deliberately not the same type as `MicRecorder`, which serves the recording
/// half of the app. A dictation press is seconds long and its samples are
/// handed straight to the transcriber, so they stay in memory and never touch
/// disk; a session is unbounded and streams to an encoded file it never holds.
/// Merging the two would mean one of the halves paying for the other's
/// constraints — a file write per dictation press, or a session capped by RAM.
final class AudioCapture {
    enum CaptureError: Error {
        case engineStartFailed(Error)
        case converterCreationFailed
        case noInputDevice
    }

    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var isRecording = false
    /// Whether this press muted the speakers, so stop() releases exactly what
    /// start() took regardless of the config changing in between.
    private var mutedOutput = false
    private let lock = NSLock()

    /// Called for every audio buffer with the buffer's RMS level (0…~1).
    /// Invoked on an arbitrary thread; hop to main if you touch UI.
    var onLevel: ((Float) -> Void)?

    /// Begin recording. Idempotent — calling while already recording is a no-op.
    func start() throws {
        guard !isRecording else { return }

        let input = engine.inputNode
        // Reading the format can raise an ObjC exception on a disconnected or
        // reconfiguring device, and that aborts the process rather than
        // unwinding, so `defer` never runs. Nothing that has to be undone may
        // be set up before this line: the mic gain lease is taken after it.
        //
        // What it answers is not necessarily true. An engine's input node keeps
        // the format it was built against and does not follow a route change:
        // measured on this machine with AirPods Max as the default input, a
        // brand-new engine in a brand-new process answered 48000 Hz while the
        // device was at 24000 Hz — so the value is only good enough to size a
        // converter with, never to hand to `installTap`. See the tap below.
        let inputFormat = input.outputFormat(forBus: 0)
        // A device that has gone away answers zero, and everything downstream
        // of it — the converter, the tap, the press — is then a slower way of
        // returning nothing.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        // Seeded from the node's format, then corrected by the buffers.
        //
        // Necessary because of the staleness above: tapping with `format: nil`
        // means the buffers arrive in the bus's real format, which is exactly
        // the format the node may have lied about. Converting them with a
        // converter built from the lie fails on every buffer, and a press that
        // silently returns no samples is the same bug wearing a quieter coat.
        // Seeding it here anyway keeps the common press — where the node told
        // the truth — from allocating a converter on the audio thread.
        guard let seed = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterCreationFailed
        }
        let converters = ConverterCache(target: targetFormat, seed: seed)

        // A mic left turned down costs more accuracy than any model choice.
        // Released in stop(), or here if the engine fails to start, since
        // stop() bails on !isRecording.
        InputGain.raiseIfQuiet()
        // Before the engine starts, so nothing playing is captured at all.
        // Muting after the mic opens still leaves the opening moments in the
        // buffer, which is the part a transcript notices.
        //
        // Remembered on the instance rather than re-read in stop(): the config
        // file can be saved mid-press, and deciding to release by reading the
        // setting again would leave the speakers muted for good if it had just
        // been turned off.
        mutedOutput = Config.muteOutputWhileDictating()
        if mutedOutput { OutputMute.acquire() }
        var started = false
        defer { if !started { releaseAudioLeases() } }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        // `format: nil` — the bus's own format, not the one read above.
        //
        // This is not a tidiness preference, it is the whole reason this file
        // was touched. Handing `installTap` a format the bus is not in raises
        // 'Failed to create tap due to format mismatch' from Core Audio, and
        // that is an ObjC exception: it unwinds through Swift frames that
        // cannot catch it, so the press does not fail — the daemon aborts.
        // launchd restarts it and it reloads the model, which from the outside
        // is a menu bar icon that vanishes whenever you press the key and a mic
        // that never records. It took 18 aborts on one machine, all of them
        // logging the mismatched pair, before anyone read the log: node at
        // 48000 Hz, AirPods Max default input at 24000 Hz. Nothing we can name
        // is more current than the bus itself at the instant the tap is made.
        //
        // Rejected, with a number: building a fresh engine per press so the
        // node always matches the current device. `AVAudioEngine()` plus the
        // first `inputNode` access measured a p50 of 593 ms on an M4 with a
        // Bluetooth input attached (140 ms to 1.6 s across seven runs) — that
        // cost belongs where it is today, once at daemon start, and never on a
        // key-down with a 500 ms budget.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.process(buffer: buffer, converters: converters)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }

        isRecording = true
        started = true
    }

    /// Stop recording and return all captured samples (16 kHz mono Float32).
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        releaseAudioLeases()
        isRecording = false

        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return captured
    }

    /// Put back everything start() borrowed from the system. Both leases are
    /// counted, so calling this on a path that never took one is a no-op —
    /// which is what makes it safe on every early exit.
    private func releaseAudioLeases() {
        InputGain.restorePrevious()
        if mutedOutput {
            OutputMute.release()
            mutedOutput = false
        }
    }

    /// A tap's block is called serially on one thread and this cache is reached
    /// from nowhere else — that, not a lock, is what makes it safe. Do not
    /// promote it to a property: as an instance property it would be read on the
    /// audio thread while `stop()` cleared it on the main one.
    private final class ConverterCache {
        let target: AVAudioFormat
        private var converter: AVAudioConverter

        init(target: AVAudioFormat, seed: AVAudioConverter) {
            self.target = target
            self.converter = seed
        }

        /// The converter for `format`, rebuilt only when the buffers turn out to
        /// be in a format the last one cannot take — once per press at worst,
        /// and on the common route never.
        func converter(for format: AVAudioFormat) -> AVAudioConverter? {
            if converter.inputFormat == format { return converter }
            guard let rebuilt = AVAudioConverter(from: format, to: target) else { return nil }
            converter = rebuilt
            return rebuilt
        }
    }

    private func process(
        buffer: AVAudioPCMBuffer,
        converters: ConverterCache
    ) {
        guard let converter = converters.converter(for: buffer.format) else { return }
        let targetFormat = converters.target

        // Output buffer capacity scales with sample-rate ratio.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64

        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outCapacity
        ) else { return }

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, let channelData = outBuffer.floatChannelData else { return }

        let count = Int(outBuffer.frameLength)
        let ptr = channelData[0]
        let chunk = Array(UnsafeBufferPointer(start: ptr, count: count))

        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        if let onLevel {
            onLevel(computeRMS(chunk))
        }
    }
}

func computeRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Double = 0
    for s in samples { sum += Double(s * s) }
    return Float((sum / Double(samples.count)).squareRoot())
}
