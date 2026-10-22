#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
NATIVE_ROOT="${TMPDIR:-/private/tmp}/qingyu-native"
REVISION=fb129222ca6f7c7b066c8c70bc99ecd9c6330e8f
CMAKE="${CMAKE:-$(command -v cmake || true)}"
if [[ -z "$CMAKE" && -x "$HOME/.local/bin/cmake" ]]; then CMAKE="$HOME/.local/bin/cmake"; fi
[[ -n "$CMAKE" ]] || { print '需要 CMake 3.20+，请先安装 CMake。'; exit 1; }
mkdir -p "$NATIVE_ROOT"
if [[ ! -d "$NATIVE_ROOT/source/.git" ]]; then git clone --no-checkout https://github.com/0xShug0/audio.cpp.git "$NATIVE_ROOT/source"; fi
if ! git -C "$NATIVE_ROOT/source" cat-file -e "$REVISION^{commit}" 2>/dev/null; then git -C "$NATIVE_ROOT/source" fetch origin "$REVISION"; fi
git -C "$NATIVE_ROOT/source" checkout --detach "$REVISION"
"$CMAKE" -S "$NATIVE_ROOT/source" -B "$NATIVE_ROOT/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DAUDIOCPP_MODEL_SET=custom '-DAUDIOCPP_MODELS=vibevoice_asr;qwen3_asr' -DAUDIOCPP_BUILD_C_API=ON -DAUDIOCPP_DEPLOYMENT_BUILD=ON -DENGINE_ENABLE_METAL=ON -DENGINE_ENABLE_OPENMP=OFF -DAUDIOCPP_BUILD_NATIVE_MODEL_MANAGER=OFF
"$CMAKE" --build "$NATIVE_ROOT/build" --target audiocpp -j 4
mkdir -p .native
cp -R "$NATIVE_ROOT/build/bin/"*.dylib .native/
print '本地流式引擎已构建。'
