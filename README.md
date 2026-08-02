<p align="center">
  <img src="packaging/yap.png" width="128" alt="">
</p>

# yap

Dictation and meeting transcription for macOS. Everything runs on your Mac.

Hold a key, speak, release. The text appears at the cursor.

The same mark sits in the menu bar while yap is running.

## Speed

yap runs Parakeet on the Apple Neural Engine. The figures below come from an
M4, scored against LibriSpeech test-clean. That is 2620 files and 5.4 hours of
speech, with the median taken across independent recordings. The left column
is the default model; `parakeet-tdt-0.6b-v2` is there because it is the
accuracy option and some people will want it.

| clip length | 110M (default) | 0.6B v2 | files |
|---|---|---|---|
| 0 to 5 s | 54 ms | 70 ms | 1089 |
| 5 to 10 s | 61 ms | 79 ms | 917 |
| 10 to 15 s | 71 ms | 89 ms | 375 |
| 15 to 20 s | 93 ms | 117 ms | 147 |
| 20 to 30 s | 104 ms | 119 ms | 83 |

Times cover transcription only, not capture or
typing at the cursor. Repeat runs move five to ten percent with machine load.
Reproduce it with `yap bench --corpus DIR`.

The binary is 9.1 MB and has two dependencies. Waiting for the key, the daemon
reports 0.0% CPU. Meeting detection is the one exception, and it costs one
cheap device read a second.

## Compared with Handy

Both apps were given the same checkpoint, `parakeet-tdt-0.6b-v2`, and
the same files from LibriSpeech test-clean. It is no longer yap's default, but
it is the one both apps can run, so the comparison stays engine against engine
rather than model against model. Each ran it the way it ships: yap as CoreML
on the Neural Engine, Handy as GGUF on Metal. Median of seven warm runs.

| file | length | yap | Handy |
|---|---|---|---|
| `121-127105-0021` | 2.0 s | 67 ms | 125 ms |
| `1580-141084-0011` | 5.0 s | 76 ms | 156 ms |
| `1320-122617-0010` | 10.0 s | 85 ms | 202 ms |
| `8463-294825-0009` | 20.0 s | 187 ms | 458 ms |
| `121-123859-0002` | 30.0 s | 203 ms | 660 ms |

About twice as fast, widening with clip length.

Forty transcriptions of the 30 second file, three repeats:

| | yap | Handy |
|---|---|---|
| process CPU time | 6.6 to 8.5 s | 30.2 to 33.5 s |
| peak resident memory | 111 to 116 MB | 1128 to 1145 MB |

Both apps ran headless, so audio capture and text insertion are excluded from
each. The memory row is per process. 

```sh
curl -L -o test-clean.tar.gz \
  https://huggingface.co/datasets/FluidInference/librispeech/resolve/main/test-clean.tar.gz
tar xzf test-clean.tar.gz
afconvert -f WAVE -d LEI16@16000 -c 1 \
  test-clean/121/123859/121-123859-0002.flac clip.wav

yap bench --audio clip.wav --iterations 7 --models parakeet-tdt-0.6b-v2

/Applications/Handy.app/Contents/MacOS/handy --transcribe-file clip.wav \
  --model handy-computer/parakeet-tdt-0.6b-v2-gguf/parakeet-tdt-0.6b-v2-Q8_0.gguf \
  --repeat 7 --json
```

## What it does

Two jobs share one process and one loaded model.

Dictation: hold a key, speak, release, and the text is typed at the cursor.

Meetings: record the microphone and the system audio as two tracks, then get one
transcript with timings and speaker labels.

Speech is transcribed on the machine, and the audio is never uploaded. There is
no account. The network is used one time, to download the model.

## Install

```sh
brew install --cask terrifiedbug/tap/yap
yap setup
```

Signed with a Developer ID certificate and notarized by Apple, so it opens
without a Gatekeeper prompt. Apple Silicon only — the model runs on the Neural
Engine.

`yap setup` asks for the permissions and downloads the model. The model is
220 MB and downloads one time.

The cask installs `yap.app` and puts the `yap` command on your PATH; they are
the same binary. To build it yourself instead:

```sh
git clone https://github.com/TerrifiedBug/yap.git
cd yap
swift build -c release --arch arm64
sudo cp .build/arm64-apple-macosx/release/yap /usr/local/bin/yap
yap setup
```

## Use

```sh
yap                              # dictation, in the foreground
yap install --launch-at-login    # dictation, at login, in the menu bar
yap start                        # start the background daemon again
yap stop                         # stop it until the next login
yap record                       # record a meeting now, stop with ^C
yap doctor                       # check permissions and the model
```

"Quit yap" in the menu bar stops the background daemon for good until you log
in again. `yap start` brings it back. Running `yap` on its own is not the same
thing: that one lives in the terminal you started it from, dies with it, and
borrows that terminal's permissions rather than its own.

Hold `fn`, speak, then release. A small pill appears while the microphone is
live. The transcript is typed where the cursor is.

If `fn` is mapped to something else on your Mac, `yap doctor` tells you how to
change it back. You can also pick a different key with `--hotkey`, or set
`dictation.hotkey` in the config file.

"Copy last transcript" in the menu bar puts the most recent dictation back on
the clipboard, for the press that landed in the wrong window. yap keeps one,
in memory, until it is replaced or you quit.

## Commands

| command | what it does |
|---|---|
| `yap run` | The dictation daemon, in the foreground. The default. |
| `yap start` | Start the background daemon, or restart it if it is already up. |
| `yap stop` | Stop the background daemon. It returns at your next login. |
| `yap record` | Record one session now, then transcribe it. |
| `yap models list` | Show the models and which are downloaded. |
| `yap models download <id>` | Get a model before you need it. |
| `yap doctor` | Report permissions, key mapping, model state, and whether the login item is actually running. |
| `yap setup` | Grant permissions and download the model. |
| `yap install` | Add or remove the login item. |
| `yap bench --audio FILE` | Time transcription on your own audio. |
| `yap --version` | Print the version. |

## Configuration

Settings live in `~/.config/yap/config.json`. Every key is optional, and a
command-line flag beats the file.

"Edit config…" in the menu bar opens the file. The first time, yap writes it
out with all the defaults filled in.

yap reloads the file when you save it. The hotkey, the overlay, `mute_output`,
`newline_after_release` and `meeting_detection` change straight away. A new
`model` or `recordings_dir` needs a restart, and yap prints a note when it
sees one.

```json
{
  "recordings_dir": "~/Recordings",
  "meeting_detection": false,
  "mic_voice_processing": true,
  "on_stop": "my-hook",
  "transcription": { "enabled": true },
  "dictation": {
    "model": "parakeet-tdt-ctc-110m",
    "hotkey": "fn",
    "overlay": true,
    "newline_after_release": false,
    "mute_output": false
  }
}
```

`newline_after_release` presses Return after the text goes in. Turn it on when
you dictate into chat boxes.

`mute_output` silences the speakers while you hold the key. The microphone
hears the room, and the room includes whatever you are playing, so a video
behind a press gets transcribed along with you. Off by default, because it is
audible: what you are listening to stops every time you speak. It reaches your
own default output only, so a second machine or someone talking nearby is
untouched either way.

`meeting_detection` offers to record when another app takes the microphone. It
is off by default, and nothing watches the microphone until you turn it on.

`mic_voice_processing` cancels speaker echo on the microphone track. It is on by
default: a call played through speakers reaches the microphone as well, so
without it everything the other side says is transcribed twice, the second time
as you. Turn it off to record the raw microphone. On a route where cancellation
returns silence, yap notices within a second and restarts the microphone raw by
itself.

`on_stop` runs a command after each recording, with the session folder as its
only argument.

`transcription` turns automatic transcription of recordings on or off. It is on
by default, and dictation ignores it — the hotkey always transcribes. Turn it
off to use yap as a recorder and do the transcribing yourself: `on_stop` then
fires as soon as the recording stops, instead of after the transcript. Nothing
is lost. Turn it back on and restart yap, and it transcribes every session under
`recordings_dir` that still has no transcript, and runs `on_stop` again for
each. A recording written elsewhere with `yap record --out` is never rescanned.

## Models

| id | languages | size | WER | default |
|---|---|---|---|---|
| `parakeet-tdt-ctc-110m` | English | 220 MB | 2.67% | ★ |
| `parakeet-tdt-0.6b-v2` | English | 465 MB | 2.06% | |
| `parakeet-tdt-0.6b-v3` | 25 languages | 500 MB | | |

WER is word error rate over the whole of LibriSpeech test-clean (2620 files,
324 minutes) — lower is better. The default is the 110M model: it is half the
download and about a third quicker, and 0.6 points of accuracy is the price.
Set `model` in the config file to `parakeet-tdt-0.6b-v2` if you would rather
have the accuracy back.

Models are stored in the shared FluidAudio cache at
`~/Library/Application Support/FluidAudio/Models`. Other apps that use FluidAudio
read the same files, so the download happens one time per machine.

## Requirements

macOS 15 or later, on Apple Silicon. Transcription needs the Neural Engine, and
system audio recording needs Core Audio process taps.

## License

MIT. See [LICENSE](LICENSE).
