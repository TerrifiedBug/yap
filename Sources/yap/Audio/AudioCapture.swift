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
    }

    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
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
        let inputFormat = input.outputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterCreationFailed
        }
        self.converter = converter

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

        // Tap with input format; convert inside the callback.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: converter, targetFormat: targetFormat)
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

    private func process(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
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
