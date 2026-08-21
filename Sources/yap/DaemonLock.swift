import Darwin
import Foundation

/// One daemon owns the hotkey.
///
/// Nothing else enforces that, and there are two ways the daemon starts. The
/// login item is a LaunchAgent, so launchd execs the binary directly; the .app
/// in /Applications is launched by LaunchServices when you double-click it.
/// The two routes are invisible to each other — only the LaunchServices one
/// registers as an application, which is why `launchctl list` shows a
/// double-clicked yap as `application.com.terrifiedbug.yap.…` and the agent
/// merely as its label — so macOS's own "this app is already running" handling
/// never sees the pair. Both processes then install an event tap on the same
/// key, and every press is captured twice and typed twice.
///
/// The cask makes that routine rather than exotic. Its postflight runs
/// `launchctl kickstart -k`, which starts the login job whether or not it was
/// already running, so anyone whose daemon came up by double-click — or who
/// used "Quit yap" and started it again from Applications — gets a second one
/// on their next `brew upgrade`, the old image and the new listening together.
///
/// A POSIX record lock rather than a pid file: the kernel holds it, it is
/// released however the holder dies including a crash, and `F_GETLK` names the
/// holder, so there is no stale file to sweep up and no recorded pid that may
/// since have been recycled onto something unrelated.
enum DaemonLock {
    /// Held for the life of the process. Closing this descriptor drops the
    /// lock, so nothing ever closes it.
    private static var descriptor: Int32 = -1

    /// Take the hotkey, replacing a daemon that already holds it.
    ///
    /// Last launch wins, deliberately. You either double-clicked the app or
    /// Homebrew replaced the binary under the running one, and both mean "this
    /// image, from now on" — refusing to start would leave an upgrade running
    /// the code it just replaced, which is the worst shape for a bug because
    /// `yap --version` reads the new binary on disk and agrees with the
    /// version you installed.
    ///
    /// The incumbent gets SIGTERM, which its own handler routes through
    /// `applicationWillTerminate`: a meeting recording in flight is finalized
    /// and transcribes on the next start rather than losing its meta.json, and
    /// the mic gain lease is given back. It exits 0, so `KeepAlive
    /// SuccessfulExit:false` leaves the job down instead of racing us for it.
    ///
    /// Five seconds later, anything still holding the lock is wedged rather
    /// than busy — a clean exit is a few file writes — and by then backing out
    /// is not an option: the SIGTERM has been delivered, so the incumbent dies
    /// the moment it recovers, and returning false here would leave the
    /// machine with no daemon at all. So it escalates to SIGKILL, which the
    /// kernel answers by dropping the lock with the process. If that daemon
    /// was the login job, launchd sees the abnormal exit and brings it back,
    /// and the two of us settle it the ordinary way — one of us ends up
    /// holding the lock, never both.
    ///
    /// False means the hotkey could not be taken and this process must not
    /// run: the only ways out above are a signal the kernel refused.
    static func claim() -> Bool {
        let path = Paths.daemonLock.path
        let handle = open(path, O_CREAT | O_RDWR, 0o600)
        guard handle >= 0 else {
            // A lock we cannot take is not a reason to refuse to dictate. The
            // guard exists to stop a duplicate typing everything twice, and
            // losing it is strictly better than losing the daemon.
            warn("warning: cannot open \(path) (\(errnoText())) — starting without the daemon lock")
            return true
        }
        descriptor = handle

        if take(handle) { return true }
        guard let holder = holder(of: handle) else {
            // It was held a moment ago and is not held now, so the holder
            // exited between the two calls. One more attempt, and if that
            // fails something else took it in the same instant — treat it the
            // same as a live incumbent that will not yield.
            return take(handle)
        }

        warn("another yap daemon has the hotkey (pid \(holder)) — replacing it")
        // ESRCH means it exited while we were reading the lock, which is the
        // outcome we wanted anyway; the wait below sees the lock go.
        if kill(holder, SIGTERM) != 0, errno != ESRCH {
            warn("could not signal pid \(holder) (\(errnoText())) — leaving it the hotkey")
            return false
        }
        // Long enough for the other side to finalize a session it was writing,
        // short enough that launch-at-login is not held up by a wedged
        // process. Polling rather than waiting on the lock, because F_SETLKW
        // would block forever against exactly that.
        for _ in 0..<100 {
            usleep(50_000)
            if take(handle) { return true }
        }
        warn("pid \(holder) ignored SIGTERM — killing it")
        if kill(holder, SIGKILL) != 0, errno != ESRCH {
            warn("could not kill pid \(holder) (\(errnoText())) — leaving it the hotkey")
            return false
        }
        // SIGKILL is not synchronous with the exit, and the lock goes when the
        // process does, so this waits for the kernel rather than for the
        // daemon. A second is orders of magnitude more than it takes.
        for _ in 0..<20 {
            usleep(50_000)
            if take(handle) { return true }
        }
        warn("pid \(holder) still holds the hotkey after SIGKILL — not starting")
        return false
    }

    // MARK: -

    /// Whole-file write lock, non-blocking.
    private static func take(_ handle: Int32) -> Bool {
        var lock = Darwin.flock(
            l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        return fcntl(handle, F_SETLK, &lock) == 0
    }

    /// The pid holding the lock, straight from the kernel, or nil if nobody
    /// holds it.
    private static func holder(of handle: Int32) -> pid_t? {
        var probe = Darwin.flock(
            l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(handle, F_GETLK, &probe) == 0, probe.l_type != Int16(F_UNLCK), probe.l_pid > 0
        else { return nil }
        return probe.l_pid
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
