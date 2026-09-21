# Architecture

Sotto's native Swift macOS client handles microphone capture, shortcuts, and cursor insertion. An independent TypeScript/Fastify server, compiled with Bun, owns inference, shared settings, and history. HTTP uses the shared OpenAPI contract; long recordings use the versioned v2 recording routes and `sotto.recording.v1` WebSocket protocol on localhost or a remote server. Existing v1 generations remain readable.

## Code map

| Component | Responsibility |
| --- | --- |
| `Sources/Sotto` | SwiftUI/AppKit app, device settings, HTTP client, capture, and guarded delivery. |
| `Sources/SottoCore` | Mac configuration, audio metering, microphone selection, and model manifests. |
| `Sources/SottoAPI` | Shared wire types and limits. |
| `Sources/SottoAPIWire` | Generated Swift transport types used through the API facade. |
| `Server/api/openapi.yaml` | Language-neutral HTTP and wire-model contract. |
| `Server/src` | Packaged TypeScript HTTP server, durable coordinator, text pipeline, and helper management. |
| `Sources/SottoDomain` | Dictionary, list formatting, rewrite validation, and composition. |
| `Sources/SottoServerKit` | Reference Swift server retained for migration parity tests. |
| `Sources/SottoServer` | Reference Swift server command-line entry point. |
| `Engine` | Persistent whisper.cpp speech helper; Metal on Mac, CPU/CUDA on Linux. |
| `TextEngine` | Persistent Qwen helper; Swift MLX on Mac, llama.cpp on Linux. |

The server talks to helpers over bounded JSON-lines pipes. Models warm at startup and stay loaded. The client contains no model helpers; it never starts or stops the server. The application has no Python runtime dependency.

Bun manages all JavaScript dependencies and compiles the coordinator plus its correction worker into standalone platform executables. Heavy correction alignment runs outside the HTTP event loop. Native inference helpers still require platform builds; the Mac proofreader remains Swift MLX. Linux server packages require neither Swift nor an installed JavaScript runtime.

## A recording

1. The client negotiates recording capability and asks the online server for durable admission with its device identity. The server freezes shared settings before microphone capture starts.
2. The client pins its microphone and saves small PCM batches to a persistent local spool. Inference audio is mono 16 kHz float32; optional original audio keeps the microphone rate/channels as float32. An independent uploader transfers committed batches over an authenticated, endpoint-pinned WebSocket.
3. The server acknowledges only recoverable audio and receipts. Reconnect snapshots reconcile exact per-run positions; connection epochs fence obsolete sockets. Network failures leave capture running against bounded local storage.
4. During capture, the server runs bounded Whisper windows with timed spans and acoustic overlap. Completed windows and bounded text/list/correction state are journaled. Dictionary and optional Qwen cleanup operate on text windows; rejected proofreading retains deterministic text. Legacy and recording work share a serialized model queue.
5. Stop drains capture and persists exact per-run endpoints. The server waits for contiguous durable audio, finishes pending speech/text tails, and assembles one result. There is no whole-session model request or mandatory WAV copy.
6. Compact WebSocket snapshots carry transfer/processing progress. The client fetches the final transcript, verifies focus/caret safety, persists one delivery attempt, and reports its outcome separately from inference completion.

Admitted audio survives network outages, app interruptions, and server restarts. Stopped sessions recover transfer and processing automatically; recovery and history never paste an old result. Explicit discard removes audio, unlike interruption. New capture still requires online admission. Legacy v1 generations retain their original lifecycle and limits; the reference Swift server does not advertise v2 recording support.

## Text delivery

Only the new `insertionText` can be inserted; `previewText` may include earlier list items. Continuation requires a previous generation from the same device and a confirmed client-side cursor anchor. The server checks age and delivery state before reusing context. Invalid context falls back to a standalone take.

The Mac rechecks destination, selection, protected fields, modifiers, and clipboard state before delivery. Unsafe destinations use clipboard or preview fallback. Only confirmed insertion advances cursor-based continuation. Editor text and Accessibility handles stay on the Mac.

Microphone capture uses input-only Core Audio without changing system routing or playback volume. A bounded writer queue and missing-frame watchdog stop safely on capture/storage failure and preserve the committed prefix. A scoped power assertion prevents idle system sleep during active capture. Real sleep, device loss, lock, and app quit preserve interrupted audio; resumed capture uses a new run and records the gap.

## Settings

| Scope | Where to edit | What it owns |
| --- | --- | --- |
| This Mac | **This Mac** and **Microphone** | Endpoint/token, device name, shortcut, launch at login, microphone priority/selection. |
| Shared server | **Server preferences** | Language, cleanup prompt, vocabulary, dictionary, proofreading toggle, original-audio retention. |
| Server process | Command arguments or environment | Bind address, port, data directory, token file, helper/model paths. See [server setup](../Server/README.md). |

Shared saves use revisions to reject stale concurrent edits. Settings are snapshotted when the server accepts a take; changes affect future recordings. Update shared settings through the UI/API rather than editing files while the server runs.

The regular app uses `~/Library/Application Support/Sotto`; Dev uses `~/Library/Application Support/Sotto Dev`. `SOTTO_CLIENT_DATA_DIR` overrides either, and the dev runner selects `.local/client`. `config.json` stores shortcut/microphone settings; `client.json` stores endpoint/device identity. Tokens live in separate release/Dev Keychain services, scoped to the endpoint and client directory. `SOTTO_SERVER_URL` overrides the saved endpoint for a run. Valid manual `config.json` edits are reloaded; invalid files leave the last good configuration active.

## Storage

The server's `--data-dir` (normally `.local/server` in development) contains:

```text
preferences.json
generations/<UUID>/
  metadata.json
  transcript.txt
  inference.wav
  original.wav
sessions/<UUID>/
  manifest.json
  <runID>/<kind>/<sequence>.pcm
  <runID>/<kind>/<sequence>.json
  windows/<sequence>.json
  result.json
  transcript.txt
```

Metadata includes device identity, settings snapshot, raw/final text, insertion/preview text, model and processing details, and any delivery receipt. `transcript.txt` contains the current take's final text. Inference audio is always retained for completed takes; original audio is optional and defaults on. The retention toggle does not remove existing files, and there is no automatic history expiry.

All clients read shared, paginated history. V2 history uses compact snapshots and fetches full results on demand. PCM batches are the canonical v2 archive; WAV exports stream on demand and reject sizes beyond RIFF limits. Original runs with different formats can be downloaded separately. Inference audio remains available when original retention is disabled.

Client spools live under `Recordings/` in the client data directory until server finalization or explicit discard. Credentials stay in Keychain. Capture batches coalesce up to 250 ms per stream and publish an atomic, aligned original/inference checkpoint. An abrupt process/power loss can additionally lose the bounded writer queue and converter tail. Orderly interruptions drain them. Server startup reconciles receipt and window journals, resumes pending work, and preserves acknowledged audio.

Only one server may own a data directory. Back up preferences, generation directories, and session directories together. Sotto does not add filesystem encryption; protect this directory as you would the recordings it contains. Authentication and remote transport are described in the [server guide](../Server/README.md#remote-access).

See the [HTTP contract](client-server-contract.md) for request details and [text correction](text-correction.md) for behavior and limitations.
