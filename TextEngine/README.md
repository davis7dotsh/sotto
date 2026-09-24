# Qwen helpers

The server packages `v07-text-engine` using native Swift MLX on macOS and llama.cpp on Linux. Both run Qwen3-4B-Instruct-2507, serve the same JSON-lines protocol, and remain loaded between requests. They read local model files and never open a microphone, network connection, or chat session.

Build with `scripts/build-server.sh`; see [model setup](../Server/README.md#models). The Mac helper requires its adjacent `mlx.metallib` and resource bundles. `scripts/build-text-engine.sh` builds that package through Xcode; plain `swift build` does not package its shaders. Linux builds the separate CMake project because its ggml version differs from Whisper's.

## Protocol

After verifying/loading the model, the helper emits a `ready` JSON object with `engineVersion`. Requests and responses are newline-delimited UTF-8 JSON:

```json
{"type":"correct","id":"example","text":"i use code ex.","terms":["Codex"],"language":"en","systemPrompt":"Return only the cleaned transcript. Preserve wording and use preferred names only when they match."}
{"type":"result","id":"example","text":"I use Codex.","elapsed":0.2}
```

An error contains `type: "error"`, `message`, and the request `id` when available. Failed requests never return a partial rewrite. The server supplies the snapshotted cleanup prompt on every request and validates each proposed result before delivery. Helpers have no fallback behavior prompt.

## Bounds and lifecycle

- Request: 64 KiB; transcript: 24 KiB; nonempty system prompt: 4 KiB. Up to 256 terms, 256 bytes each, 16 KiB total. Server policy further caps text at 6,000 characters and model hints at 80 terms/4 KiB.
- Context: 8,192 tokens including role framing, prompt, JSON input, and the 2,048-token output reservation. Greedy decoding; overflow, output exhaustion, and empty output fail rather than truncate.
- Inference: 15-second helper deadline. The MLX helper adds a two-second process-exit backstop; the server resets either hung helper at 18 seconds and bounds proofreading startup at 30 seconds.
- User text and custom prompts cannot introduce structural control-token IDs. Semantic model mistakes are still possible; [rewrite guards](../docs/text-correction.md#preservation-checks) determine whether output is accepted.
- Request state is cleared after each correction. Cancellation of active work terminates the process. Quit, stdin EOF, and parent death release the model. The server retains idle warm helpers.

Diagnostics use stderr and omit transcripts. The server drains them without storing them.

## Verify

With a built package and `V07_TEXT_MODEL` set to its model directory/file:

```sh
./scripts/test-corrections.sh
```

This selects the platform's harness and exports the canonical default from `build/server/v07-server`. To test a custom prompt, add `--prompt /absolute/path/to/prompt.txt`; the file is used exactly, including any trailing newlines. Use `--server` when running `test-text-engine.py` or `test-llama-engine.py` directly against a different server build.

The suites use synthetic text to check corrections, numbers/negations, names, literal role markers, bounds, request isolation, and process shutdown. Portable Swift tests cover server lifecycle and output validation without model files. These checks do not establish microphone or cross-app insertion behavior.
