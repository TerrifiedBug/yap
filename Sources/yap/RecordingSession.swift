import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — either engine does better on clean single-source
/// audio than on a mixdown of two people talking over each other, and two
/// tracks give free two-party diarization.
final class RecordingSession {
    let dir: URL
    let startedAt = Date()

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private var stallTimer: Timer?
    /// Tracks already reported, so one stall warns once.
    private var warned: Set<String> = []

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(root: URL) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start(voiceProcessing: Bool = Config.micVoiceProcessing()) throws {
        try system.start(writingTo: dir.appendingPathComponent("system.caf"))
        do {
            try mic.start(
                writingTo: dir.appendingPathComponent("mic.caf"),
                voiceProcessing: voiceProcessing
            )
        } catch {
            system.stop()
            throw error
        }
        startStallWatch()
    }

    /// Tell the user when a track stops growing.
    ///
    /// Upstream saw a call app take the input device and leave a 19 minute
    /// meeting with 1.7 seconds of microphone, discovered only afterwards.
    /// Rather than guess at the cause and auto-recover, watch the one symptom
    /// every cause shares: the file stops getting bigger. Two `stat` calls
    /// every 15 seconds, only while recording.
    private func startStallWatch() {
        var lastSize: [String: Int] = [:]
        var stalledSince: [String: Date] = [:]

        stallTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            for track in ["mic", "system"] {
                let path = self.dir.appendingPathComponent("\(track).caf").path
                let size =
                    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
                    .flatMap { $0 } ?? 0

                if size > (lastSize[track] ?? -1) {
                    // remove() returns nil if we never warned, which keeps the
                    // all-clear paired with an alarm the user actually saw, and
                    // re-arms the track so a second stall is not swallowed.
                    if self.warned.remove(track) != nil {
                        notifyUser(title: "yap", body: "\(track) track is recording again")
                    }
                    stalledSince[track] = nil
                    lastSize[track] = size
                    continue
                }
                // Same size as last look. Warn once per stall, not every tick.
                let since = stalledSince[track] ?? Date()
                stalledSince[track] = since
                if Date().timeIntervalSince(since) >= 45, !self.warned.contains(track) {
                    self.warned.insert(track)
                    notifyUser(
                        title: "yap", body: "\(track) track stalled — no audio for 45s")
                    warn("warning: \(track) track has not grown for 45s")
                }
            }
        }
    }

    /// Stop both tracks and write meta.json.
    func stop() {
        stallTimer?.invalidate()
        stallTimer = nil
        mic.stop()
        system.stop()

        let ended = Date()
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)

        let meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ],
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }
}
