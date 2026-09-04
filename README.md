<p align="center">
  <img src="packaging/yap.png" width="128" alt="">
</p>

# yap

Dictation and meeting transcription for macOS, all of it on your Mac.

Hold a key, talk, let go. The text turns up at your cursor about 60 ms later.
No account, no upload. The network gets used once, to fetch the model.

## Install

```sh
brew install --cask terrifiedbug/tap/yap
```

Or download the .dmg from [Releases](https://github.com/TerrifiedBug/yap/releases)
and drag yap to Applications.

Then launch yap from Applications. The menu bar mark appears straight away and
walks you through the rest: it asks for Accessibility, then the microphone, and
pulls the model down in the background. That is 220 MB, once, and then you are
offline: nothing you say ever leaves the machine, and yap makes no network
request of its own again unless you ask it to check for a new version.

Builds are signed with a Developer ID certificate and notarized by Apple, so
there is no Gatekeeper prompt. Apple Silicon only, because the model runs on
the Neural Engine.

## Use

Hold `fn`, speak, release. A small pill shows up while the mic is live, and the
same mark sits in the menu bar the whole time yap is running.

Everything else is in that menu: start a recording, copy the last transcript,
open Settings, quit. Dictation and the meeting recorder share one process and
one loaded model. The recorder takes your mic and the system audio as two
separate tracks and gives you one transcript, with timings and speaker labels.

"Settings…" opens a window covering every setting below, and every change lands
immediately — the daemon does not need a restart to notice. General has the
login item, updates and a way to the logs; Dictation has the hotkey, which you
set by clicking the field and pressing the key or chord you want. "Open Config
File" at the bottom opens the JSON, for anyone who would rather type.

If `fn` is set to do something else on your Mac, the menu says so and offers to
open Keyboard settings.

"Copy Last Transcript" is there for the press that landed in the wrong window.
yap holds the most recent one in memory and nowhere else.

"Quit yap" stops it until you launch it again, or until your next login if
"Launch at login" is on.

Settings → General has a "Check Now" button. It asks GitHub Releases once,
downloads the new build, verifies its signature against the one yap is running
under, and puts "Update to x.y.z · Restart" in the menu. Nothing is replaced
until you click that, and it is never offered while a recording is in flight.
There is no automatic check and no timer behind it: yap does nothing at all
while it is idle.

One daemon holds the hotkey at a time. Start another — from Applications, from
a terminal, or because an upgrade restarted the login item — and the new one
takes over and the old one stops, so a press is never captured or typed twice.

If you run a menu bar manager — Ice, Thaw, Bartender — and the mark is nowhere
to be seen, look in its hidden section. Managers that file newly-appeared items
there catch yap the first time it shows up. Reveal that section, then hold
Command and drag the mark out of it once; it stays where you put it.

There is one command, and it is not needed for anything you do day to day:

```sh
/Applications/yap.app/Contents/MacOS/yap bench --audio FILE
```

It times transcription on your own audio. `--version` prints the version.

## Configuration

`~/.config/yap/config.json`. Every key is optional, and this file is the only
store there is. The Settings window is a GUI over it — nothing is kept anywhere
else — and "Open Config File" in it opens the JSON, filled in with the
defaults. An upgrade adds a line for anything new, so the file always lists
what this yap can do. Your own values are never touched.

```json
{
  "recordings_dir": "~/Recordings",
  "meeting_detection": false,
  "meeting_auto_record": false,
  "meeting_excluded_apps": [],
  "mic_voice_processing": true,
  "on_stop": "my-hook",
  "transcription": { "enabled": true },
  "dictation": {
    "model": "parakeet-tdt-ctc-110m",
    "hotkey": "fn",
    "tap_to_toggle": false,
    "overlay": true,
    "newline_after_release": false,
    "mute_output": false
  }
}
```

Save it and yap picks it up. The hotkey, `tap_to_toggle`, the overlay,
`mute_output`, `newline_after_release`, `meeting_detection`,
`meeting_auto_record` and `meeting_excluded_apps` all change on the spot. A
new `model` or `recordings_dir` wants a restart, and yap says so when it sees
one.

`hotkey` is a modifier held on its own — `fn`, `rightOption`, `rightCommand`,
`rightControl`, `rightShift`, `leftOption`, `leftControl`, `leftShift` — or a
chord like `cmd+shift+space`, or a lone function key like `f5`. The recorder in
Settings → Dictation writes it for you; typing it by hand is case-insensitive
and ignores `-` and `_`. A chord is swallowed while yap holds it, so the app
underneath never sees it.

`newline_after_release` hits Return once the text is in, which is what you want
for chat boxes.

`mute_output` silences the speakers while the key is down. Your mic hears the
room and the room includes whatever you are playing, so a video behind a press
gets transcribed along with you. Off by default because you can hear it happen.

`tap_to_toggle` turns the press into a switch: tap the key, talk with your hands
free, tap again to finish. A press you actually hold still ends when you let go,
so both habits work and a hold never leaves the mic latched open.

`meeting_detection` offers to record when something else grabs the mic. Off by
default, and nothing is watching until you turn it on. When the meeting app
exposes a window title, yap uses it in the prompt, recording folder and
transcript.

`meeting_auto_record` skips that prompt and starts recording immediately, with a
visible Stop action. It only has an effect when `meeting_detection` is on, and is
off by default.

`meeting_excluded_apps` is the bundle identifiers of apps that never trigger the
meeting prompt — the list behind the "Ignore <App>" button on the prompt and the
"Ignore" button on the auto-record banner. Clicking it adds the app here, ends
any recording that button started, and yap says nothing about that app again.
Manage the list under Meetings in the Settings window: it shows each app by icon
and name, and the + and − under it add one ahead of time or stop ignoring the
one you select. Detection stays fail-open — an app you have never excluded still
gets offered, even one yap has never heard of.

`mic_voice_processing` cancels speaker echo on the mic track. On by default: a
call coming out of your speakers goes back into the mic. Without it, the other
side gets transcribed twice, the second time as you. If some audio route
returns silence instead, yap notices inside a second and restarts the mic raw.

`on_stop` runs a command after each recording with the session folder as its
argument.

`transcription` is automatic transcription of recordings, on by default.
Dictation ignores it, since the hotkey always transcribes. When one finishes
while the daemon is running, a banner drops under the menu bar with Open and
Name… buttons. Open reveals the transcript in Finder; Name… renames the folder
and updates its metadata and heading. Turn it off to use yap as a plain
recorder: `on_stop` then fires when the recording stops rather than after the
transcript. Nothing is lost either way. Turn it back on, restart, and yap works
through every session under `recordings_dir` that has no transcript yet, firing
`on_stop` again for each.

## Models

| id | languages | size | default |
|---|---|---|---|
| `parakeet-tdt-ctc-110m` | English | 220 MB | ★ |
| `parakeet-tdt-0.6b-v2` | English | 465 MB | |
| `parakeet-tdt-0.6b-v3` | 25 languages | 500 MB | |

The default is the small one. Set `model` in the config file if you want a
different one. Numbers behind that choice are in
[docs/benchmarks.md](docs/benchmarks.md).

They live in the shared FluidAudio cache, at
`~/Library/Application Support/FluidAudio/Models`. Anything else built on
FluidAudio reads the same files, so the download only happens once per machine.

## Speed

About 60 ms from key-up to text for a short clip, and roughly twice as quick as
Handy on the same model. [docs/benchmarks.md](docs/benchmarks.md) has the
tables and the commands to reproduce them.

The binary is 9.1 MB with two dependencies. Sitting there waiting for the key
it reports 0.0% CPU. Meeting detection is the one thing that ever runs on its
own, and that is a single device read a second.

## Uninstall

```sh
brew uninstall --zap --cask yap
```

`--zap` takes the login item away with it, along with the config file and the
logs. Installed from the .dmg instead, drag yap out of Applications and delete
`~/Library/LaunchAgents/com.terrifiedbug.yap.plist`. Your recordings are never
touched, and neither are the models, which are shared with anything else built
on FluidAudio.

## Requirements

macOS 15 or later on Apple Silicon. Transcription needs the Neural Engine, and
recording system audio needs Core Audio process taps.

## License

MIT. See [LICENSE](LICENSE).
