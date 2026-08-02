import AVFoundation
import CoreAudio
import Foundation

/// Records all system audio output to a file via a Core Audio process tap
/// (macOS 14.2+). No virtual device, no kernel extension — the tap mixes every
/// process's output to stereo and hands us buffers through a private aggregate
/// device. First use triggers the one-time "System Audio Recording" TCC prompt
/// and lights the purple recording indicator while active.
final class SystemAudioRecorder {
    enum RecorderError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case tapFormatUnreadable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case fileCreationFailed(Error)

        var description: String {
            switch self {
            case .tapCreationFailed(let s):
                return "process tap creation failed (OSStatus \(s)) — check System Settings → Privacy & Security → Screen & System Audio Recording"
            case .tapFormatUnreadable(let s): return "couldn't read tap stream format (OSStatus \(s))"
            case .aggregateCreationFailed(let s): return "aggregate device creation failed (OSStatus \(s))"
            case .ioProcCreationFailed(let s): return "IO proc creation failed (OSStatus \(s))"
            case .deviceStartFailed(let s): return "device start failed (OSStatus \(s))"
            case .fileCreationFailed(let e): return "output file creation failed: \(e)"
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "com.terrifiedbug.yap.system-tap")
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?

    /// Start capturing system audio, encoding AAC into `url` (use a .caf
    /// extension — CAF needs no finalization pass, so a crash mid-meeting
    /// loses nothing already written).
    func start(writingTo url: URL) throws {
        guard !isRecording else { return }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "yap system tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw RecorderError.tapCreationFailed(status) }
        tapID = newTapID

        do {
            let format = try tapStreamFormat()
            try createAggregateDevice(tapUUID: description.uuid)
            file = try makeFile(url: url, format: format)
            try installIOProc(format: format)
        } catch {
            cleanup()
            throw error
        }

        isRecording = true
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
        }
        // AudioDeviceStop schedules no further IOProc blocks but does not wait
        // for one already running. Draining the queue keeps cleanup() from
        // releasing `file` mid-write, and publishes `firstBufferAt` to main.
        queue.sync {}
        cleanup()
    }

    // MARK: -

    private func tapStreamFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.tapFormatUnreadable(status)
        }
        return format
    }

    private func createAggregateDevice(tapUUID: UUID) throws {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "yap-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAggregateID)
        guard status == noErr else { throw RecorderError.aggregateCreationFailed(status) }
        aggregateID = newAggregateID
    }

    private func makeFile(url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        do {
            return try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
    }

    private func installIOProc(format: AVAudioFormat) throws {
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else { return }
            do {
                try file.write(from: buffer)
            } catch {
                warn("system track write failed: \(error)")
            }
        }
        guard status == noErr, let procID else { throw RecorderError.ioProcCreationFailed(status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw RecorderError.deviceStartFailed(status) }
    }

    private func cleanup() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        file = nil
    }
}
