import FluidAudio
import Foundation

/// Where downloaded models live on disk.
///
/// There is only one store, and it is not ours: FluidAudio's machine-global
/// cache at `~/Library/Application Support/FluidAudio/Models/`. Every
/// FluidAudio client on the machine shares it, so the download happens once per
/// machine rather than once per app. Pointing yap somewhere tidier would orphan
/// existing downloads and *reduce* sharing, so we leave it alone and just
/// report where it is.
enum ModelStore {
    /// The directory every model is downloaded beneath. Printed by
    /// `yap models list` so "where did the gigabyte go" stays one command.
    static var modelsRoot: URL {
        AsrModels.defaultCacheDirectory(for: .v2).deletingLastPathComponent()
    }

    /// Where `model` lives once downloaded, whether or not it is there yet.
    static func location(of model: TranscriptionModel) -> URL {
        AsrModels.defaultCacheDirectory(for: model.version)
    }

    static func isDownloaded(_ model: TranscriptionModel) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: location(of: model).path,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    /// Collapse `$HOME` back to `~` for display.
    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home)
            ? "~" + url.path.dropFirst(home.count)
            : url.path
    }
}
