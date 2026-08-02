import Foundation

/// Where yap writes anything derived from what you said.
///
/// Not `/tmp`. Everything here is either a transcript, a timing line that
/// implies one, or raw captured audio, and `/tmp` is world readable on a
/// shared machine. A daemon that keeps a plaintext record of everything you
/// have ever dictated, in a directory any other local account can read, is a
/// worse problem than whatever the log was going to help debug.
enum Paths {
    /// `~/Library/Logs/yap`, created 0700 on first use.
    static var logDirectory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/yap", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    static var stdoutLog: URL { logDirectory.appendingPathComponent("yap.out.log") }
    static var stderrLog: URL { logDirectory.appendingPathComponent("yap.err.log") }

    /// launchd creates the log files itself and does not honour a mode, so
    /// tighten them to 0600 after the agent is installed. Existing files are
    /// tightened too, which covers an agent installed by an earlier build.
    static func restrictLogPermissions() {
        for url in [stdoutLog, stderrLog] {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(
                    atPath: url.path, contents: nil,
                    attributes: [.posixPermissions: 0o600])
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Keep the LaunchAgent's logs from growing forever.
    ///
    /// Called once per daemon start — two `stat`s, and nothing while idle.
    /// launchd opens these with `O_APPEND`, so truncating under its live
    /// descriptor is safe: its next write lands at the new EOF. Rotating by
    /// rename is the wrong shape here, because that strands launchd's fd on
    /// the old inode and every later line goes to a file nobody can find
    /// until the agent is restarted.
    static func trimOversizedLogs() {
        for url in [stdoutLog, stderrLog] {
            let path = url.path
            guard
                let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
                size > 5 * 1024 * 1024
            else { continue }
            // truncate(2) rather than a FileHandle: one syscall and no
            // descriptor to own. A failure needs no report — logging about the
            // log is not worth a failure path — but it must not be announced
            // as a success either, or the line claims a 7 MB file went away
            // while it is still sitting there.
            guard truncate(path, 0) == 0 else { continue }
            warn("truncated \(url.lastPathComponent) (was \(size / (1024 * 1024)) MB)")
        }
    }
}
