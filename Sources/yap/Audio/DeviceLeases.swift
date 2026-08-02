import CoreAudio
import Foundation

/// Scalar Core Audio device properties, read and written the same way every
/// time. Both leases below need the same get/set/settable dance, and it was
/// written out once per lease before.
///
/// Deliberately not `MeetingDetector`'s Core Audio helpers: those read global
/// system objects — the process list, the device list — and answer nil by
/// logging once and giving up, because they run every second forever. These
/// read one named device on a keypress and let the caller decide.
enum AudioDevice {
    /// A property on a device, in one scope. Passed by value everywhere
    /// below: the API wants a pointer but only reads through it, so each call
    /// takes its own copy rather than sharing a mutable static.
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// The system's current default input or output, or nil if there isn't
    /// one — no device, or Core Audio still settling after a hot-unplug.
    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = address(selector, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// Read a scalar property, or nil if the device does not carry it.
    ///
    /// Two named pairs rather than one generic: a generic wide enough to hold
    /// an object reference cannot take a raw pointer to its value without the
    /// compiler objecting, correctly.
    static func float32(
        _ device: AudioDeviceID, _ address: AudioObjectPropertyAddress
    ) -> Float32? {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func uint32(
        _ device: AudioDeviceID, _ address: AudioObjectPropertyAddress
    ) -> UInt32? {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    /// Write a scalar property. False when the device refuses, which plenty
    /// do: aggregates, virtual devices and some USB interfaces expose a
    /// property as readable and not settable.
    @discardableResult
    static func set(
        _ value: Float32, _ device: AudioDeviceID, _ address: AudioObjectPropertyAddress
    ) -> Bool {
        var value = value
        return write(&value, MemoryLayout<Float32>.size, device, address)
    }

    @discardableResult
    static func set(
        _ value: UInt32, _ device: AudioDeviceID, _ address: AudioObjectPropertyAddress
    ) -> Bool {
        var value = value
        return write(&value, MemoryLayout<UInt32>.size, device, address)
    }

    private static func write(
        _ value: UnsafeMutableRawPointer, _ size: Int,
        _ device: AudioDeviceID, _ address: AudioObjectPropertyAddress
    ) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
            settable.boolValue
        else { return false }

        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(size), value) == noErr
    }
}

/// A device setting borrowed for the length of a capture and handed back
/// afterwards, counted so overlapping captures nest.
///
/// Dictation and a recorded session can be live at the same time, so this is a
/// counted lease: the first capture changes the device, the last one puts it
/// back. A single slot would let whichever finished first restore the old
/// value underneath the other, and leave the second with nothing to restore.
///
/// `take` runs only for the first lease, and only its non-nil result is
/// remembered. A take that finds nothing to do — no device, a setting already
/// where we want it, a device that refuses the write — still counts as a
/// lease, so the matching release balances it and restores nothing. That is
/// what makes `release()` safe on every early exit out of a capture,
/// including the ones that throw.
///
/// `@unchecked Sendable` because the lock is what makes the shared state safe,
/// not the compiler. Both callbacks run under it, exactly as the inline
/// versions of this did.
final class DeviceLease<State: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var leases = 0
    private var saved: (device: AudioDeviceID, state: State)?

    func acquire(_ take: () -> (AudioDeviceID, State)?) {
        lock.lock()
        defer { lock.unlock() }

        leases += 1
        guard leases == 1, saved == nil else { return }
        saved = take()
    }

    func release(_ restore: (AudioDeviceID, State) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard leases > 0 else { return }
        leases -= 1
        guard leases == 0, let saved else { return }
        self.saved = nil
        restore(saved.device, saved.state)
    }
}

/// Raises a turned-down microphone for the duration of a capture.
///
/// macOS remembers input gain per device, and a mic left at 13% is the single
/// largest accuracy factor measured anywhere in this project: upstream saw
/// word accuracy go from 84.8% to 94.7% purely by raising it. No model change
/// comes close. A quiet mic is also invisible, since the waveform still moves
/// and the transcript still returns words, just the wrong ones.
///
/// Only touches the device when it is below `floor`, so a deliberately tuned
/// setup is left alone, and always puts the previous value back.
enum InputGain {
    /// Below this, the mic is quiet enough to cost accuracy.
    private static let floor: Float32 = 0.5
    /// Measured sweet spot upstream. High enough to hear, short of clipping.
    private static let target: Float32 = 0.7

    private static let lease = DeviceLease<Float32>()
    private static let gain = AudioDevice.address(
        kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput)

    /// Take a lease, raising the default input if it is below the floor.
    static func raiseIfQuiet() {
        lease.acquire {
            guard
                let device = AudioDevice.defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
                let current = AudioDevice.float32(device, gain),
                current < floor,
                AudioDevice.set(target, device, gain)
            else { return nil }

            warn(
                String(
                    format: "mic gain %.0f%% is low — raised to %.0f%% while capturing",
                    current * 100, target * 100))
            return (device, current)
        }
    }

    /// Release a lease. The last one out puts the user's gain back.
    static func restorePrevious() {
        lease.release { device, previous in
            AudioDevice.set(previous, device, gain)
        }
    }
}

/// Silences the speakers for the duration of a dictation press.
///
/// The microphone hears the room, and the room includes whatever your speakers
/// are playing. A video behind a press ends up transcribed, in your voice, at
/// your cursor. Muting the output for the two seconds you are talking removes
/// the sound at the source.
///
/// The alternative is acoustic echo cancellation, which is what the meeting
/// track uses and is transparent where this is not. It is also a duplex audio
/// graph on the hot path, and its failure mode is silence rather than an
/// error. This is a property write, and its failure mode is that the speakers
/// stay on.
///
/// Off by default. It is audible — the thing you are listening to stops every
/// time you speak — and that is a preference, not a fix everyone wants.
///
/// Bounded by the same counted lease as `InputGain`, and restores whatever was
/// there before rather than simply unmuting: a user who muted their own output
/// before pressing the key should still be muted afterwards.
enum OutputMute {
    /// What has to be put back on release. Which one depends on the device:
    /// plenty of outputs — aggregates, virtual devices, some USB interfaces —
    /// expose no mute switch at all, so volume is the fallback.
    private enum Previous: Sendable {
        case muted(UInt32)
        case volume(Float32)
    }

    private static let lease = DeviceLease<Previous>()
    private static let mute = AudioDevice.address(
        kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
    private static let volume = AudioDevice.address(
        kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput)

    /// Take a lease, silencing the default output.
    ///
    /// Call before the microphone opens. Muting afterwards leaves the first
    /// moments of whatever was playing already captured, which is the part a
    /// transcript notices.
    static func acquire() {
        lease.acquire {
            guard
                let device = AudioDevice.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
            else { return nil }

            if let current = AudioDevice.uint32(device, mute) {
                if current == 1 {
                    // Already muted by whoever was here first. Leave it alone
                    // and put the same value back, so they stay muted
                    // afterwards.
                    return (device, .muted(current))
                }
                if AudioDevice.set(UInt32(1), device, mute) {
                    return (device, .muted(current))
                }
                // Readable but not settable, which some devices are. Falling
                // through matters: returning here would take a lease, mute
                // nothing, and report success.
            }

            // No usable mute switch. Volume to zero and back.
            guard let level = AudioDevice.float32(device, volume), level > 0,
                AudioDevice.set(Float32(0), device, volume)
            else { return nil }
            return (device, .volume(level))
        }
    }

    /// Release a lease. The last one out puts the speakers back as they were.
    ///
    /// Every path out of a capture has to reach this, including the ones that
    /// throw: leaving someone's audio muted because the engine failed to start
    /// is a worse bug than the one this feature fixes.
    static func release() {
        lease.release { device, previous in
            switch previous {
            case .muted(let value): AudioDevice.set(value, device, mute)
            case .volume(let value): AudioDevice.set(value, device, volume)
            }
        }
    }
}
