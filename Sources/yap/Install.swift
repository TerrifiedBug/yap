import ArgumentParser
import Foundation

/// Manage yap's LaunchAgent so the daemon starts at login.
///
/// We deliberately do NOT use SMAppService.mainApp here. It registers the
/// enclosing .app, and yap is a CLI that happens to ship inside one: the
/// bundle exists so the build can be notarized and so TCC has a stable
/// identity, not so the app can be launched as an app. A plain LaunchAgent
/// plist names the executable directly, which is the honest description of
/// what runs, and it works the same whether yap came from Homebrew, the .dmg
/// or a local build.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register yap to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            warn("specify exactly one of --launch-at-login or --uninstall")
            throw ExitCode(64)
        }

        if uninstall {
            try removeAgent()
        } else {
            try writeAgent()
        }
    }

    // MARK: -

    /// Not private: `yap doctor` reports on the agent this installs.
    static let label = "com.terrifiedbug.yap"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private func writeAgent() throws {
        let binary = try resolveBinaryPath()

        let plist: [String: Any] = [
            "Label": Self.label,
            // KeepAlive relaunches anything that exits non-zero, so every
            // expected-and-unfixable-by-retrying startup state must exit 0 or
            // launch-at-login becomes a relaunch loop. Two halves to that:
            // --skip-doctor suppresses the startup report (which would exit 1
            // on any warning), and Daemon.start() exits 0 rather than 1 when
            // Accessibility is missing. Neither alone is sufficient.
            "ProgramArguments": [binary, "run", "--skip-doctor"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": Paths.stdoutLog.path,
            "StandardErrorPath": Paths.stderrLog.path,
        ]

        let url = Self.plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)

        // Best-effort bootstrap; ignore failure if already loaded.
        _ = Agent.run(["bootout", Agent.domain, url.path])
        let result = Agent.run(["bootstrap", Agent.domain, url.path])
        if result.status != 0 {
            warn("warning: launchctl bootstrap exited \(result.status):\n\(result.output)")
        }

        // launchd creates the log files itself and ignores any mode we ask
        // for, so tighten them here.
        Paths.restrictLogPermissions()

        print("✓ launch-at-login installed")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        print("  logs:   \(Paths.stdoutLog.path)")
        print("          \(Paths.stderrLog.path)")
        print()
        // Under launchd there is no terminal to inherit a TCC grant from, so
        // the permissions live against the binary itself rather than against
        // Ghostty/iTerm/Terminal the way they do when you run yap by hand.
        print("note: launchd runs the binary directly, not through your terminal,")
        print("so Accessibility and Microphone have to be granted to")
        print("\(binary) itself the first time the agent starts.")
    }

    private func removeAgent() throws {
        let url = Self.plistURL
        if FileManager.default.fileExists(atPath: url.path) {
            _ = Agent.run(["bootout", Agent.domain, url.path])
            try FileManager.default.removeItem(at: url)
            print("✓ launch-at-login removed")
        } else {
            print("nothing to remove (no agent at \(url.path))")
        }
    }

    /// Which binary launchd should run.
    ///
    /// The one you invoked, in almost every case. Preferring
    /// `/usr/local/bin/yap` instead looks tidy and is wrong: install yap from
    /// Homebrew on a machine that still has an older copy there, and the agent
    /// launches the old one for ever. Nothing about that is visible — the new
    /// binary reports the install succeeded, and the permission advice names a
    /// file launchd is not going to run.
    ///
    /// `Bundle.main.executablePath` is absolute and symlink-resolved, so a
    /// Homebrew shim resolves to the real binary inside the app bundle, which
    /// is what TCC keys the grants on.
    private func resolveBinaryPath() throws -> String {
        let running = Bundle.main.executablePath.flatMap {
            FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
        }
        // The exception: a build directory is rebuilt and replaced constantly,
        // and every rebuild invalidates the Accessibility grant. Point at the
        // installed copy instead when there is one.
        if let running, !running.contains("/.build/") {
            return running
        }
        let installed = "/usr/local/bin/yap"
        if FileManager.default.isExecutableFile(atPath: installed) {
            if running != nil { warn("note: running from a build directory; using \(installed)") }
            return installed
        }
        if let running {
            warn("note: no binary at \(installed); using \(running)")
            return running
        }
        warn("couldn't locate the yap binary. install it to \(installed) first.")
        throw ExitCode(1)
    }
}
