# TypeScript server draft validation

The packaged coordinator now uses TypeScript, Fastify, and Bun. The Swift server
and domain packages remain as migration references; the macOS client remains Swift.

## Local verification

- `bun run check`: passes.
- `bun run test`: 185 tests pass, covering the HTTP contract, text behavior,
  storage/recovery/imports, helper supervision, locks, and correction workers.
- `bun run generate:api --check`: TypeScript and Swift bindings match OpenAPI.
- `swift test`: existing Swift domain/server/client tests and new API bridge tests
  pass. The client was compiled without launching it.
- Correction parity: 3,380 generated cases compared against the Swift algorithm,
  with no differences.
- Standalone coordinators compile for macOS arm64 and Linux x64/arm64. Linux
  executables and their native file locks were exercised in Ubuntu containers.
- Complete Linux CPU archives from CI include the runtime, native helpers, VAD,
  and notices. Their coordinator and both helpers launch in matching Ubuntu
  containers without an installed Bun or Node runtime.
- Compiled HTTP smoke covers preferences, imports, archive deletion, NDJSON,
  Origin rejection, and unavailable-model readiness using a temporary archive.
- Real Whisper and Qwen inference passes the server integration script using the
  public JFK audio sample, with original-audio retention both enabled and disabled.
  The test checks ordered streaming states, model identity, exact artifacts,
  delivery, deletion, and warm readiness.

Two independent reviews covered security and API/domain/build compatibility.
Material findings were fixed and checked again: Swift artifact upload MIME types,
the download schema, archive FIFO handling, and retired helper shutdown.
Automated review also led to fixes for processing-task drainage before archive
lock release, independent hash-waiter cancellation, and token-wrapped silence.
Workflow actions now use verified immutable revisions.

## Isolated development instance

The new server uses `http://localhost:8392` and `.local/typescript-server` for data.
Its own packaged helper copies load existing model files read-only. The installed
server at port 8391, its archive, and the running V07 client were left untouched.

## Distribution limits

- Bun embeds the coordinator runtime. Native inference helpers and Metal assets
  must still be included in each platform package; model weights remain separate.
- CI builds full Linux CPU packages on x64 and arm64 and tests their compiled HTTP
  servers. The release workflow also builds the macOS MLX package.
- CUDA container support is implemented but was not tested on a GPU locally.
- macOS packages are ad-hoc signed. Developer ID signing and notarization require
  distribution credentials.
- Linux packages target Ubuntu 24.04 or newer compatible glibc environments;
  the x64 coordinator uses Bun's baseline CPU target.
