# Benchmarks

All figures from an M4, against LibriSpeech test-clean: 2620 files, 5.4 hours
of speech.

## Latency by clip length

Median across independent recordings. The left column is the default model. The
right one is `parakeet-tdt-0.6b-v2`, the accuracy option.

| clip length | 110M (default) | 0.6B v2 | files |
|---|---|---|---|
| 0 to 5 s | 54 ms | 70 ms | 1089 |
| 5 to 10 s | 61 ms | 79 ms | 917 |
| 10 to 15 s | 71 ms | 89 ms | 375 |
| 15 to 20 s | 93 ms | 117 ms | 147 |
| 20 to 30 s | 104 ms | 119 ms | 83 |

Transcription only. Capture and typing at the cursor are not in these numbers.
Repeat runs move five to ten percent with machine load.

```sh
yap bench --corpus DIR
```

## Accuracy

Word error rate over the whole of test-clean. Lower is better.

| model | WER |
|---|---|
| `parakeet-tdt-ctc-110m` | 2.67% |
| `parakeet-tdt-0.6b-v2` | 2.06% |

The 110M model is the default. Half the download, about a third quicker, and
0.6 points of accuracy is what that costs.

## Against Handy

Both apps ran the same checkpoint, `parakeet-tdt-0.6b-v2`, on the same files.
It is not yap's default any more, but it is the one both can run, so this is
engine against engine rather than model against model. Each app ran the way it
ships: yap as CoreML on the Neural Engine, Handy as GGUF on Metal. Median of
seven warm runs.

| file | length | yap | Handy |
|---|---|---|---|
| `121-127105-0021` | 2.0 s | 67 ms | 125 ms |
| `1580-141084-0011` | 5.0 s | 76 ms | 156 ms |
| `1320-122617-0010` | 10.0 s | 85 ms | 202 ms |
| `8463-294825-0009` | 20.0 s | 187 ms | 458 ms |
| `121-123859-0002` | 30.0 s | 203 ms | 660 ms |

About twice as fast, and the gap grows with the clip.

Forty transcriptions of the 30 second file, three repeats:

| | yap | Handy |
|---|---|---|
| process CPU time | 6.6 to 8.5 s | 30.2 to 33.5 s |
| peak resident memory | 111 to 116 MB | 1128 to 1145 MB |

Both ran headless, so neither number includes audio capture or text insertion.
Memory is per process.

## Reproducing it

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
