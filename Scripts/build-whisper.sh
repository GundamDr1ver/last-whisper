#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
WHISPER_ROOT="${TMPDIR:-/private/tmp}/qingyu-whisper"
REVISION=2eeeba56e9edd762b4b38467bab96c2517163158
CMAKE="${CMAKE:-$(command -v cmake || true)}"
if [[ -z "$CMAKE" && -x "$HOME/.local/bin/cmake" ]]; then CMAKE="$HOME/.local/bin/cmake"; fi
[[ -n "$CMAKE" ]] || { print '需要 CMake 3.20+。'; exit 1; }
mkdir -p "$WHISPER_ROOT"
if [[ ! -d "$WHISPER_ROOT/source/.git" ]]; then git clone --depth 1 --branch v1.8.3 https://github.com/ggml-org/whisper.cpp.git "$WHISPER_ROOT/source"; fi
if ! git -C "$WHISPER_ROOT/source" cat-file -e "$REVISION^{commit}" 2>/dev/null; then git -C "$WHISPER_ROOT/source" fetch origin "$REVISION"; fi
git -C "$WHISPER_ROOT/source" checkout --detach "$REVISION"
"$CMAKE" -S "$WHISPER_ROOT/source" -B "$WHISPER_ROOT/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_OPENMP=OFF
"$CMAKE" --build "$WHISPER_ROOT/build" --target whisper-cli -j 4
mkdir -p .native
cp "$WHISPER_ROOT/build/bin/whisper-cli" .native/whisper-cli
cp "$WHISPER_ROOT/source/LICENSE" Sources/VoiceInput/Resources/NativeLicenses/whisper-LICENSE.txt
