# Whisper helper

`v07-engine` is the server's persistent whisper.cpp process. It reads audio files supplied by the server; it never opens a microphone or network connection. Builds use Metal on macOS and CPU or CUDA on Linux. See [server setup](../Server/README.md) for packaging and models.

## Protocol

After loading Whisper and Silero VAD, the helper emits a `ready` JSON object with an `engineVersion`. Send one UTF-8 JSON object per line on stdin; replies are flushed JSON lines on stdout. Diagnostics go to stderr without transcript text.

```json
{"type":"transcribe","id":"request-1","path":"/absolute/path/to/recording.wav","language":"en","vocabularyTerms":["V07","SwiftUI","Metal"]}
```

- `language` defaults to `en`; `auto` enables language detection.
- `vocabularyTerms` is an ordered list of recognition hints. Whole terms are fitted into the loaded model's token budget. Responses report `includedTerms`, `omittedTerms`, `tokenCount`, and `tokenBudget`.
- WAV input must be mono 16 kHz PCM16 or float32, 0.2–180 seconds long. The HTTP server uses a 0.25-second minimum.
- Progress: `{"type":"progress","id":"request-1","value":0.5}`.
- Results contain `type: "result"`, `id`, `text`, audio `duration`, processing `elapsed`, detected `language`, and hint diagnostics.
- Errors contain `type: "error"`, `message`, and a request `id` when available. Requests are processed sequentially.

Requests are bounded to 1 MiB. Vocabulary allows at most 8,192 terms, 16 KiB per term, and 384 KiB total; actual model hints usually fit much less. Silence returns a successful empty transcript.

## Decoding and lifecycle

A CPU Silero pass rejects nonspeech (threshold 0.5, minimum speech segment 120 ms). If speech is detected, Whisper receives the complete recording. Decoding uses beam search 5, temperature 0, and internal timestamp tokens; the returned transcript is plain text. Segments above Whisper's no-speech threshold are excluded. This remains probabilistic and can miss quiet speech.

The server keeps the model warm. Terminating the helper cancels active work. `{"type":"quit"}`, stdin EOF, or parent death releases it. Native dependencies and Metal source are embedded in the speech executable.

## Verify

```sh
./scripts/build-server.sh
python3 scripts/test-engine.py --help
```

The test harness exercises protocol bounds, public sample recordings, vocabulary, passage retention, and process lifetime. For the full API path, use `scripts/smoke-test.sh` against an idle Dev server.
