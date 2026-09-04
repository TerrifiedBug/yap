import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
///
/// The daemon hands us the transcriber it already holds for dictation, so a
/// meeting transcribes on the same loaded model the hotkey uses — no second
/// load, no second copy in memory. A coordinator handed nothing resolves and
/// loads its own, and releases it when the queue drains; an injected one is
/// never released, because the whole point of the dictation daemon is that
/// the next key press is instant.
actor TranscriptionCoordinator {
    private var queue: [URL] = []
    private var drainTask: Task<Void, Never>?
    private var transcriber: (any Transcriber)?
    private let ownsTranscriber: Bool
    private var statusHandler: (@Sendable (Bool) -> Void)?
    private var transcriptReadyHandler: (@Sendable (URL) -> Void)?
    /// Built once. `ISO8601DateFormatter` is expensive to construct and this
    /// one is only ever touched from the actor.
    private let iso = ISO8601DateFormatter()

    /// - Parameter transcriber: the daemon's warm transcriber, shared with
    ///   dictation. Pass nil to have the coordinator resolve and own one.
    init(transcriber: (any Transcriber)? = nil) {
        self.transcriber = transcriber
        self.ownsTranscriber = transcriber == nil
    }

    /// Called with true while the queue is draining and false when it empties.
    ///
    /// A flag, not a status: the menu bar has one state line and nowhere to
    /// put a session name or a queue depth, so everything richer than "busy"
    /// was being constructed and thrown away. Failures reach the user through
    /// a notification and the session's transcribe.log.
    func setStatusHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        statusHandler = handler
    }

    /// Called with the session directory after transcript.json/.md are written.
    /// Unset, a plain notification fires instead.
    func setTranscriptReadyHandler(_ handler: @escaping @Sendable (URL) -> Void) {
        transcriptReadyHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Queue a session and return only once the queue is empty, for a caller
    /// that owns the coordinator and has nothing left to do but wait for the
    /// transcript.
    func transcribeNow(_ sessionDir: URL) async {
        enqueue(sessionDir)
        await waitUntilDrained()
    }

    /// Wait out any transcription in flight.
    func waitUntilDrained() async {
        while let task = drainTask { await task.value }
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            warn("resuming \(pending.count) untranscribed session(s)")
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard drainTask == nil, !queue.isEmpty else { return }
        drainTask = Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(true)
            do {
                try await transcribe(dir)
                if let transcriptReadyHandler {
                    transcriptReadyHandler(dir)
                } else {
                    notifyUser(title: "yap — transcript ready", body: dir.lastPathComponent)
                }
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                notifyUser(
                    title: "yap — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
        }
        // Only ours to free. A transcriber borrowed from the dictation daemon
        // stays loaded — releasing it would put the next hotkey press behind a
        // model load.
        if ownsTranscriber, let transcriber {
            await transcriber.release()
            self.transcriber = nil
        }
        publish(false)
        drainTask = nil
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let transcriber = try await preparedTranscriber()

        var merged: [Transcript.Segment] = []
        // A transcript.json is a permanent "this session is done" marker to
        // resumePending, so it must not be written when nothing was actually
        // transcribed. One bad track shouldn't cost us the other's transcript,
        // but every track failing means the engine is broken, not the audio —
        // throw and leave the session on the queue for the next launch.
        var attempted = 0
        var succeeded = 0
        var lastTrackError: Error?

        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(transcriber.engineName))")
            attempted += 1
            let segments: [TranscriptSegment]
            do {
                segments = try await transcriber.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                lastTrackError = error
                continue
            }
            // An empty result is a valid silent track, so success is "did not
            // throw" rather than "returned segments".
            succeeded += 1
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }

        if attempted > 0, succeeded == 0 {
            throw CoordinatorError.allTracksFailed(lastTrackError)
        }

        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: transcriber.engineName,
            model: transcriber.modelID,
            created_at: iso.string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
    }

    /// `warmUp()` is idempotent, so a borrowed transcriber the daemon already
    /// loaded costs one actor hop and nothing else.
    private func preparedTranscriber() async throws -> any Transcriber {
        if let transcriber {
            try await transcriber.warmUp()
            return transcriber
        }
        guard let model = Self.resolveModel() else { throw CoordinatorError.noModel }
        let transcriber = model.makeTranscriber()
        try await transcriber.warmUp()
        self.transcriber = transcriber
        return transcriber
    }

    /// Sessions transcribe on the model dictation uses. One model id in
    /// config, one model on disk, one model in memory — so this is the same
    /// resolution the daemon booted with, warning and all.
    private static func resolveModel() -> TranscriptionModel? {
        try? Resolve.model()
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(iso.string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ busy: Bool) {
        statusHandler?(busy)
    }
}

private enum CoordinatorError: Error, CustomStringConvertible {
    case noModel
    /// Every track that existed on disk failed to transcribe. Distinct from a
    /// session with no usable audio: this one is worth retrying.
    case allTracksFailed(Error?)

    var description: String {
        switch self {
        case .noModel:
            return "no transcription model available in the registry"
        case .allTracksFailed(let underlying):
            return "every track failed to transcribe"
                + (underlying.map { ": \($0)" } ?? "")
        }
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
private struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Render transcript.md, then write transcript.json.
    ///
    /// Order matters. Both writes are atomic, but `resumePending` treats the
    /// presence of transcript.json as "this session is done", so writing it
    /// first means a failed markdown write leaves a session marked finished
    /// that never produced a readable transcript and will never be retried.
    /// The marker goes last, so a partial failure leaves the session queued.
    func write(to dir: URL) throws {
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            lines.append(
                "**[\(formatElapsed(Double(seg.start_ms) / 1000))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
