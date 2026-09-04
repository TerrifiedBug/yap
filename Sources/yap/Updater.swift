import AppKit
import CryptoKit
import Foundation
import Security

/// Keeps yap current from its own GitHub Releases.
///
/// No Sparkle. The whole mechanism is: read one JSON document, download a zip,
/// check its digest, check its signature against the one this process is
/// running under, and swap the bundle — about two hundred lines against a
/// framework and an appcast, and it is the only network access yap makes after
/// the model is on disk.
///
/// Nothing is replaced without a click. The download and every check happen in
/// the background, and the menu then offers "Update to x.y.z · Restart" —
/// which is also the only place the app can decide it is a bad moment, because
/// a restart during a meeting would cost the recording.
///
/// The signature check is what makes the swap safe: the staged app has to be
/// signed by the same team as the running one, so a poisoned feed cannot
/// install something else, and TCC keeps the Accessibility and microphone
/// grants because they are keyed on that identity.
@MainActor
final class Updater {
    static let shared = Updater()

    enum State {
        case idle
        /// Not an installed .app, or not signed by a team we can compare
        /// against — a `swift build` binary, in other words. Nothing to do.
        case unavailable(String)
        case checking
        case upToDate(Date)
        case downloading(String)
        case ready(version: String, app: URL)
        case failed(String)

        var description: String {
            switch self {
            case .idle: return "Not checked yet"
            case .unavailable(let why): return why
            case .checking: return "Checking…"
            case .upToDate(let when):
                let time = DateFormatter.localizedString(
                    from: when, dateStyle: .none, timeStyle: .short)
                return "Up to date · \(time)"
            case .downloading(let version): return "Downloading \(version)…"
            case .ready(let version, _): return "\(version) ready — restart from the menu"
            case .failed(let why): return "Couldn't check: \(why)"
            }
        }
    }

    private(set) var state: State = .idle {
        didSet { for observer in observers.values { observer(state) } }
    }

    private var observers: [UUID: (State) -> Void] = [:]

    /// The daily timer, and the one-shot that runs the first check a little
    /// after launch. Both nil while automatic checks are off, which is the
    /// only state in which nothing of yap's is scheduled at all.
    private var timer: Timer?
    private var firstCheck: DispatchWorkItem?
    private var inFlight = false

    /// Overridable so the update path can be exercised against a local feed
    /// without publishing a release: `YAP_RELEASES_URL=http://…`. Not a
    /// setting — there is no reason for a user to point yap at another feed,
    /// and every reason not to make it easy.
    private let feedURL = URL(
        string: ProcessInfo.processInfo.environment["YAP_RELEASES_URL"]
            ?? "https://api.github.com/repos/TerrifiedBug/yap/releases/latest"
    )!

    /// The team the running code is signed by. Nil for an unsigned or
    /// ad-hoc-signed build, which is what makes those ineligible: there would
    /// be nothing to hold the replacement to.
    private let teamIdentifier: String? = Updater.runningTeamIdentifier()

    private init() {
        if !Bundle.main.bundlePath.hasSuffix(".app") || teamIdentifier == nil {
            state = .unavailable("Updates only apply to the installed app")
        }
    }

    private var available: Bool {
        if case .unavailable = state { return false }
        return true
    }

    // MARK: - observation

    /// A map rather than one closure: the menu bar and an open Settings window
    /// both want the state, and the second one to subscribe must not silently
    /// unhook the first.
    @discardableResult
    func observe(_ handler: @escaping (State) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        handler(state)
        return token
    }

    func unobserve(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    // MARK: - scheduling

    /// One check shortly after launch, then one a day.
    ///
    /// The 30 s delay keeps it off the startup path — the model has just
    /// finished loading and the first press is the thing that matters. The
    /// hour of tolerance lets the OS coalesce the daily wake with something
    /// else it was going to do anyway.
    func startAutomaticChecks() {
        guard available, timer == nil, firstCheck == nil else { return }
        let first = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.firstCheck = nil
                self?.checkNow()
            }
        }
        firstCheck = first
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: first)

        let daily = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkNow() }
        }
        daily.tolerance = 3_600
        timer = daily
    }

    func stopAutomaticChecks() {
        firstCheck?.cancel()
        firstCheck = nil
        timer?.invalidate()
        timer = nil
    }

    /// Manual check. Runs even with automatic checks off — turning the daily
    /// request off is not the same as never wanting to know.
    func checkNow() {
        guard available, !inFlight else { return }
        if case .ready = state { return }
        inFlight = true
        Task { [weak self] in
            await self?.check()
            self?.inFlight = false
        }
    }

    /// Delete anything left in the staging directory. Called at launch: an
    /// interrupted download is not worth resuming, and a stale extraction is
    /// several megabytes of nothing.
    static func cleanStaging() {
        let dir = Paths.updatesDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries { try? FileManager.default.removeItem(at: entry) }
    }

    // MARK: - the check

    private func check() async {
        state = .checking
        do {
            guard let release = try await fetchLatest() else {
                state = .upToDate(Date())
                return
            }
            state = .downloading(release.version)
            let staged = try await Self.stage(release)
            try verify(staged)
            state = .ready(version: release.version, app: staged)
            warn("update \(release.version) staged at \(staged.path)")
        } catch {
            let reason = (error as? UpdateError)?.reason ?? error.localizedDescription
            warn("update check failed: \(reason)")
            state = .failed(reason)
        }
    }

    private struct Release {
        let version: String
        let zip: URL
        let checksum: URL
    }

    private struct Feed: Decodable {
        let tagName: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    /// Nil when the published release is not newer than what is running.
    private func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError("release feed returned \(http.statusCode)")
        }
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        let version = feed.tagName.hasPrefix("v")
            ? String(feed.tagName.dropFirst()) : feed.tagName
        guard Self.isNewer(version, than: Yap.configuration.version ?? "0") else { return nil }

        guard
            let zip = feed.assets.first(where: { $0.name == "yap-\(version).zip" }),
            let sum = feed.assets.first(where: { $0.name == "yap-\(version).zip.sha256" })
        else { throw UpdateError("release has no zip") }
        return Release(
            version: version, zip: zip.browserDownloadURL, checksum: sum.browserDownloadURL)
    }

    /// Dotted integer components, left to right. Anything unparseable counts
    /// as zero rather than throwing: a tag we cannot read is not a reason to
    /// stop checking tomorrow.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let new = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let old = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(new.count, old.count) {
            let lhs = index < new.count ? new[index] : 0
            let rhs = index < old.count ? old[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    /// Download, check the digest, unpack. Off the main actor: the digest and
    /// the unpack are the only genuinely slow parts of an update, and neither
    /// touches anything the UI owns.
    private nonisolated static func stage(_ release: Release) async throws -> URL {
        let dir = Paths.updatesDirectory
        let zip = dir.appendingPathComponent("yap-\(release.version).zip")
        try? FileManager.default.removeItem(at: zip)

        let (downloaded, response) = try await URLSession.shared.download(from: release.zip)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError("download returned \(http.statusCode)")
        }
        try FileManager.default.moveItem(at: downloaded, to: zip)

        let (sumData, _) = try await URLSession.shared.data(from: release.checksum)
        guard
            let expected = String(decoding: sumData, as: UTF8.self)
                .split(whereSeparator: \.isWhitespace).first
        else {
            try? FileManager.default.removeItem(at: zip)
            throw UpdateError("checksum file is empty")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: zip))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased() else {
            try? FileManager.default.removeItem(at: zip)
            throw UpdateError("checksum mismatch")
        }

        // In process, because yap spawns nothing. See `ZipArchive` for what
        // it does and does not restore, and why that is enough for the
        // signature check below to pass.
        let unpacked = dir.appendingPathComponent(release.version, isDirectory: true)
        try? FileManager.default.removeItem(at: unpacked)
        do {
            try ZipArchive.extract(zip, to: unpacked)
        } catch {
            try? FileManager.default.removeItem(at: zip)
            try? FileManager.default.removeItem(at: unpacked)
            throw UpdateError("couldn't unpack the download: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: zip)

        let app = unpacked.appendingPathComponent("yap.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw UpdateError("download contains no yap.app")
        }
        return app
    }

    /// The staged app must be signed by the same team as the running one.
    ///
    /// This is the whole security model of the updater, and it is also what
    /// keeps the permissions: TCC keys Accessibility and the microphone on the
    /// signing identity, so a build from the same team inherits both, and one
    /// from anywhere else is refused before it can be run at all.
    private func verify(_ app: URL) throws {
        guard let team = teamIdentifier else { throw UpdateError("this build is not signed") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
            let code
        else {
            try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
            throw UpdateError("staged app has no signature")
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
            let requirement,
            SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
        else {
            try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
            throw UpdateError("signature mismatch")
        }

        // Downloaded by us, verified by us: without this LaunchServices puts
        // the "downloaded from the internet" sheet in front of the relaunch,
        // which for a menu-bar app nobody is looking at means it simply never
        // comes back.
        for path in [app.path, app.appendingPathComponent("Contents/MacOS/yap").path] {
            removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    // MARK: - the swap

    /// Replace the running bundle and restart into it.
    ///
    /// The relaunch is deliberately not a fork: a second instance takes the
    /// daemon lock and the old one stands down, which is the mechanism that
    /// already handles every other way two yaps can exist at once.
    func installAndRestart() {
        guard case .ready(let version, let staged) = state else { return }
        let live = Bundle.main.bundleURL
        do {
            try swap(staged: staged, live: live)
        } catch {
            let reason = FileManager.default.isWritableFile(atPath: live.deletingLastPathComponent().path)
                ? error.localizedDescription
                : "can't write \(live.deletingLastPathComponent().path) — update with brew or the DMG"
            warn("update install failed: \(reason)")
            state = .failed(reason)
            return
        }
        Self.cleanStaging()
        warn("updated to \(version) — restarting")

        if LaunchAgent.isLoaded {
            LaunchAgent.kickstart()
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: live, configuration: configuration)
        }
    }

    private func swap(staged: URL, live: URL) throws {
        do {
            try FileManager.default.replaceItem(
                at: live, withItemAt: staged, backupItemName: nil, options: [],
                resultingItemURL: nil)
        } catch {
            // A busy or cross-volume replace: move the old one aside and put
            // the new one in its place. Two renames rather than one atomic
            // swap, so the failure window is real but tiny.
            let aside = Paths.updatesDirectory.appendingPathComponent("yap-previous.app")
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: live, to: aside)
            do {
                try FileManager.default.moveItem(at: staged, to: live)
            } catch {
                // Put it back rather than leave the machine with no yap.
                try? FileManager.default.moveItem(at: aside, to: live)
                throw error
            }
        }
    }

    // MARK: -

    private static func runningTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(
            unsafeBitCast(code, to: SecStaticCode.self),
            SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess,
            let dictionary = info as? [String: Any],
            let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        else { return nil }
        return team
    }

    private struct UpdateError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}
