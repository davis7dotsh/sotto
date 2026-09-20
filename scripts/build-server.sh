#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
build_jobs="${SOTTO_BUILD_JOBS:-8}"
server_platform=$(uname -s)
server_architecture=$(uname -m)
if [[ "$server_platform" != Darwin && "$server_platform" != Linux ]]; then
    printf 'The Sotto server supports macOS and Linux.\n' >&2
    exit 1
fi
if [[ "$server_platform" == Linux && "$server_architecture" != x86_64 && \
      "$server_architecture" != aarch64 && "$server_architecture" != arm64 ]]; then
    printf 'Linux server packages support x86_64 and ARM64.\n' >&2
    exit 1
fi
dependencies=(bun)
if [[ "${SOTTO_SKIP_NATIVE:-0}" != 1 ]]; then
    dependencies+=(cmake)
    if [[ "$server_platform" == Darwin ]]; then dependencies+=(swift); fi
fi
for dependency in "${dependencies[@]}"; do
    if ! command -v "$dependency" >/dev/null; then
        printf 'Missing build dependency: %s\n' "$dependency" >&2
        exit 1
    fi
done
if [[ "${SOTTO_SKIP_NATIVE:-0}" != 1 && \
      ( ! -f vendor/whisper.cpp/include/whisper.h || ! -f vendor/llama.cpp/include/llama.h ) ]]; then
    git submodule update --init --recursive
fi

native_flags=(-DCMAKE_BUILD_TYPE=Release "-DSOTTO_CUDA=${SOTTO_CUDA:-OFF}")
if [[ "$server_platform" == Darwin ]]; then
    if [[ "$server_architecture" != arm64 ]]; then
        printf 'The macOS server uses MLX and requires Apple Silicon.\n' >&2
        exit 1
    fi
    native_flags+=(-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64)
fi
if [[ -n "${SOTTO_CUDA_ARCHITECTURES:-}" ]]; then
    native_flags+=("-DCMAKE_CUDA_ARCHITECTURES=$SOTTO_CUDA_ARCHITECTURES")
fi
if [[ -n "${SOTTO_NATIVE:-}" ]]; then
    native_flags+=("-DGGML_NATIVE=$SOTTO_NATIVE")
fi
if [[ "${SOTTO_SKIP_NATIVE:-0}" == 1 ]]; then
    # Reuse explicitly selected helpers without rebuilding or modifying them.
    # This is useful for isolated server development beside an installed app.
    : "${SOTTO_ENGINE_PATH:?Set SOTTO_ENGINE_PATH when SOTTO_SKIP_NATIVE=1}"
    : "${SOTTO_TEXT_ENGINE_PATH:?Set SOTTO_TEXT_ENGINE_PATH when SOTTO_SKIP_NATIVE=1}"
    : "${SOTTO_VAD_PATH:?Set SOTTO_VAD_PATH when SOTTO_SKIP_NATIVE=1}"
    speech_helper="$SOTTO_ENGINE_PATH"
    text_helper="$SOTTO_TEXT_ENGINE_PATH"
    text_helper_dir=$(dirname "$text_helper")
    vad_model="$SOTTO_VAD_PATH"
else
    cmake -S . -B .build/server-native "${native_flags[@]}"
    cmake --build .build/server-native --target sotto-engine --parallel "$build_jobs"
    if [[ "$server_platform" == Darwin ]]; then
        ./scripts/build-text-engine.sh
        text_helper_dir="$project_dir/.build/text-native"
    else
        cmake -S TextEngine -B .build/server-llama "${native_flags[@]}"
        cmake --build .build/server-llama --target sotto-text-engine --parallel "$build_jobs"
        text_helper_dir="$project_dir/.build/server-llama"
    fi
    ./scripts/download-vad.sh
    speech_helper="$project_dir/.build/server-native/Engine/sotto-engine"
    text_helper="$text_helper_dir/sotto-text-engine"
    vad_model="$project_dir/.build/models/silero-vad.bin"
fi
test -x "$speech_helper"
test -x "$text_helper"
test -f "$vad_model"
bun install --frozen-lockfile

mkdir -p build
staging_dir=$(mktemp -d "$project_dir/build/.server.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
mkdir -p "$staging_dir/helpers" "$staging_dir/resources"
bun run --cwd Server build --outfile "$staging_dir/sotto-server"
cp "$speech_helper" "$staging_dir/helpers/sotto-engine"
cp "$text_helper" "$staging_dir/helpers/sotto-text-engine"
if [[ "$server_platform" == Darwin ]]; then
    cp "$text_helper_dir/mlx.metallib" "$staging_dir/helpers/mlx.metallib"
    for bundle in "$text_helper_dir/resources/"*.bundle "$text_helper_dir/"*.bundle; do
        [[ -d "$bundle" ]] || continue
        ditto "$bundle" "$staging_dir/helpers/$(basename "$bundle")"
    done
    codesign --force --sign - "$staging_dir/helpers/sotto-engine"
    codesign --force --sign - "$staging_dir/helpers/sotto-text-engine"
    # Preserve Bun's JIT permissions when signing the bundled runtime.
    codesign --force --sign - --entitlements Server/entitlements.plist "$staging_dir/sotto-server"
fi
cp "$vad_model" "$staging_dir/resources/silero-vad.bin"
for library in whisper llama; do
    license_path="$project_dir/vendor/$library.cpp/LICENSE"
    if [[ ! -f "$license_path" && "${SOTTO_SKIP_NATIVE:-0}" == 1 ]]; then
        license_path="$(dirname "$vad_model")/$library-LICENSE.txt"
    fi
    if [[ ! -f "$license_path" ]]; then
        printf 'Missing %s license; initialize submodules or reuse a complete helper/resource package.\n' "$library" >&2
        exit 1
    fi
    cp "$license_path" "$staging_dir/resources/$library-LICENSE.txt"
done
cp Resources/*-LICENSE.txt THIRD_PARTY_NOTICES.md "$staging_dir/resources/"
bun Server/scripts/licenses.ts "$staging_dir/resources/javascript-LICENSES.txt"
cp Server/README.md "$staging_dir/README.md"
if [[ "$server_platform" == Linux ]]; then
    cp Server/sotto-server.service "$staging_dir/sotto-server.service"
fi
prior_package="$project_dir/build/.server-previous-$$"
if [[ -d build/server ]]; then mv build/server "$prior_package"; fi
if ! mv "$staging_dir" "$project_dir/build/server"; then
    if [[ -d "$prior_package" ]]; then mv "$prior_package" "$project_dir/build/server"; fi
    exit 1
fi
rm -rf "$prior_package"
printf '\nBuilt %s/build/server\n' "$project_dir"
