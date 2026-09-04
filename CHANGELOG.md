# Changelog

What changed, for the person using yap. The release workflow reads the section
matching the tag and publishes it as the release notes, so a version with no
section here does not ship.

Releases before 0.3.0 are on the
[Releases page](https://github.com/TerrifiedBug/yap/releases).

## 0.3.0

yap is an app now. Everything that used to need a terminal happens in the menu
bar, and the command line is down to the one thing a terminal is genuinely
better at.

### Setting up

- Launch yap from Applications and it asks for what it needs — Accessibility
  first, then the microphone — each one click from the right pane of System
  Settings.
- The menu bar mark appears straight away and says what it is doing while the
  model downloads, instead of yap being invisible for the first few minutes of
  its life. Holding the key during that says so rather than recording into
  nothing.
- A missing Accessibility grant no longer stops yap. It waits, and starts
  listening the moment you tick the box — no relaunch.
- If macOS has the 🌐 key doing something else, the menu says which action and
  offers to open Keyboard settings.

### The hotkey

- Set it by pressing it: Settings → Dictation, click the field, hold what you
  want.
- Any modifier on its own, now including the left-hand ones — or a chord like
  ⌘⇧Space, or a function key like F5. A chord is swallowed while yap holds it,
  so the app underneath never sees the keystroke.

### Settings

- A new General pane: launch at login, updates, and a button that reveals the
  logs in Finder.
- yap can update itself. "Check Now" downloads the new build, checks it is
  signed by the same identity as the one running, and offers
  "Update to x.y.z · Restart" in the menu — never while a recording is in
  flight. There is no background check: yap makes no network request of its own
  after the model is on disk unless you ask for one.

### Recordings

- The transcript banner gained **Delete**. It moves the session to the Trash and
  offers Undo, so a mis-click on a banner that appeared by itself costs nothing.

### Faster where you can feel it

- The recording pill now appears when you press the key rather than when the
  microphone finishes opening: **1.9 ms** instead of 70 ms, measured over ten
  presses. Transcription itself is unchanged — 39 ms for a five-second clip.

### Removed

- `yap setup`, `yap install`, `yap start`, `yap stop`, `yap doctor`,
  `yap record` and `yap models`. The menu bar does all of it.
  `yap bench --audio FILE` stays, at
  `/Applications/yap.app/Contents/MacOS/yap`.
- The `--model`, `--hotkey`, `--no-overlay`, `--newline` and `--skip-doctor`
  flags. Settings covers every one of them.
- Homebrew no longer puts a `yap` command on your PATH.

### Upgrading

`brew upgrade --cask yap` handles everything, including rewriting the login
item that 0.2 left behind. If you installed from the .dmg and use launch at
login, launch yap once after replacing the app — otherwise the old login item
keeps trying to start it with an argument this version no longer takes.
