import AVFoundation
import ApplicationServices
import ArgumentParser
import Foundation

/// First-run walkthrough: permissions, then the model.
///
/// Order matters. The model download is several hundred megabytes and a
/// one-off ANE compile on top; making someone sit through it only to discover
/// afterwards that Accessibility was never granted is the worst possible
/// sequence. Permissions first, and each one exits rather than continuing
/// half-configured.
struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Walk through first-run permission setup."
    )

    func run() throws {
        print("yap setup")
        print("=========")
        print()
        print("yap needs two permissions:")
        print("  1. Accessibility — to detect the hotkey globally and inject text at the cursor.")
        print("  2. Microphone — to record audio while you hold the hotkey.")
        print()
        // TCC files the grant against the responsible process, which for a CLI
        // binary is the terminal that launched it. Nobody will find a "yap"
        // row in System Settings, so say so before they go looking.
        print("Run from a terminal, these attach to your terminal app")
        print("(Terminal/iTerm/Ghostty/etc.), not to yap itself.")
        print()
        print("Launched at login they do not: launchd runs the binary directly, so it")
        print("needs its own grant. `yap install --launch-at-login` says which one.")
        print()

        try waitForAccessibility()
        print()
        try waitForMicrophone()
        print()
        try downloadDefaultModel()
        print()
        print("✓ all set. Run `yap` to start the daemon.")

        // Everything above answered for this process. If a login agent is
        // installed, it is a different one, and reporting success without
        // saying so is how "setup says granted" coexists with "nothing runs".
        if let agent = DoctorReport.checkLaunchAgent(), case .warn(let detail) = agent.status {
            print()
            print("! the login agent is a separate case: \(detail)")
            if let fix = agent.remediation { print("  → \(fix)") }
        }
    }

    /// Fetch the model up front so the first hotkey press isn't a surprise
    /// several-hundred-MB download followed by a one-off ANE compile.
    ///
    /// Resolved the same way the daemon resolves it, so someone who already
    /// picked a model in the config file doesn't get handed a different one.
    private func downloadDefaultModel() throws {
        let model = try Resolve.model(nil)
        if ModelStore.isDownloaded(model) {
            print("✓ \(model.id) already downloaded")
            return
        }

        print("→ downloading \(model.id) (~\(model.sizeMB) MB), then compiling for the ANE...")
        do {
            try runBlocking { try await model.makeTranscriber().warmUp() }
        } catch {
            print("  ✗ download failed: \(error)")
            throw ExitCode(1)
        }
    }

    private func waitForAccessibility() throws {
        if AXIsProcessTrusted() {
            print("✓ accessibility already granted")
            return
        }

        print("→ opening accessibility prompt...")
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        print()
        print("  1. Toggle your terminal on in the Accessibility list.")
        print("  2. Re-run `yap setup` — macOS only picks up the grant on a fresh process.")
        throw ExitCode(0)
    }

    private func waitForMicrophone() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            print("✓ microphone already granted")
            return
        case .denied, .restricted:
            print("✗ microphone is denied — macOS won't re-prompt once denied.")
            print("  opening Settings → Privacy & Security → Microphone...")
            openSettings("Privacy_Microphone")
            print("  enable your terminal, then re-run `yap setup`.")
            throw ExitCode(1)
        case .notDetermined:
            print("→ requesting microphone access...")
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            if granted {
                print("  ✓ microphone granted")
            } else {
                print("  ✗ microphone denied")
                throw ExitCode(1)
            }
        @unknown default:
            print("? microphone in unknown state")
        }
    }

    private func openSettings(_ pane: String) {
        let url = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [url]
        try? task.run()
    }
}
