import Foundation

/// yap's launch-at-login agent, as a plist launchd loads for us.
///
/// Deliberately not `SMAppService.mainApp`. That API registers the enclosing
/// bundle and gives us nothing to say about it; a plain LaunchAgent plist
/// names the executable directly, and it is the only way to get the two things
/// this daemon actually needs from launchd — `KeepAlive` so a crash comes back,
/// and `StandardErrorPath` so the log exists at all. It also works the same
/// whether yap arrived from Homebrew, the .dmg or a local build.
///
/// Writing the plist is the whole of "launch at login": nothing here
/// bootstraps the job. The app the user just launched is already running, and
/// bootstrapping a second copy of it under launchd would take the daemon lock
/// away from the process they are looking at. launchd reads the file at the
/// next login, which is exactly what the toggle promises.
enum LaunchAgent {
    static let label = "com.terrifiedbug.yap"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static var domain: String { "gui/\(getuid())" }
    static var target: String { "\(domain)/\(label)" }

    /// Whether the login item exists on disk. The Settings toggle reads this.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Whether launchd knows about the job at all. Distinct from installed: a
    /// plist written since the last login is not loaded yet.
    static var isLoaded: Bool {
        run(["list", label]).status == 0
    }

    /// Both streams down one pipe: `list` answers on stdout, and every refusal
    /// launchctl has to offer arrives on stderr, so dropping stderr would
    /// leave a failed command reporting nothing but a number.
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

    /// Write the plist. The binary named is this bundle's own executable,
    /// symlink-resolved: run through Homebrew's shim `executableURL` reports
    /// `/opt/homebrew/bin/yap`, and naming that is what costs the daemon its
    /// bundle identity and with it the menu bar icon (see
    /// `Run.reexecInsideAppBundle`).
    ///
    /// Only from inside a .app, and that guard is load-bearing rather than
    /// tidy. A `swift build` binary is replaced on every rebuild, and TCC keys
    /// the Accessibility grant on the code it saw — so a login item naming one
    /// launches something the grant no longer covers, and the daemon comes
    /// back at the next login unable to see the hotkey. Worse, pointing the
    /// item at a build directory *takes the working one away*: measured, by
    /// running an unbundled build with a login item already installed.
    static func install() throws {
        guard Bundle.main.bundlePath.hasSuffix(".app"),
            let binary = Bundle.main.executableURL?.resolvingSymlinksInPath().path
        else { throw LaunchAgentError.notBundled }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary, "run"],
            "RunAtLoad": true,
            // Only on failure. "Quit yap" exits 0, so quitting sticks.
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": Paths.stdoutLog.path,
            "StandardErrorPath": Paths.stderrLog.path,
        ]

        let url = plistURL
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
        // launchd creates the log files itself and ignores any mode we ask
        // for, so tighten them here.
        Paths.restrictLogPermissions()
    }

    /// Remove the plist. No `bootout`: when the running process *is* the
    /// launchd instance, booting the job out kills the app the user is
    /// clicking in.
    static func uninstall() throws {
        guard isInstalled else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    /// Rewrite an installed plist that no longer says what this build writes.
    ///
    /// The upgrade path, and the only one there is: yap 0.2 wrote
    /// `run --skip-doctor` and pointed at whichever binary was current then.
    /// Nothing but yap rewrites that file, so a build that changed either has
    /// to repair it the first time it runs. Silent when there is nothing to
    /// do, which is every launch after the first.
    static func refreshIfStale() {
        guard isInstalled, Bundle.main.bundlePath.hasSuffix(".app"),
            let binary = Bundle.main.executableURL?.resolvingSymlinksInPath().path
        else { return }
        let current = (try? Data(contentsOf: plistURL))
            .flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil)
                    as? [String: Any]
            }?["ProgramArguments"] as? [String]
        guard current != [binary, "run"] else { return }
        do {
            try install()
            warn("login item updated: \(binary) run")
        } catch {
            warn("warning: couldn't update the login item: \(error)")
        }
    }

    /// Restart the job launchd owns. Used after an in-place update, so the new
    /// image comes up under launchd rather than beside it.
    @discardableResult
    static func kickstart() -> (status: Int32, output: String) {
        run(["kickstart", "-k", target])
    }

    enum LaunchAgentError: LocalizedError {
        case notBundled

        var errorDescription: String? {
            switch self {
            case .notBundled:
                return "launch at login needs the installed yap.app, not a build directory"
            }
        }
    }
}
