import FluidAudio
import Foundation

struct TranscriptionModel {
    let id: String
    let displayName: String
    /// The FluidAudio checkpoint this id resolves to.
    ///
    /// The enum rather than a string tag: FluidAudio can only run the handful
    /// of checkpoints it ships specs for, and naming the case here means a new
    /// registry entry either picks a real one or fails to compile. A string
    /// used to be mapped with a defaulted `?:`, so a typo resolved silently to
    /// v2 and quietly ran the wrong model.
    let version: AsrModelVersion
    let sizeMB: Int
    let languages: [String]
    /// Whether this model can transcribe a recorded session.
    ///
    /// Dictation only needs text. A session needs *timed segments*, because
    /// `TranscriptionCoordinator` merges two tracks on their start and end
    /// times — so a model that can only return a bare string collapses each
    /// track to one span, and the meeting reads as one block per speaker
    /// instead of a conversation.
    ///
    /// Timed segments, not token timestamps: how an engine arrives at them is
    /// its own business. Parakeet happens to build them from word timings, but
    /// an engine emitting native sentence or chunk spans would serve sessions
    /// just as well, and this flag should not exclude it.
    ///
    /// Every checkpoint in the registry today can, so this is `true`
    /// throughout. It is here because the failure it guards is silent and
    /// arrives after the meeting, which is the worst possible moment to learn
    /// the model was the wrong one.
    let supportsSessions: Bool
    let recommended: Bool
}
