import Foundation

/// The two shell hooks from config: `on_start`, given a session folder the
/// moment its tracks are recording, and `on_stop`, given one whose transcript
/// is written. Both get the folder as their only argument.
///
/// Fire and forget. The process is spawned and never waited on, so a hook that
/// hangs costs nothing but its own pid; a hook that cannot launch is reported
/// through `onFailure` and the recorder carries on as if there were none.
enum Hook {
    static func run(_ command: String, dir: URL, onFailure: (String) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `$0` rather than interpolation: the folder name can carry a meeting
        // title with quotes and spaces in it, and the shell parses `command`
        // exactly once.
        task.arguments = ["-c", "\(command) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            onFailure("hook failed to launch: \(error)")
        }
    }
}
