# Whisper helper

`sotto-engine` is the server's persistent whisper.cpp process. It reads audio files supplied by the server; it never opens a microphone or network connection. Builds use Metal on macOS and CPU or CUDA on Linux. See [server setup](../Server/README.md) for packaging and models.

## Protocol

After loading Whisper and Silero VAD, the helper emits a `ready` JSON object with an `engineVersion`. Send one UTF-8 JSON object per line on stdin; replies are flushed JSON lines on stdout. Diagnostics go to stderr without transcript text.

```json
{"type":"transcribe","id":"request-1","path":"/absolute/path/to/recording.wav","language":"en","vocabularyTerms":["Sotto","SwiftUI","Metal"]}
```

- `language` defaults to `en`; `auto` enables language detection.
- `vocabularyTerms` is an ordered list of recognition hints. Whole terms are fitted into the loaded model's token budget. Responses report `includedTerms`, `omittedTerms`, `tokenCount`, and `tokenBudget`.
- WAV input must be mono 16 kHz PCM16 or float32, 0.2–180 seconds long and at most 32 MiB. These are per-processing-window bounds, not the long-recording session duration. The legacy HTTP server uses a 0.25-second minimum.
- Progress: `{"type":"progress","id":"request-1","value":0.5}`.
- Results contain `type: "result"`, `id`, `text`, audio `duration`, processing `elapsed`, detected `language`, `spans`, `segmentSpans`, and hint diagnostics. Each span has exact `text` plus request-relative `startSeconds` and `endSeconds`. Joining either span array's text and trimming the outside must reproduce `text` exactly. BPE pieces that split a Unicode codepoint are joined into one valid UTF-8 span. `segmentSpans` retain whole decoder utterances for source checkpoints.
- Acoustic preflight: `{"type":"boundary","id":"request-1","path":"/absolute/path/to/window.wav"}` returns `duration` and an optional `boundarySeconds`. The last nonspeech gap after 30 seconds is preferred. Speech segments have 100 ms padding on each side and must leave at least another 200 ms of quiet; the cut is their gap's midpoint. This uses CPU Silero, tolerates noise, and resets detector state per request.
- Errors contain `type: "error"`, `message`, and a request `id` when available. Requests are processed sequentially.

Requests are bounded to 1 MiB. Vocabulary allows at most 8,192 terms, 16 KiB per term, and 384 KiB total; actual model hints usually fit much less. Silence returns a successful empty transcript.

## Decoding and lifecycle

A CPU Silero pass rejects nonspeech (threshold 0.5, minimum speech segment 120 ms). If speech is detected, Whisper receives the complete window. Decoding uses beam search 5, temperature 0, and token timestamps; the returned transcript remains plain text. Segments above Whisper's no-speech threshold are excluded. Token timestamps are acoustic estimates, not exact word boundaries. When upstream word estimates become unavailable or nonmonotonic, the helper preserves all text in conservative segment envelopes rather than inventing corrected word timing. The coordinator then prefers a fresh bounded decode over an unsupported overlap match. Silence returns `spans: []`. This remains probabilistic and can miss quiet speech.

The TypeScript coordinator selects bounded 45-second windows from canonical audio, preferring conservative Silero nonspeech gaps and then sustained near-zero amplitude after 30 seconds. These cuts do not remove any captured silence. With no safe quiet cut, timing-capable backends use two seconds of overlap. Checkpoints retain whole decoder utterances around an eight-second provisional tail, including at quiet cuts: speech recognition can autocomplete a phrase whose actual ending is in the next window. The next pass freshly decodes the complete provisional source interval (at most 90 seconds), replacing only provisional evidence while preserving the committed prefix. This avoids joining an autocompleted quote to its actual spoken continuation. Other overlap reconciliation requires matching text pieces at matching acoustic times; it never removes a repeated phrase by text alone. Invalid or failed replacement coverage stays incomplete. Backends without timing use nonoverlapping windows and preserve every returned phrase.

The server keeps the model warm. Terminating the helper cancels active work. `{"type":"quit"}`, stdin EOF, or parent death releases it. Native dependencies and Metal source are embedded in the speech executable.

## Verify

```sh
./scripts/build-server.sh
python3 scripts/test-engine.py --help
```

The test harness exercises protocol bounds, public sample recordings, vocabulary, passage retention, and process lifetime. For the full API path, use `scripts/smoke-test.sh` against an idle Dev server.
