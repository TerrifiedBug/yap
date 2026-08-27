import CoreAudio
import Darwin
import Foundation

/// Notices when something other than yap starts using the microphone.
///
/// "Some app is holding a live input stream" is as close to "you are in a call"
/// as macOS will say without extra permissions, and it beats matching a list of
/// meeting apps: a list has to be maintained, mislabels shared helper processes,
/// and fails *silently* for anything nobody thought to add. The trade is
/// deliberate — a false prompt costs one click, a missed one costs the meeting.
///
/// Polling rather than a property listener: listener callbacks for these
/// selectors are unreliable, and the answer almost always comes from one cheap
/// device read.
@MainActor
final class MeetingDetector {
    /// Something took the mic. The arguments are its capture pid and a display
    /// name ("Microsoft Teams") when that pid belongs to an app.
    var onMeetingStart: ((pid_t, String?) -> Void)?

    /// The mic went quiet a moment ago (~2 s). The call could still come back
    /// from a device switch, so this is only for things that are cheap to
    /// lose — an unanswered prompt, not a running recording.
    var onMeetingQuiet: (() -> Void)?

    /// Still quiet after ~16 s: the call is over.
    var onMeetingEnd: (() -> Void)?

    /// One second. An idle poll is one cheap device read, so the ceiling on
    /// how fast the prompt can appear is worth more than the microseconds.
    private static let pollInterval: TimeInterval = 1
    /// Two hits (~2 s) still filters the blips — a Siri activation or a mic
    /// test rarely holds the input stream across two consecutive samples —
    /// while getting the prompt up while you're still saying hello.
    private static let activePollsToPrompt = 2
    /// A prompt for a call that already ended is worse than one that flickers
    /// back if the call resumes, so it goes ~2 s after the mic frees.
    private static let quietPollsToRetire = 2
    /// A recording is not cheap to lose, so it waits ~16 s — long enough to
    /// ride out swapping headphones mid-call.
    private static let quietPollsToEnd = 16

    private let ownPID = getpid()
    /// Test seam for the detector state machine. Production reads Core Audio;
    /// tests supply the active pid for the requested meeting pid, or any active
    /// pid when the argument is nil.
    private let capturePID: ((pid_t?) -> pid_t?)?
    private var timer: Timer?
    /// The client we last saw capturing. Re-checking it is two reads; finding
    /// it in the first place is a scan, so remember it between polls.
    private var capturing: (object: AudioObjectID, pid: pid_t)?
    /// The client observed on the latest poll, independent of the Core Audio
    /// object cache above.
    private var observedPID: pid_t?
    /// Once the user accepts a prompt, only that capture client can keep the
    /// recording alive. Recording our mic can wake other input clients of its
    /// own; they are not evidence that the accepted call continues.
    private var acceptedPID: pid_t?
    private var consecutiveActive = 0
    private var consecutiveInactive = 0
    /// Capture has been confirmed and not yet declared over. Drives the end
    /// detection, and outlives the prompt: the mic can drop for a moment
    /// mid-call without the call being over.
    private var inMeeting = false
    /// The process we have already asked about. Held by pid, like the decline
    /// below, because the question is about one specific call: if the mic
    /// passes straight from one app to another there is no quiet gap to clear
    /// a plain flag, and the second app would never be offered.
    private var askedPID: pid_t?
    /// The process the user said no to. A dropout of that same process stays
    /// declined, but a different app taking the mic is a different call.
    private var declinedPID: pid_t?
    private var loggedPollFailure = false

    init(capturePID: ((pid_t?) -> pid_t?)? = nil) {
        self.capturePID = capturePID
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Stops polling and forgets everything observed so far. The state has to
    /// go: nothing watched the mic while we were stopped, so a stale `asked`
    /// would suppress the prompt for a call that began in the gap, and a stale
    /// `inMeeting` would end a call that was already over.
    func stop() {
        timer?.invalidate()
        timer = nil
        capturing = nil
        observedPID = nil
        acceptedPID = nil
        consecutiveActive = 0
        consecutiveInactive = 0
        inMeeting = false
        askedPID = nil
        declinedPID = nil
    }

    /// The user dismissed the prompt for whoever holds the mic right now.
    /// Don't ask again for that process.
    func declineCurrentMeeting() {
        declinedPID = observedPID
    }

    /// The user accepted the prompt for the client seen on the latest poll.
    func acceptCurrentMeeting() {
        acceptedPID = observedPID ?? askedPID
    }

    /// The session bound to the accepted prompt has stopped. The preferred-pid
    /// filter exists to keep clients woken by our own recording from prolonging
    /// the call; with no recording live it only blinds the scan to other apps.
    func releaseAcceptedMeeting() {
        acceptedPID = nil
    }

    /// Ignore the microphone while yap is dictating.
    ///
    /// Filtering our own pid is not enough, because the process on the mic
    /// during a press is not always us. Holding the hotkey wakes macOS's own
    /// `corespeechd`, which opens an input stream of its own for the length of
    /// the press — a different pid, so it passes the filter and reads as a
    /// call starting. Measured: over a press, `corespeechd` is the *only*
    /// process reporting a running input stream; yap's own capture never
    /// appears in the process list at all.
    ///
    /// Naming that daemon and skipping it would be the wrong fix — a real call
    /// runs through helper processes too, and a denylist is exactly the
    /// maintenance burden this detector was built to avoid. What is actually
    /// true is narrower: nothing observed during a press of our own hotkey is
    /// evidence of a meeting.
    ///
    /// Not `stop()`: that forgets `inMeeting` and `declinedPID`, so dictating
    /// during a call you had already dismissed would prompt you again.
    var suppressed = false {
        didSet {
            // A press that overlapped a poll or two leaves a count behind.
            // Clear it so the lingering stream has to convince us again from
            // scratch after the key comes up.
            if !suppressed { consecutiveActive = 0 }
        }
    }

    // MARK: -

    func poll() {
        // Suppressed rather than stopped, so an in-progress call keeps its
        // end detection running underneath a dictation press.
        guard !suppressed else { return }
        let pid = capturePID.map { $0(acceptedPID) }
            ?? currentCapturingPID(preferred: acceptedPID)
        observedPID = pid
        guard let pid else {
            consecutiveActive = 0
            // No meeting was ever reported, so there is nothing to end.
            guard inMeeting else { return }
            consecutiveInactive += 1
            if consecutiveInactive == Self.quietPollsToRetire {
                askedPID = nil
                onMeetingQuiet?()
            }
            guard consecutiveInactive >= Self.quietPollsToEnd else { return }
            consecutiveInactive = 0
            inMeeting = false
            declinedPID = nil
            acceptedPID = nil
            onMeetingEnd?()
            return
        }
        consecutiveInactive = 0
        consecutiveActive += 1
        guard consecutiveActive >= Self.activePollsToPrompt else { return }
        inMeeting = true
        // Ask once per capturing process: not again for one already asked
        // about, and never for one the user turned down.
        guard pid != askedPID, pid != declinedPID else { return }
        askedPID = pid
        onMeetingStart?(pid, Self.appName(forPID: pid))
    }

    /// The capturing process to follow, excluding yap itself.
    ///
    /// Three tiers, cheapest first, because this runs every second forever:
    /// ask the devices whether anyone at all is capturing (~0.1 ms, and the
    /// answer is no all day), then re-check the client we already know
    /// about (~2 ms), and only scan every client when neither settles it.
    /// Interrogating all ~50 audio clients costs ~45 ms — that is the main
    /// thread, so it stays off the common path.
    ///
    /// Before a prompt is accepted, `preferred` is nil and any external input
    /// client can start a meeting. Afterwards it is the pid behind that prompt:
    /// clients opened by yap's own recording cannot prolong the call.
    private func currentCapturingPID(preferred: pid_t?) -> pid_t? {
        guard anyInputDeviceRunning() else {
            capturing = nil
            return nil
        }
        // Same client as last poll? Confirm the id wasn't recycled onto another
        // process while we weren't looking, and we're done. This can never be
        // one of our own captures: the scan below filters our pid out before
        // assigning `capturing`, so nothing of ours ever reaches this cache.
        if let capturing,
            preferred == nil || capturing.pid == preferred,
            uint32Property(capturing.object, kAudioProcessPropertyIsRunningInput) == 1,
            pidProperty(capturing.object) == capturing.pid {
            return capturing.pid
        }
        // The gate said someone is capturing but nobody we know of is. Scan.
        for object in processObjects() {
            guard uint32Property(object, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            // Skip ourselves. MicRecorder holds the mic for the length of a
            // session, so this is what lets a prompt-started recording still
            // notice the call ending rather than seeing itself.
            //
            // It is *not* what keeps a dictation press quiet, though it was
            // long described that way. Instrumenting CoreAudio over a real
            // press shows yap never appears in this list at all — the process
            // holding the input stream is macOS's own corespeechd, woken by
            // the keypress, under its own pid. `suppressed` handles that, and
            // the two are easy to confuse when a prompt appears.
            guard let pid = pidProperty(object), pid != ownPID else { continue }
            guard preferred == nil || pid == preferred else { continue }
            capturing = (object, pid)
            return pid
        }
        // The gate can sit open for something we don't care about: playback on
        // a duplex device also answers yes. Backing off the scan would cut the
        // cost of that, but every poll it skips is added to how long a real
        // call waits for its prompt, so the scan pays it instead.
        capturing = nil
        return nil
    }

    /// Whether any device that can capture is running for anyone.
    ///
    /// `DeviceIsRunningSomewhere` is global, not input-direction: on a device
    /// with both input and output streams, output-only playback also answers
    /// yes. Filtering to devices that have input streams keeps ordinary
    /// speaker playback out of it, but a duplex device (a USB interface, a
    /// virtual driver) still holds this open while it plays. That costs a scan
    /// rather than a wrong answer, since the per-process check runs after it.
    private func anyInputDeviceRunning() -> Bool {
        for device in deviceObjects() where hasInputStreams(device) {
            if uint32Property(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1 {
                return true
            }
        }
        return false
    }

    private func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    /// Finder's name for the app owning `pid` — "Google Chrome" for a renderer
    /// buried in Chrome's Frameworks directory, since the outermost `.app` is
    /// the one a human would recognise. Daemons and XPC services have no `.app`
    /// and get no name.
    private static func appName(forPID pid: pid_t) -> String? {
        MeetingTitle.appBundlePath(forPID: pid).map(FileManager.default.displayName(atPath:))
    }

    // MARK: - Core Audio plumbing

    private func processObjects() -> [AudioObjectID] {
        systemObjects(kAudioHardwarePropertyProcessObjectList, describedAs: "process list")
    }

    private func deviceObjects() -> [AudioObjectID] {
        systemObjects(kAudioHardwarePropertyDevices, describedAs: "device list")
    }

    private func systemObjects(
        _ selector: AudioObjectPropertySelector,
        describedAs what: String
    ) -> [AudioObjectID] {
        var address = Self.globalAddress(selector)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else { return logPollFailure(what, status) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var objects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects)
        guard status == noErr else { return logPollFailure(what, status) }
        let written = Int(size) / MemoryLayout<AudioObjectID>.size
        if written < count { objects.removeLast(count - written) }
        return objects
    }

    /// A failing poll is "nobody is on a call" — reported once, then silent, so
    /// a permanently unhappy Core Audio can't write a line every second.
    private func logPollFailure(_ what: String, _ status: OSStatus) -> [AudioObjectID] {
        if !loggedPollFailure {
            loggedPollFailure = true
            warn("meeting detection: \(what) unreadable (OSStatus \(status)) — detection off")
        }
        return []
    }

    private func uint32Property(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = Self.globalAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private func pidProperty(_ object: AudioObjectID) -> pid_t? {
        var address = Self.globalAddress(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func globalAddress(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
