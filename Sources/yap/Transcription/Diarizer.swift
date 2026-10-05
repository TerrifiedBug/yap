import FluidAudio
import Foundation

/// Who, among "them", said which line.
///
/// Two tracks give me-versus-them for free; this is the rest of it. After a
/// session is transcribed, the system track goes through FluidAudio's offline
/// diarizer (pyannote segmentation, WeSpeaker embeddings, VBx clustering — the
/// same package the transcriber comes from, so no new dependency), and each
/// "them" segment takes the label of the voice that was speaking for most of
/// it. Voices get a stable identity across meetings: each cluster's centroid is
/// matched against `~/.config/yap/voices.json`, so a voice you have named in
/// Settings is labelled by name from then on, and one you have not is
/// `them-N`, numbered by first appearance in this transcript.
///
/// The diarizer models (~50 MB, one-off download into the shared FluidAudio
/// cache) are loaded for the pass and dropped with it: the daemon's one
/// resident model is still the transcriber. Off by default — `diarize` in
/// config, "Tell the other speakers apart" in Settings — because the pass
/// costs a model download the first time and a minute or so after a long
/// call, and a dictation-only install has no use for either.
enum Diarizer {
    struct Result {
        let spans: [SpeakerSpan]
        /// One embedding per cluster, l2-normalised: the voice's print.
        let centroids: [String: [Float]]
    }

    static func run(_ file: URL) async throws -> Result {
        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()
        let result = try await manager.process(file)
        let spans = result.segments.map {
            SpeakerSpan(
                cluster: $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds))
        }
        var centroids = result.speakerDatabase ?? [:]
        // Older pipelines leave the database nil; the segments still carry
        // their embeddings, and their mean is the same print.
        if centroids.isEmpty {
            var sums: [String: [Float]] = [:]
            for seg in result.segments where !seg.embedding.isEmpty {
                var acc = sums[seg.cluster] ?? [Float](repeating: 0, count: seg.embedding.count)
                for i in 0..<min(acc.count, seg.embedding.count) { acc[i] += seg.embedding[i] }
                sums[seg.cluster] = acc
            }
            centroids = sums
        }
        return Result(spans: spans, centroids: centroids.mapValues(Voices.normalized))
    }
}

private extension TimedSpeakerSegment {
    var cluster: String { speakerId }
}

/// One stretch of one voice on the system track, in track seconds.
struct SpeakerSpan: Equatable {
    let cluster: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Pure: which cluster a transcript segment belongs to, and what to call it.
enum SpeakerLabeler {
    /// Clusters in order of first appearance, which is the order `them-N`
    /// counts in: the first other voice you hear is them-1.
    static func order(_ spans: [SpeakerSpan]) -> [String] {
        var seen: [String] = []
        for span in spans.sorted(by: { $0.start < $1.start }) where !seen.contains(span.cluster) {
            seen.append(span.cluster)
        }
        return seen
    }

    /// The cluster that covers most of `start..<end`. With no overlap at all
    /// — a short segment that fell in a gap between spans — the nearest span
    /// within `tolerance` wins; further than that, nil, and the line stays
    /// an unattributed "them" rather than a guess.
    static func cluster(
        covering start: TimeInterval, _ end: TimeInterval,
        in spans: [SpeakerSpan], tolerance: TimeInterval = 1.5
    ) -> String? {
        var overlap: [String: TimeInterval] = [:]
        var nearest: (cluster: String, distance: TimeInterval)?
        for span in spans {
            let shared = min(end, span.end) - max(start, span.start)
            if shared > 0 {
                overlap[span.cluster, default: 0] += shared
                continue
            }
            let distance = span.end <= start ? start - span.end : span.start - end
            if nearest == nil || distance < nearest!.distance {
                nearest = (span.cluster, distance)
            }
        }
        if let best = overlap.max(by: { $0.value < $1.value }) {
            return best.key
        }
        if let nearest, nearest.distance <= tolerance {
            return nearest.cluster
        }
        return nil
    }
}

/// `~/.config/yap/voices.json`: every other voice yap has heard, its print,
/// and the name you gave it. The file is the whole store, like config.json.
struct Voice: Codable, Equatable {
    let id: String
    var name: String?
    var embedding: [Float]
    var meetings: Int
    var lastHeard: String
    /// The folder the voice was last heard in, so an unnamed one can be
    /// placed: "them-2 in Thursday's call".
    var lastSession: String?

    /// What this voice is called in a transcript: its name, or the `them-N`
    /// the caller counted for it.
    func label(fallback: String) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

enum Voices {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/yap/voices.json")
    /// Cosine distance above which two prints are different people. The same
    /// number FluidAudio's own speaker manager assigns with.
    static let threshold: Float = 0.65

    static func load(from url: URL = path) -> [Voice] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(File.self, from: data) { return file.voices }
        warn("warning: \(url.path) is not a voices file — starting empty")
        return []
    }

    static func save(_ voices: [Voice], to url: URL = path) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(File(voices: voices)).write(to: url, options: .atomic)
        } catch {
            warn("warning: could not write \(url.path): \(error)")
        }
    }

    /// Match this session's clusters against the store. Each cluster takes
    /// the closest known voice inside the threshold, closest pairs first so
    /// two clusters cannot claim one voice; the rest become new voices. The
    /// store is updated — print nudged toward the new print, meeting count,
    /// last heard — and returned with the cluster → voice map.
    static func resolve(
        centroids: [String: [Float]], session: String, in voices: [Voice],
        now: Date = Date(), threshold: Float = threshold
    ) -> (voices: [Voice], byCluster: [String: Voice]) {
        var voices = voices
        var byCluster: [String: Voice] = [:]
        let stamp = ISO8601DateFormatter().string(from: now)

        var pairs: [(cluster: String, index: Int, distance: Float)] = []
        for (cluster, print) in centroids {
            for (i, voice) in voices.enumerated() {
                let d = cosineDistance(print, voice.embedding)
                if d <= threshold { pairs.append((cluster, i, d)) }
            }
        }
        var takenVoices: Set<Int> = []
        var matched: Set<String> = []
        for pair in pairs.sorted(by: { $0.distance < $1.distance })
        where !takenVoices.contains(pair.index) && !matched.contains(pair.cluster) {
            takenVoices.insert(pair.index)
            matched.insert(pair.cluster)
            var voice = voices[pair.index]
            voice.embedding = normalized(blend(voice.embedding, centroids[pair.cluster]!,
                                               weight: 1 / Float(voice.meetings + 1)))
            voice.meetings += 1
            voice.lastHeard = stamp
            voice.lastSession = session
            voices[pair.index] = voice
            byCluster[pair.cluster] = voice
        }
        for (cluster, print) in centroids where !matched.contains(cluster) {
            let voice = Voice(
                id: String(UUID().uuidString.prefix(8)).lowercased(), name: nil,
                embedding: normalized(print), meetings: 1, lastHeard: stamp, lastSession: session)
            voices.append(voice)
            byCluster[cluster] = voice
        }
        return (voices, byCluster)
    }

    static func rename(_ id: String, to name: String?) {
        var voices = load()
        guard let i = voices.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        voices[i].name = trimmed.isEmpty ? nil : trimmed
        save(voices)
    }

    static func forget(_ id: String) {
        save(load().filter { $0.id != id })
    }

    // MARK: - maths

    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 1 }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    private static func blend(_ old: [Float], _ new: [Float], weight: Float) -> [Float] {
        let n = min(old.count, new.count)
        return (0..<n).map { old[$0] * (1 - weight) + new[$0] * weight }
    }

    private struct File: Codable {
        var voices: [Voice]
    }
}
