import FluidAudio
import Foundation

/// Built-in model registry.
///
/// The list lives in source rather than a JSON resource so the binary stays
/// self-contained — no `Bundle.module` lookup, no resource bundle to ship
/// beside the executable.
///
/// Order matters: `recommended()` takes the first entry flagged as such.
enum ModelRegistry {
    static let shared: [TranscriptionModel] = [
        // Default. Measured on this machine against the full LibriSpeech
        // test-clean split (2620 files, 324 min): 2.67% WER at 54 ms p50 for
        // clips under 5 s, against v2's 2.06% at 70 ms. Two thirds the
        // latency and half the download for 0.6 points of WER — and both
        // numbers are far enough under the perceptual floor that the win is
        // really the 220 MB and the faster load, not the milliseconds.
        TranscriptionModel(
            id: "parakeet-tdt-ctc-110m",
            displayName: "Parakeet TDT-CTC 110M (English)",
            version: .tdtCtc110m,
            sizeMB: 220,
            languages: ["en"],
            supportsSessions: true,
            recommended: true
        ),
        // Kept as the accuracy option: 2.06% WER is the best of the three,
        // and a user who would rather have the point back than the megabytes
        // sets this in config.
        TranscriptionModel(
            id: "parakeet-tdt-0.6b-v2",
            displayName: "Parakeet TDT 0.6B v2 (English)",
            version: .v2,
            sizeMB: 465,
            languages: ["en"],
            supportsSessions: true,
            recommended: false
        ),
        TranscriptionModel(
            id: "parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT 0.6B v3 (multilingual)",
            version: .v3,
            sizeMB: 500,
            languages: ["multi"],
            supportsSessions: true,
            recommended: false
        )
    ]

    static func find(_ id: String) -> TranscriptionModel? {
        shared.first { $0.id == id }
    }

    static func recommended() -> TranscriptionModel? {
        shared.first { $0.recommended } ?? shared.first
    }
}
