import AppKit
import ApplicationServices
import ArgumentParser
import Foundation

@main
struct Yap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "yap",
        abstract:
            "Hold a key, speak, release. On-device dictation, plus a meeting recorder that shares the same loaded model.",
        // The single source of truth for what this binary is. Nothing else
        // holds a version constant, and the release workflow greps this
        // literal against the tag, so a build can never claim the wrong one.
        version: "0.3.0",
        // Two subcommands, and that is the product: `run` is the app, `bench`
        // is the only thing a terminal can do that the menu bar cannot.
        // Everything else — setup, permissions, the login item, the model,
        // recording a session — moved into the menu bar, where the people who
        // need it are already looking.
        subcommands: [Run.self, Bench.self],
        defaultSubcommand: Run.self
    )
}

// MARK: - run

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon in the foreground."
    )

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(
        name: .long,
        help: """
            Write the transcript text to the log as well as its length. Off by \
            default, and the LaunchAgent never passes it, because the log \
            outlives the session.
            """
    )
    var echoTranscripts: Bool = false

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        // Before anything else, because it can replace the process image and
        // everything below would then run twice. See the function.
        Self.reexecInsideAppBundle()

        // First, before anything this run says can land in them: under
        // launch-at-login these two files are the only record of what
        // happened, and they are also the only thing here that grows without
        // bound.
        Paths.trimOversizedLogs()

        // Before the daemon comes up, and only when the file already exists:
        // an installed plist from an older yap names arguments this build no
        // longer takes. See `refreshIfStale`.
        LaunchAgent.refreshIfStale()

        let chosenModel = try Resolve.model()
        let key = Resolve.hotkey()
        let root = Config.resolveRoot()

        // Before the model loads, so a takeover never holds two copies of it
        // in memory at once.
        guard DaemonLock.claim() else { throw ExitCode.success }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // The status item goes up here, and the model is warmed behind it by
        // `Daemon.start`. That order is the difference between an app that is
        // on screen in a second and one that is invisible for the several
        // minutes a first-run model download takes.
        let daemon = Daemon(
            transcriber: chosenModel.makeTranscriber(),
            model: chosenModel,
            root: root,
            hotkey: key,
            echoTranscripts: echoTranscripts,
            debugHotkey: debugHotkey
        )
        daemon.start()
        // NSApplication holds its delegate weakly; `daemon` stays alive
        // because this frame does, and app.run() never leaves it.
        app.delegate = daemon

        let sources = interruptSources {
            warn("\nshutting down")
            // The source fires on the main queue, so this is already the main
            // actor — the handler's own signature just can't say so.
            //
            // Everything live is torn down in applicationWillTerminate,
            // which Cmd-Q and the menu's Quit item also route through.
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }

        var banner =
            "yap \(Yap.configuration.version ?? "?") · \(key.serialized) "
            + "\(Config.tapToToggle() ? "tap" : "hold") · \(chosenModel.id)"
        if Config.meetingDetectionEnabled() {
            banner += " · watching for meetings → \(root.path)"
        }
        banner += " · ^C to quit"
        warn(banner)

        // Hold the signal sources: they are cancelled when released, and a
        // cancelled source with the default disposition already ignored means
        // ^C and launchd stop would both do nothing.
        withExtendedLifetime(sources) { app.run() }
    }

    /// Re-exec through the real binary inside the .app when we were started
    /// through a symlink, so LaunchServices has an identity to publish.
    ///
    /// Homebrew's `/opt/homebrew/bin/yap` is a symlink into the bundle, and
    /// CFBundle derives `Bundle.main` from the path we were *exec'd with*, not
    /// the path that resolves to. Through the shim the main bundle is
    /// `/opt/homebrew/bin`, which is not a bundle, and LaunchServices then
    /// registers us with no bundle identifier: `lsappinfo info -only bundleid`
    /// answers `[ NULL ]` while still reporting
    /// `LSBundlePath=/Applications/yap.app`.
    ///
    /// That splits the menu bar icon in two. Thaw — the maintained Ice fork,
    /// and what this was measured against — names each item
    /// `<owner>:<status item autosave name>`, the owner being the owning
    /// process's bundle identifier when it has one and its process name when it
    /// does not. So the daemon is `yap:Item-0` while the same build launched
    /// from /Applications is `com.terrifiedbug.yap:Item-0` — one app, two
    /// identities, each with a section remembered separately. Both keys were
    /// sitting in its hidden section, and that is self-sustaining: with "new
    /// items appear in hidden" set, an item it has no section for is
    /// cmd-dragged there, AppKit persists the drag as our own saved position —
    /// 430 rewritten to 5518, measured — and we come back hidden on the next
    /// launch.
    ///
    /// Do not test `Bundle.main.bundleIdentifier` here. This binary carries its
    /// own `__TEXT,__info_plist` (Package.swift, so TCC can attribute the
    /// grants), so in-process it answers `com.terrifiedbug.yap` either way —
    /// measured, after it sent one debugging pass down the wrong road. The
    /// question LaunchServices actually asks is whether we were exec'd from
    /// inside a bundle, and the main bundle's path is the answer.
    ///
    /// The grants survive: TCC keys them on the code signature and that
    /// embedded identifier, so the microphone is recorded against
    /// `com.terrifiedbug.yap` and not against a path, and swapping the daemon
    /// onto the bundled path kept the event tap working. `execv` keeps the pid,
    /// so launchd sees one process throughout.
    private static func reexecInsideAppBundle() {
        guard !Bundle.main.bundlePath.hasSuffix(".app"),
            let running = Bundle.main.executablePath
        else { return }

        // Only worth doing when the far side is genuinely a bundled executable:
        // a plain `swift build` binary has no identity to recover. `real` is
        // fully resolved, so it is also what stops this exec'ing in a loop —
        // the second image resolves to the path it was started with.
        let real = URL(fileURLWithPath: running).resolvingSymlinksInPath()
        let contents = real.deletingLastPathComponent().deletingLastPathComponent()
        guard real.path != running,
            contents.lastPathComponent == "Contents",
            FileManager.default.fileExists(
                atPath: contents.appendingPathComponent("Info.plist").path)
        else { return }

        // Our own argv, untouched: `Bundle.main` comes from the exec'd path
        // rather than from `argv[0]`, so there is nothing to rewrite. `ps` will
        // keep showing the symlink in argv[0] while the image is the bundled
        // one.
        execv(real.path, CommandLine.unsafeArgv)

        // Only reachable if the exec failed, which is not fatal: yap carries on
        // under the process-name identity LaunchServices gives it, exactly as it
        // did before this existed.
        warn("note: couldn't re-exec via \(real.path): \(String(cString: strerror(errno)))")
    }
}

// MARK: - shared resolution

/// The config file beats the built-in default, resolved in one place.
///
/// There are no flags left to beat either of them: the daemon is the app, the
/// app is configured from the Settings window, and the Settings window writes
/// this same file.
enum Resolve {
    /// An unknown id in the config file only warns: bricking the daemon over a
    /// typo in a file edited weeks ago is worse than quietly running the
    /// default.
    static func model() throws -> TranscriptionModel {
        if let id = Config.dictationModel() {
            if let model = ModelRegistry.find(id) { return model }
            warn("warning: unknown model \"\(id)\" in \(Config.path.path) — using the default")
        }
        guard let model = ModelRegistry.recommended() else {
            throw ValidationError("no models registered")
        }
        return model
    }

    /// Same precedence as `model`, and the same reasoning about a bad value:
    /// warn and fall back to Fn rather than refuse to start. An unusable
    /// binding — a bare letter, which would swallow every one you type —
    /// is refused the same way.
    static func hotkey() -> HotkeyBinding {
        guard let name = Config.hotkey() else { return .fn }
        guard let binding = HotkeyBinding(parsing: name) else {
            warn("warning: unreadable hotkey \"\(name)\" in \(Config.path.path) — using fn")
            return .fn
        }
        if let reason = HotkeyBinding.validate(binding) {
            warn("warning: hotkey \"\(name)\" \(reason) — using fn")
            return .fn
        }
        return binding
    }
}

// MARK: - plumbing

/// Carries a result across the concurrency boundary in `runBlocking`. The
/// semaphore is the happens-before edge that makes reading it safe.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Bridge from ArgumentParser's synchronous `run()` into async work.
///
/// A detached task plus a semaphore, deliberately: nothing in the CLI needs
/// the main run loop until `NSApp.run()`, and blocking the calling thread is
/// far easier to reason about than spinning a nested one.
func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            box.result = .success(try await body())
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    // Signalled means written.
    return try box.result!.get()
}

/// Signal handling for the daemon.
///
/// Ignore the default disposition first: between `resume()` and a signal
/// arriving, the default disposition would still kill the process before the
/// handler ever ran. SIGTERM as well as SIGINT, because launchd stops the
/// agent with SIGTERM and the teardown puts the user's mic gain back.
///
/// The returned sources must be held for as long as the handler should fire.
/// They are cancelled when released, and a cancelled source over an
/// already-ignored disposition means ^C and a launchd stop would both do
/// nothing at all.
private func interruptSources(_ handler: @escaping @Sendable () -> Void)
    -> [DispatchSourceSignal]
{
    [SIGINT, SIGTERM].map { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }
}

/// `m:ss`, widening to `h:mm:ss` only once there is an hour to show. Every
/// duration a user reads goes through here: the menu bar's live session
/// counter, the line printed when a recording stops, and the timestamps in
/// transcript.md.
func formatElapsed(_ interval: TimeInterval) -> String {
    let total = Int(interval)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d", m, s)
}

/// Right-pad without truncating. `String.padding(toLength:)` cuts anything
/// longer than the target, which silently mangles a long model id.
func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}
