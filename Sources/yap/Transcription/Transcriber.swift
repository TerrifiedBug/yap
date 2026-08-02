import Foundation

/// One timed span of recognised speech from a single track, relative to that
/// track's own start.
struct TranscriptSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// A loaded speech-to-text engine.
///
/// One conformance serves both halves of the app: dictation hands it samples
/// straight off the mic ring buffer and wants finished text; a recorded
/// session hands it a file and wants timed segments.
///
/// Sharing one protocol — and therefore one loaded model — is the whole reason
/// the two tools became one binary. A machine that dictates *and* records
/// meetings used to run two daemons each holding their own copy of a
/// few-hundred-megabyte model. Now it loads once, in one process.
protocol Transcriber: Actor {
    /// Short engine identifier, recorded as transcript provenance.
    nonisolated var engineName: String { get }
    /// Concrete model identifier, recorded as transcript provenance.
    nonisolated var modelID: String { get }

    /// Download if absent, then load into memory. Called once up front so the
    /// first hotkey press isn't stuck behind a download or an ANE compile.
    func warmUp() async throws

    /// Drop the loaded model. Session transcription releases when its queue
    /// drains; a dictation daemon holds on, because the whole point is that
    /// the next press is instant.
    func release() async

    /// Dictation: 16 kHz mono samples in, finished text out.
    func transcribe(_ samples: [Float]) async throws -> String

    /// Session: an audio file in, timed segments out.
    func transcribe(_ file: URL) async throws -> [TranscriptSegment]
}

extension TranscriptionModel {
    /// There is one engine. This exists so callers name a model, not a class,
    /// and so adding a second engine later stays a one-line change here rather
    /// than a hunt through the call sites.
    func makeTranscriber() -> any Transcriber {
        ParakeetTranscriber(model: self)
    }
}

enum TranscriberError: Error, CustomStringConvertible {
    case notLoaded
    case unreadableAudio(URL, Error?)

    var description: String {
        switch self {
        case .notLoaded:
            return "transcriber used before warmUp()"
        case .unreadableAudio(let url, let underlying):
            return "unreadable or empty audio \(url.lastPathComponent)"
                + (underlying.map { ": \($0)" } ?? "")
        }
    }
}
