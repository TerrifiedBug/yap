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
    let recommended: Bool
}
