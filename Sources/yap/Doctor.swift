import AVFoundation
import ApplicationServices
import Darwin
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

/// Everything that has to be true before yap works, in one list.
///
/// Both halves of the app report here: dictation needs Accessibility, a clean
/// Fn key and the mic; recorded sessions additionally need system-audio
/// capture and somewhere to write. `yap run` runs the same list at startup, so
/// what `yap doctor` says is exactly what the daemon checked.
enum DoctorReport {
    static func run(
        recordingsRoot: URL,
        model: TranscriptionModel,
        hotkey: HotkeyMonitor.Key
    ) -> [Check] {
        var checks = [
            checkMicrophone(),
            checkAccessibility(),
        ]
        // Only Fn is at risk of being stolen by the system; the right-hand
        // modifiers have no such setting, so the row would be noise.
        if hotkey == .fn {
            checks.append(checkFnKeyMapping())
        }
        checks.append(checkSystemAudio())
        checks.append(checkRecordingsRoot(recordingsRoot))
        checks.append(checkModel(model))
        if let agent = checkLaunchAgent() { checks.append(agent) }
        return checks
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first use"),
                remediation: "hold the hotkey once, or start a recording; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation:
                    "System Settings → Privacy & Security → Microphone → enable for \(grantee())"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    /// TCC attributes a grant to the *responsible process*, and for a CLI
    /// binary that is whichever terminal launched it — not the binary. So the
    /// row the user has to tick in System Settings says Ghostty or iTerm or
    /// Terminal, and telling them to look for "yap" sends them hunting for a
    /// row that will never appear. Hence naming the parent here.
    ///
    /// Started by launchd instead, there is no terminal in the chain and the
    /// grant really does attach to the binary — so `grantee()` names the
    /// binary there, not the parent. "enable for launchd" would send someone
    /// looking for a row TCC never creates, which is the same failure this
    /// check exists to avoid.
    static func checkAccessibility() -> Check {
        if AXIsProcessTrusted() {
            return Check(name: "accessibility", status: .ok, remediation: nil)
        }
        return Check(
            name: "accessibility",
            status: .fail("not granted"),
            remediation:
                "System Settings → Privacy & Security → Accessibility → enable for \(grantee())"
        )
    }

    /// macOS routes Fn (🌐) to one of: Do Nothing / Change Input Source / Show Emoji / Start Dictation.
    /// We need "Do Nothing" so Fn is a clean modifier.
    static func checkFnKeyMapping() -> Check {
        guard let value = intDefault(domain: "com.apple.HIToolbox", key: "AppleFnUsageType")
        else {
            return Check(
                name: "fn key mapping",
                status: .warn("unset — system default may intercept Fn"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        }
        // Warn, never fail. The tap sees the Fn keypress whatever the system
        // does with it afterwards, so a stock mapping degrades dictation, it
        // does not break it. Failing here gated startup through allOK() and
        // stopped a fresh install running at all on a machine whose Fn key
        // was still set to whatever macOS shipped.
        switch value {
        case 0:
            return Check(name: "fn key mapping", status: .ok, remediation: nil)
        case 1, 2, 3:
            let uses = [1: "Change Input Source", 2: "Show Emoji & Symbols", 3: "Start Dictation"]
            return Check(
                name: "fn key mapping",
                status: .warn("set to \(uses[value] ?? "another action")"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        default:
            return Check(
                name: "fn key mapping",
                status: .warn("unknown value \(value)"),
                remediation: "System Settings → Keyboard → Press 🌐 key to → Do Nothing"
            )
        }
    }

    /// There is no public API to query the system-audio-capture TCC state
    /// without side effects, so all we can do is describe the flow.
    static func checkSystemAudio() -> Check {
        Check(
            name: "system audio",
            status: .warn("state unknowable until first use — will prompt on first recording"),
            remediation:
                "if recordings come out silent: System Settings → Privacy & Security → Screen & System Audio Recording"
        )
    }

    /// Deliberately creates nothing. `yap doctor` on a machine that only ever
    /// dictates shouldn't leave an empty ~/Recordings behind, and asking
    /// whether the nearest existing ancestor is writable answers the same
    /// question the create would have.
    static func checkRecordingsRoot(_ root: URL) -> Check {
        let fm = FileManager.default
        var probe = root
        while !fm.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        guard fm.isWritableFile(atPath: probe.path) else {
            return Check(
                name: "recordings folder",
                status: .fail("\(probe.path) is not writable"),
                remediation:
                    "fix permissions, or set recordings_dir in \(Config.path.path)"
            )
        }
        return Check(name: "recordings folder", status: .ok, remediation: nil)
    }

    /// Never discover a missing model after an important meeting — or on the
    /// first hotkey press. A warning, not a failure: `yap run` warms the model
    /// at startup and will fetch it, you just wait for the download once.
    static func checkModel(_ model: TranscriptionModel) -> Check {
        // Reported ahead of a missing download because it is the one the user
        // has to act on: a download fixes itself on first use, a model that
        // cannot time its output never will, and every recorded session is
        // quietly skipped until the config changes.
        if Config.transcriptionEnabled(), !model.supportsSessions {
            return Check(
                name: "model",
                status: .warn("\(model.id) cannot transcribe recorded sessions"),
                remediation:
                    "dictation works; sessions are skipped until dictation.model is one that "
                    + "can time its output — see `yap models list`"
            )
        }
        if ModelStore.isDownloaded(model) {
            return Check(name: "model", status: .ok, remediation: nil)
        }
        return Check(
            name: "model",
            status: .warn("\(model.id) not downloaded (~\(model.sizeMB) MB)"),
            remediation: "run `yap models download \(model.id)`, or `yap setup`"
        )
    }

    /// Whether the installed launch agent is actually running.
    ///
    /// Every check above answers for *this* process, and under launchd that is
    /// a different one. The gap that matters is Accessibility: run from a
    /// terminal, `AXIsProcessTrusted` reports the terminal's grant, so doctor
    /// says "ok" while the agent — which needs a grant against the binary
    /// itself — exits on startup and leaves nothing running. The grant is also
    /// keyed to the binary's code signature, so an unsigned rebuild silently
    /// invalidates it while Settings still shows the row ticked.
    ///
    /// Reported as "not running" rather than blamed on Accessibility: the
    /// daemon exits 0 for several reasons and only its log knows which, so
    /// this points there instead of guessing.
    ///
    /// Nil when no agent is installed — running yap by hand is not a fault.
    static func checkLaunchAgent() -> Check? {
        guard FileManager.default.fileExists(atPath: Install.plistURL.path) else { return nil }
        let listing = Agent.run(["list", Install.label])
        guard listing.status == 0 else {
            return Check(
                name: "launch agent",
                status: .warn("installed but not loaded"),
                remediation: "run `yap install --launch-at-login` to load it"
            )
        }
        // `launchctl list <label>` prints the job dictionary, and the PID key
        // is only there while it is up.
        guard !listing.output.contains("\"PID\" =") else {
            return Check(name: "launch agent", status: .ok, remediation: nil)
        }
        return Check(
            name: "launch agent",
            status: .warn("loaded but not running — it started and exited"),
            remediation:
                "see \(Paths.stderrLog.path) for why. Most often Accessibility: launchd runs "
                + "the binary directly, so the grant has to name \(agentBinary()), and a "
                + "rebuild invalidates it — remove the stale row in System Settings → Privacy "
                + "& Security → Accessibility and add it again, then "
                + "`launchctl kickstart -k gui/$(id -u)/\(Install.label)`"
        )
    }

    /// The binary the agent actually launches, read back from its own plist.
    ///
    /// Not the canonical path: `Install` falls back to the running executable
    /// when /usr/local/bin/yap is absent, so a dev install runs from the build
    /// directory. Naming the wrong binary here sends someone to grant
    /// Accessibility to a file launchd never runs, which fixes nothing and
    /// looks like the advice was wrong.
    private static func agentBinary() -> String {
        guard
            let data = try? Data(contentsOf: Install.plistURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any],
            let args = plist["ProgramArguments"] as? [String],
            let binary = args.first
        else { return "the installed yap binary" }
        return binary
    }

    /// One preference read instead of a `defaults` fork. CFPreferences goes
    /// through cfprefsd exactly as the `defaults` tool does, and this check
    /// runs at every daemon start, not just on `yap doctor`.
    ///
    /// Both shapes accepted: System Settings writes an integer, but a domain
    /// edited by hand can hold the same value as a string.
    private static func intDefault(domain: String, key: String) -> Int? {
        let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        return value as? Int ?? (value as? String).flatMap(Int.init)
    }

    /// The name the permission is actually filed under — see the note on
    /// `checkAccessibility`.
    ///
    /// The parent, except when the parent is launchd. TCC files a CLI
    /// binary's grant against the responsible process, which is the terminal
    /// that launched it; launchd is not a responsible process, so under the
    /// login agent the grant attaches to the executable itself. That is also
    /// what `checkLaunchAgent` tells people further down, and the two have to
    /// agree or the report contradicts itself.
    private static func grantee() -> String {
        // Unreadable parent. Says nothing about whether launchd is in the
        // chain, so it must not pick either specific answer — the vague one
        // is right here, and is what this returned before launchd was
        // special-cased.
        guard let parent = parentProcessName() else { return "your terminal" }
        guard parent == "launchd" else { return parent }
        // Whatever launchd actually started, which is the file the grant is
        // keyed to. Not `agentBinary()`: a daemon run from somewhere other
        // than the installed plist would be misreported by it.
        return Bundle.main.executablePath ?? "the yap binary"
    }

    /// The parent's executable name.
    ///
    /// `proc_pidpath` rather than forking `ps -o comm=`: same answer — the
    /// last component of the executable path — without a process spawn on the
    /// daemon's startup path. Deliberately not `MeetingDetector.appName`,
    /// which resolves the enclosing `.app` and returns nil for anything
    /// without one; `grantee()` above has to be able to tell a launchd parent
    /// from an unreadable one, and nil cannot say which.
    private static func parentProcessName() -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(PATH_MAX))
        let length = buffer.withUnsafeMutableBytes {
            proc_pidpath(getppid(), $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        let path = String(decoding: buffer[..<Int(length)], as: UTF8.self)
        return path.isEmpty ? nil : (path as NSString).lastPathComponent
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool { firstFailure(checks) == nil }

    /// The first hard failure, for callers that have to name one.
    static func firstFailure(_ checks: [Check]) -> Check? {
        checks.first {
            if case .fail = $0.status { return true }
            return false
        }
    }
}
