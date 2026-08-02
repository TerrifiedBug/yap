import ArgumentParser
import Foundation

/// Start and stop the login agent without remembering a `launchctl` line.
///
/// "Quit yap" in the menu bar calls `NSApp.terminate`, which exits 0, and the
/// agent is `KeepAlive` only on failure — so quitting sticks, and getting back
/// meant knowing `launchctl kickstart gui/$(id -u)/com.terrifiedbug.yap`. For a
/// menu-bar app whose Quit item is one click away, that is a poor trade.
///
/// yap does ship inside a .app now, so double-clicking it in Applications is
/// another way back. That only helps someone who found it there; `yap start`
/// is the answer for a CLI you installed with Homebrew.
enum Agent {
    /// Whether launchd knows about the job at all.
    static var isLoaded: Bool {
        run(["list", Install.label]).status == 0
    }

    /// Whether it is loaded *and* has a process. The distinction is the whole
    /// reason `start` needs two different commands: the agent spends its life
    /// loaded and only sometimes running, and `kickstart` cannot start a job
    /// launchd has never heard of.
    static var isRunning: Bool {
        let listing = run(["list", Install.label])
        return listing.status == 0 && listing.output.contains("\"PID\" =")
    }

    static var domain: String { "gui/\(getuid())" }
    static var target: String { "\(domain)/\(Install.label)" }

    /// Both streams down one pipe: `list` answers on stdout, and every
    /// refusal launchctl has to offer arrives on stderr, so dropping stderr
    /// would leave a failed bootstrap reporting nothing but a number.
    ///
    /// One pipe rather than two, and read before waiting. Two pipes drained in
    /// sequence still deadlock the moment the second one fills while the first
    /// is being read to EOF — and the output here is small enough that the
    /// interleaving does not matter.
    @discardableResult
    static func run(_ args: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        guard (try? task.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Wait for the job to stop having a process. Cheap and unambiguous:
    /// nothing has to start working, it just has to be gone.
    static func settlesStopped(within seconds: Int) -> Bool {
        for _ in 0..<(seconds * 4) {
            if !isRunning { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return !isRunning
    }

    /// Wait for the daemon to say it is listening, not merely to exist.
    ///
    /// A pid is the wrong signal in both directions. `kickstart` returns as
    /// soon as launchd has spawned something, and on a missing Accessibility
    /// grant the daemon then exits — quietly, with status 0 — so a pid check
    /// reports success for a daemon that is already gone. In the other
    /// direction a cold model cache holds a pid for minutes while several
    /// hundred megabytes download, long before the hotkey works.
    ///
    /// So: watch for the line it prints when the tap is actually live, and
    /// give up early if the process disappears first.
    ///
    /// - Parameter after: size of the log before launching, so only this run's
    ///   output counts. The log outlives many starts.
    static func settlesListening(after offset: UInt64, within seconds: Int) -> Bool {
        for tick in 0..<(seconds * 4) {
            if logContainsListening(after: offset) { return true }
            // Grace at the start: launchd has not necessarily spawned it yet.
            if tick > 8, !isRunning { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return logContainsListening(after: offset)
    }

    static func logSize() -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: Paths.stderrLog.path)[.size] as? UInt64)
            .flatMap { $0 } ?? 0
    }

    private static func logContainsListening(after offset: UInt64) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: Paths.stderrLog) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return false }
        return String(decoding: data, as: UTF8.self).contains("listening on")
    }

    static func requireInstalled() throws {
        guard FileManager.default.fileExists(atPath: Install.plistURL.path) else {
            throw ValidationError(
                "no login agent installed — run `yap install --launch-at-login` first")
        }
    }
}

// MARK: - start

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the background daemon, or restart it if it is already running."
    )

    func run() throws {
        try Agent.requireInstalled()

        // Before launching, so only this run's output is examined.
        let offset = Agent.logSize()

        // Both branches check the status. A rejected launchctl leaves the old
        // daemon running and no new "listening" line coming, so skipping the
        // check does not fail — it waits the full ten minutes and then blames
        // the daemon for something launchctl refused to do.
        let result: (status: Int32, output: String)
        if Agent.isLoaded {
            // -k restarts a running job and starts a stopped one, so this
            // covers both. Reaching for `yap start` on a daemon that is
            // already up means wanting it to pick up whatever just changed,
            // not a message saying it is fine.
            result = Agent.run(["kickstart", "-k", Agent.target])
        } else {
            // `yap stop` boots the job out, so this is the ordinary path back.
            result = Agent.run(["bootstrap", Agent.domain, Install.plistURL.path])
        }
        if result.status != 0 {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ValidationError(
                "launchctl refused: \(detail.isEmpty ? "status \(result.status)" : detail)")
        }

        // Long enough for a cold model cache, which downloads several hundred
        // megabytes before the hotkey works. A warm one takes a second.
        guard Agent.settlesListening(after: offset, within: 600) else {
            print("✗ it did not come up.")
            print("  \(Paths.stderrLog.path) says why — most often Accessibility.")
            print("  yap doctor")
            throw ExitCode(1)
        }
        print("✓ running")
    }
}

// MARK: - stop

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the background daemon. It comes back at your next login."
    )

    func run() throws {
        try Agent.requireInstalled()

        guard Agent.isRunning else {
            print("not running")
            return
        }

        // Boot it out rather than signal it. The agent is KeepAlive on
        // unsuccessful exit, and a process killed by a signal is exactly that,
        // so SIGTERM would stop it and launchd would put it straight back.
        //
        // Booting out unloads the job but leaves the plist on disk, so it
        // loads again at the next login. Removing it for good is
        // `yap install --uninstall`; this is the one you can undo.
        let result = Agent.run(["bootout", Agent.target])
        if result.status != 0, Agent.isRunning {
            print("✗ launchctl bootout failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            throw ExitCode(1)
        }

        guard Agent.settlesStopped(within: 10) else {
            print("✗ still running — `launchctl bootout \(Agent.target)`")
            throw ExitCode(1)
        }
        print("✓ stopped — back at your next login, or `yap start`")
    }
}
