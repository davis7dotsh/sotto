# Sotto server

The server is an independent TypeScript/Fastify HTTP process that owns models, shared preferences, recordings, and history. Bun manages its dependencies and compiles standalone executables with the runtime included. Native inference helpers run separately. This guide covers model installation and running the server separately.

| Server | Speech | Proofreading |
| --- | --- | --- |
| Apple Silicon macOS | Whisper large-v3-turbo / whisper.cpp / Metal | Qwen3-4B-Instruct-2507 / Swift MLX / 4-bit |
| Linux x86_64 or ARM64 | Whisper large-v3-turbo / whisper.cpp / CPU or CUDA | Qwen3-4B-Instruct-2507 / llama.cpp / Q4_K_M |

## Linux

The release workflow publishes `sotto-server-linux-x64-cuda.tar.gz` on `server-v*` tags and manual dispatch. Extract that tarball to `/opt/sotto`. The host NVIDIA driver must match CUDA 13.0.2: the helpers load `libcuda.so.1` from the driver, and the package does not include the CUDA toolkit. Keep model weights outside the package.

```sh
sudo mkdir -p /opt/sotto /var/lib/sotto/models
sudo install -d -m 700 /etc/sotto
sudo tar -xzf sotto-server-linux-x64-cuda.tar.gz -C /opt/sotto --strip-components=1
```

Place the pinned files at `/var/lib/sotto/models/ggml-large-v3-turbo.bin` and `/var/lib/sotto/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`. Install a token of at least 32 characters, with no whitespace, at `/etc/sotto/token` with mode `0600`. The package includes `sotto-server.service`. Install that unit once, outside the package:

```sh
sudo cp /opt/sotto/sotto-server.service /etc/systemd/system/sotto-server.service
sudo systemctl daemon-reload
sudo systemctl enable --now sotto-server
```

To update, stop the service, replace `/opt/sotto`, and start it again. Weights and history under `/var/lib/sotto` stay put, and so does the installed unit.

Without a GPU, build on the machine with `./scripts/build-server.sh` (`SOTTO_CUDA` defaults to `OFF`) or `docker build -f Server/Dockerfile --target cpu`. If the host cannot place a matching CUDA runtime next to the binary, use the `--target cuda` image below.

## Models

Run these commands from the repository root. Weights use about 4 GB of disk; runtime memory also includes model state and inference buffers. The server verifies pinned files before loading and keeps models warm. It does not download large weights automatically.

### Whisper, on either platform

```sh
SOTTO_MODEL_DIR="$PWD/.local/models" ./scripts/download-model.sh
```

This installs and verifies `ggml-large-v3-turbo.bin`. The URL, revision, and checksum are pinned in `scripts/download-model.sh` and `Sources/SottoCore/SpeechModel.swift`. The server build separately downloads the pinned Silero VAD model.

### Qwen on macOS

The MLX directory must contain exactly the six files listed below. Download the pinned revision:

```sh
(
  set -e
  sotto_qwen_dir="$PWD/.local/models/Qwen3-4B-Instruct-2507-MLX-4bit"
  sotto_qwen_url="https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
  mkdir -p "$sotto_qwen_dir"
  for file in model.safetensors config.json tokenizer.json tokenizer_config.json generation_config.json chat_template.jinja; do
    curl --fail --location --retry 3 --output "$sotto_qwen_dir/$file" "$sotto_qwen_url/$file"
  done
)
```

`Sources/SottoCore/TextModel.swift` defines the six-file size/hash manifest; the MLX helper verifies it before becoming ready. Use regular files, with no extra files or symlinks in the model directory.

### Qwen on Linux

```sh
mkdir -p .local/models
curl --fail --location --retry 3 \
  --output .local/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
```

Expected size: 2,497,281,120 bytes. SHA-256: `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597`. The server verifies both before loading.

## Build

Install Bun 1.4.2 and initialize submodules with `git submodule update --init --recursive`. macOS requires Apple Silicon and full Xcode with its Metal compiler for the MLX helper; the complete client/helper build uses Xcode 26+ and Swift 6.2+. If Metal is missing, run `xcodebuild -downloadComponent MetalToolchain`.

Linux requires Bun, a C/C++ toolchain, CMake, Git, curl, pkg-config, and libcurl development headers. Swift is not required. The [Dockerfile](Dockerfile) provides a pinned Ubuntu 24.04 build environment. `./scripts/build-server.sh` is the macOS package and the Linux no-GPU fallback; `SOTTO_CUDA` defaults to `OFF`.

```sh
./scripts/build-server.sh
```

Output is `build/server`: executable, native helpers, VAD, notices, and resources. Keep the package together; the Mac proofreader requires the adjacent Metal library and bundles. Large model weights and user data live outside it.

To compile only the coordinator, including its correction worker:

```sh
bun install --frozen-lockfile
bun run build:server                     # Native coordinator in build/server
bun run build:server --all               # Mac arm64, Linux x64 and Linux arm64
```

Cross builds live under `build/server-coordinators`. Bun cross-compiles the coordinator; complete installation archives combine it with helpers built on each matching platform. Installed packages need neither Bun nor Node. Full Linux release packages target Ubuntu 24.04 or a compatible glibc/libstdc++ environment; Mac packages require Apple Silicon and macOS 14+. Linux x64 coordinators use Bun's baseline CPU target. Native helper CPU/CUDA compatibility remains determined by its CMake build flags.

The release workflow produces complete platform tarballs and SHA-256 checksums, including `sotto-server-linux-x64-cuda.tar.gz`. Extract a package, retain its `server` directory together, install the pinned model weights separately, then use the arguments below. On Linux the CUDA package already includes the systemd unit described above. Developer ID distribution still requires signing/notarization credentials; the draft Mac build is ad-hoc signed with Bun's executable entitlements.

The archive lock uses Bun FFI to call libc `flock`, matching the reference Swift server. This dependency is tested from source and compiled executables on the supported platforms. A running Swift server and Bun server must never share a data directory.

`SOTTO_BUILD_JOBS` controls build concurrency. For another CPU host, use `SOTTO_NATIVE=OFF`. The published Linux GPU package is `sotto-server-linux-x64-cuda.tar.gz`; the release job builds it with `docker build --target cuda-package`. CPU packages remain the no-GPU fallback.

## Run

From the repository root, with the models installed above:

```sh
./build/server/sotto-server \
  --host 127.0.0.1 --port 8391 \
  --data-dir "$PWD/.local/server" \
  --speech-helper "$PWD/build/server/helpers/sotto-engine" \
  --speech-model "$PWD/.local/models/ggml-large-v3-turbo.bin" \
  --vad-model "$PWD/build/server/resources/silero-vad.bin" \
  --proof-helper "$PWD/build/server/helpers/sotto-text-engine" \
  --proof-model "$PWD/.local/models/Qwen3-4B-Instruct-2507-MLX-4bit"
```

On Linux, replace the last path with the GGUF file. Add `--dev` for a development label in health responses. If using the packaged distribution elsewhere, point helper/resource paths at that package and choose durable model/data paths.

Check `curl http://localhost:8391/v1/health`; HTTP reachability alone does not mean the models are ready. The `ready` field means the server can accept a recording. Quitting a client does not stop this process. The scripts do not install a service. Linux installs `sotto-server.service` once, as above. macOS can use launchd, and containers use the image entrypoint.

For server-only development alongside an installed Sotto instance, use `--port 8392 --data-dir "$PWD/.local/typescript-server" --dev` with your helper/model arguments. Start the executable directly or use `bun run dev:server` with those arguments. The client dev runner starts the app and defaults to port 8391; avoid it when preserving a running installation.

| Argument | Environment variable |
| --- | --- |
| `--host`, `--port` | `SOTTO_SERVER_HOST`, `SOTTO_SERVER_PORT` |
| `--data-dir`, `--token-file` | `SOTTO_SERVER_DATA_DIR`, `SOTTO_SERVER_TOKEN_FILE` |
| `--speech-helper`, `--speech-model` | `SOTTO_ENGINE_PATH`, `SOTTO_SPEECH_MODEL` |
| `--vad-model` | `SOTTO_VAD_PATH` |
| `--proof-helper`, `--proof-model` | `SOTTO_TEXT_ENGINE_PATH`, `SOTTO_TEXT_MODEL` |
| `--dev` | `SOTTO_DEV=1` |

The dev runner fixes its host to loopback and defaults to port 8391, `.local/server` for data, and `.local/server.log` for logs. Set `SOTTO_SPEECH_MODEL` and `SOTTO_TEXT_MODEL` when using the paths above. Without those overrides, macOS searches the existing locations `~/Library/Application Support/Murmur/Models/ggml-large-v3-turbo.bin` and `~/.murmur/models/Qwen3-4B-Instruct-2507-MLX-4bit`.

## Remote access

Bind to a reachable address and pass `--token-file /absolute/path/to/token`. Nonloopback listeners require a token of at least 32 characters with no internal whitespace. In the Mac app, enter the endpoint and token under **This Mac**; tokens are stored in Keychain.

- Use an HTTPS reverse proxy for hosted servers and hostnames, including Tailscale MagicDNS names. The runner itself serves HTTP.
- HTTP is accepted for localhost and literal Tailscale IPs in `100.64.0.0/10` or `fd7a:115c:a1e0::/48` on your connected tailnet. Sotto checks the address range, not routing; use HTTPS if that private route cannot be assured.
- Ordinary LAN IPs require HTTPS. Endpoints cannot contain credentials, queries, or fragments. Credential-bearing redirects are not followed.

Keep the data directory on persistent storage and back it up. Only one runner can own it. See [storage](../docs/architecture.md#storage) and the [HTTP API](../docs/client-server-contract.md).

## Containers

Build from the repository root with initialized submodules:

```sh
docker build -f Server/Dockerfile --target cpu -t sotto-server:cpu .
docker build -f Server/Dockerfile --target cuda -t sotto-server:cuda .
```

`--target cpu` is the portable no-GPU image, and it is what an unqualified `docker build` selects. `--target cuda` is the container fallback when the host cannot place a matching CUDA 13.0.2 runtime next to the binary: that image copies the toolkit and sets `LD_LIBRARY_PATH`. `CUDA_ARCHITECTURES`, `CUDA_IMAGE`, `BUN_IMAGE`, `UBUNTU_IMAGE`, and `BUILD_JOBS` are build arguments. Choose CUDA architectures/toolkit/driver versions for your GPU. GPU containers require NVIDIA Container Toolkit and `--gpus all`; Linux containers on a Mac do not have Metal access.

Mount a directory containing the Whisper `.bin` and Qwen `.gguf` files, plus a token file:

```sh
docker run --rm --name sotto-server \
  -p 127.0.0.1:8391:8391 \
  --mount type=volume,source=sotto-data,target=/data \
  --mount type=bind,source=/absolute/path/to/models,target=/models,readonly \
  --mount type=bind,source=/absolute/path/to/token,target=/run/secrets/sotto-token,readonly \
  sotto-server:cpu
```

The example is the no-GPU image and exposes only host loopback; use the remote-access setup above for clients on other machines. For the container fallback, use `sotto-server:cuda` and add `--gpus all`. The container runs as UID 10001, which must be able to read model/token files and write `/data`. The named volume preserves history across container replacement.

## Verify

```sh
bun install --frozen-lockfile
bun run fmt
bun run fmt:check
bun run check
bun run test
bun run generate:api --check
swift test
./scripts/smoke-test.sh
SOTTO_TEXT_MODEL=/absolute/path/to/qwen ./scripts/test-corrections.sh
```

API generation/Swift checks need Swift 6.2+. Linux-only development can check TypeScript bindings with `bun run generate:api --check --typescript-only`. The reference Swift server/domain remain as a parity oracle; packaged server builds use TypeScript. See the [contract guide](api/README.md) for generated bindings and the [implementation plan](../docs/typescript-server-plan.md) for the migration.

The HTTP smoke test needs an idle Dev server with proofreading enabled. It uses public sample audio, checks progress/artifacts, temporarily changes and restores retention settings, and removes its test generations. The helper test accepts the MLX directory on Mac or GGUF file on Linux and uses synthetic text. Neither opens a microphone. These checks do not establish live cursor-insertion behavior or GPU performance on a different machine.
