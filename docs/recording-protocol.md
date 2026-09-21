# Long-recording protocol

The packaged TypeScript server offers `/v2/recordings` independently of legacy
`/v1/generations`. New sessions and results live in the `sessions/` storage
namespace. A completed session exposes a `GenerationRecord` result for existing
delivery code, but does not write that facade into legacy generation storage.
The reference Swift server does not implement this capability.

The authoritative transport models are `Server/src/recording-contract.ts` and
`Sources/SottoAPI/RecordingAPI.swift`. Recording codecs are standalone; the v1
generated Swift wire adapters do not own these models.

## HTTP

Requests use the existing authentication and endpoint rules. Online admission
is required before capture starts. Tokenless localhost remains supported.

| Request | Response |
| --- | --- |
| `GET /v2/recordings/capabilities` | `{ "protocol": "sotto.recording.v1", "maximumPCMBytes": 1048576 }` |
| `POST /v2/recordings` | `RecordingSnapshot`; body is the existing `CreateGenerationRequest` |
| `GET /v2/recordings?limit=50&before=cursor` | `RecordingPage` with compact snapshots and optional `nextCursor` |
| `GET /v2/recordings/:id` | `RecordingDetail`: `{snapshot,result?}` |
| `GET /v2/recordings/:id/transcript` | UTF-8 `text/plain` transcript |
| `GET /v2/recordings/:id/audio/:kind` | WAV export; `kind` is `inference` or `original` |
| `GET /v2/recordings/:id/audio/:kind/:runID` | WAV export for one capture run, retaining its format |
| `POST /v2/recordings/:id/discard` | Explicit discard; separate from connection/capture interruption |
| `POST /v2/recordings/:id/delivery` | Existing `DeliveryReceipt` body, recording delivery outcome |
| `GET /v2/recordings/:id/stream` | WebSocket upgrade using `sotto.recording.v1` |

Clients must negotiate capabilities before admitting a long recording. Do not
silently fall back to an old server that clips audio at three minutes.
Combined original-audio export rejects incompatible run formats with HTTP 409;
use per-run exports when capture formats differ.

## WebSocket

The URL uses `ws` for permitted HTTP endpoints and `wss` for HTTPS. Bearer
authentication, where required, is sent in the upgrade request headers.
Compression is disabled. Binary payloads contain float32 little-endian PCM.

After connecting, send `{ "type": "resume" }`. The server returns
`{ "type": "snapshot", "snapshot": RecordingSnapshot }` with a granted epoch
and authoritative per-stream positions. Resuming fences superseded sockets.
Include that epoch in every audio message and stop request. A new connection
must resume again; a locally cached epoch does not grant permission to write.

When continuing a previously delivered take, send
`{ "type": "context", "epoch": 1, "continuationID": "predecessor UUID" }`
after resume and before uploading audio. Await a snapshot confirming the
frozen `continuationID`. This selects the existing confirmed dictation/list
continuation before incremental text processing starts. An identical context
can be repeated after reconnect; conflicting or late context is rejected.
Persist the desired context locally alongside the admitted session so recovery
cannot lose it or apply a different predecessor.

Each binary message has this layout:

```text
4 bytes: unsigned JSON header length, big-endian
N bytes: UTF-8 JSON RecordingAudioHeader
remaining bytes: interleaved PCM float32, little-endian
```

```json
{
  "type": "audio",
  "epoch": 1,
  "runID": "d65f28dc-35f7-4f66-a5ee-5f124b2398dc",
  "kind": "inference",
  "sequence": 0,
  "firstFrame": 0,
  "format": { "sampleRate": 16000, "channels": 1 },
  "frameCount": 1600,
  "sha256": "lowercase SHA-256 hex of the PCM bytes, exactly 64 characters"
}
```

Streams are identified by `(runID,kind)`. A run represents one uninterrupted
capture format; restarting capture uses a new run ID. `sequence` and
`firstFrame` are relative to that stream, beginning at zero. PCM byte count
must equal `frameCount * channels * 4`. Inference is 16 kHz mono; original
audio accepts 8–192 kHz and 1–8 channels. Samples must be finite. Counters are
nonnegative JSON safe integers; audio/stop epochs and audio frame counts are
positive. There is no recording-duration or lifetime sequence ceiling.

Resource bounds apply to individual transfers:

- PCM: at most 1,048,576 bytes.
- Audio JSON header: at most 16,384 bytes.
- JSON control message, in either direction: at most 2,097,152 bytes.
- Complete binary message: at most 1,064,964 bytes.
- Combined queued/in-flight audio: at most four complete maximum messages.

Durable metadata reserves a separate cumulative budget. Closed endpoints,
their eventual final-stop copy, and capture timings together fit within 1 MiB.
Active runs reserve their later closed endpoint and timing before audio is
acknowledged.
Before accepting changes, the server also checks the complete prospective final
snapshot against the 2 MiB wire budget with 64 KiB reserved for progress metadata.
This lets an accepted pause remain finishable without producing an oversized
reconciliation response. Unsupported metadata growth rejects before acceptance;
the acknowledged audio and previous checkpoints remain available. The on-disk
manifest allows a further 2 MiB for internal speech/text checkpoints, for a total
4 MiB bound. These limits bound metadata rather than recording duration.

The WebSocket payload limit is enforced before decoding. Receive queues and
outbound buffers are independently bounded. A rejected transfer never grants
an acknowledgment; capture can continue into durable local storage while the
uploader waits or reconnects.

An accepted batch returns:

```json
{
  "type": "ack",
  "runID": "d65f28dc-35f7-4f66-a5ee-5f124b2398dc",
  "kind": "inference",
  "nextSequence": 1,
  "frameCount": 1600,
  "revision": 2
}
```

An ACK reports contiguous recoverable audio and receipts, not merely bytes
received on a socket. After reconnect, use server positions rather than local
assumptions about lost ACKs. An identical replay is idempotent; conflicting
content at an accepted sequence is rejected. `nextSequence` and `frameCount`
are cumulative positions for the identified stream.

`{ "type": "ping" }` requests a current snapshot. Protocol WebSocket
ping/pong also detects dead connections. Processing notifications have shape
`{ "type": "progress", "snapshot": RecordingSnapshot }`; notifications may
be coalesced. Reconciliation provides authoritative state even if individual
notifications were lost.

Errors use `{ "type": "error", "code": string, "message": string,
"retryable": boolean }`. A retryable failure requires reconciliation or
waiting, rather than discarding captured audio. SHA-256, PCM sample validity,
offsets, and epoch checks are authoritative on the server. The Swift binary
codec validates framing and declared format/length; the uploader supplies the
digest of its persisted PCM.

## Stop and result

Persist the client's stopped state and exact captured endpoints before sending:

```json
{
  "type": "stop",
  "epoch": 1,
  "runs": [
    {
      "runID": "d65f28dc-35f7-4f66-a5ee-5f124b2398dc",
      "inferenceFrames": 480000,
      "originalFrames": 1440000
    }
  ]
}
```

`originalFrames` is omitted when original audio was not retained. The first
accepted stop fixes the exact per-run endpoints. An identical repeat is safe;
different endpoints or audio beyond them are rejected. Finalization waits for
contiguous audio coverage and completed speech processing. A lost stop reply
is resolved by reconnecting and inspecting `snapshot.stopRuns`, then retrying
the identical intent when necessary. Stop does not authorize partial delivery.

### Interrupted capture and explicit continuation

Capture interruption closes a run without ending the logical recording. After
saving its exact endpoints and uploading its committed prefix, send:

```json
{
  "type": "pause",
  "epoch": 1,
  "runs": [{ "runID": "d65f28dc-35f7-4f66-a5ee-5f124b2398dc", "inferenceFrames": 480000 }],
  "runTimings": [{
    "runID": "d65f28dc-35f7-4f66-a5ee-5f124b2398dc",
    "startedAt": "2026-09-21T10:00:00Z",
    "endedAt": "2026-09-21T10:00:30Z",
    "gapBeforeMilliseconds": 0
  }],
  "interruption": "Microphone disconnected."
}
```

Pause requires a nonempty endpoint list and exactly matching closed run timings.
`endedAt` must be present and at or after `startedAt`. The optional nonnegative
`gapBeforeMilliseconds` records the hiatus before that run; it is persisted
explicitly rather than inferred from uploaded frame counts. Empty zero-frame
runs can still be closed and represented honestly. Control messages use the
2 MiB budget without an independent capture-run count ceiling; the 16 KiB
header budget applies only to binary audio messages.

The server persists immutable endpoints in `snapshot.closedRuns` and timelines
in `snapshot.runTimings`. Identical pause replay is safe after reconnect;
changed endpoints or timings reject. Closed run audio cannot grow, and its
remaining speech/text tail is processed before text from the next run. A pause
sets capture to `interrupted` and does not set `stopRuns` or authorize final
delivery.

Explicit user continuation creates a fresh local capture run with a new run ID,
its current formats, start timestamp, and an honest gap. Uploaders reconcile
the prior pause before sending the new run's audio. WebSocket `resume` only
grants connection ownership; it cannot reopen a closed capture run. Recovered
audio remains paused until the user chooses to continue or finish it.

Final `stop` includes all closed and current run endpoints, and can additionally
include `runTimings` for all of them. When supplied, final timing coverage must
match the endpoints and every timing must be closed. Existing closed endpoints
and timelines remain immutable. This produces one recording/result across
interruptions while preserving captured intervals and gaps.

Snapshots expose capture state (`recording`, `interrupted`, `stopped`, or
`discarded`) separately from processing state (`queued`, `processing`,
`completed`, or `failed`). Frame progress totals describe normalized inference
audio; original frames are reported per stream, since formats can differ.
`previewText` is a compact preview, not the complete transcript. `revision`
orders state changes and `epoch` fences connection ownership. ISO8601
timestamps preserve millisecond precision, including capture timing.

Once finalized, `RecordingDetail.result` contains the assembled
`GenerationRecord`. Delivery remains one guarded insertion after stop. A
recovered recording must not automatically insert into a stale destination or
repeat an uncertain previous delivery.
