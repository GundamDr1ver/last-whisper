#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEXT_ROOT="${TMPDIR:-/private/tmp}/speakeasy-wetext"
REVISION=0c9395098e122e60e649250877637b7c332dc433
CMAKE="${CMAKE:-$(command -v cmake || true)}"
if [[ -z "$CMAKE" && -x "$HOME/.local/bin/cmake" ]]; then CMAKE="$HOME/.local/bin/cmake"; fi
[[ -n "$CMAKE" ]] || { print '需要 CMake 3.20+。'; exit 1; }
mkdir -p "$TEXT_ROOT"
if [[ ! -d "$TEXT_ROOT/source/.git" ]]; then git clone --no-checkout https://github.com/wenet-e2e/WeTextProcessing.git "$TEXT_ROOT/source"; fi
if ! git -C "$TEXT_ROOT/source" cat-file -e "$REVISION^{commit}" 2>/dev/null; then git -C "$TEXT_ROOT/source" fetch origin "$REVISION"; fi
git -C "$TEXT_ROOT/source" checkout --detach "$REVISION"
"$CMAKE" -S "$TEXT_ROOT/source/runtime" -B "$TEXT_ROOT/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DBUILD_SHARED_LIBS=OFF
"$CMAKE" --build "$TEXT_ROOT/build" --target wetext_processor_c -j 4
mkdir -p .native Sources/VoiceInput/Resources/WeText
cp "$TEXT_ROOT/build/processor/libwetext_processor_c.dylib" .native/
install_name_tool -id '@rpath/libwetext_processor_c.dylib' .native/libwetext_processor_c.dylib
for graph in tagger verbalizer; do
    graph_path="Sources/VoiceInput/Resources/WeText/zh_itn_${graph}.fst"
    if [[ ! -f "$graph_path" ]]; then
        curl -fL --max-time 180 "https://github.com/wenet-e2e/WeTextProcessing/releases/download/WeTextProcessing/zh_itn_${graph}.fst" -o "$TEXT_ROOT/${graph}.fst"
        cp "$TEXT_ROOT/${graph}.fst" "$graph_path"
    fi
done
print 'ae9f5389aa65c1d24dc7bc761fe0b9c751bb76a152cc917af5bc52bb93b76563  Sources/VoiceInput/Resources/WeText/zh_itn_tagger.fst
6aead1b68211a2bb56b6805e7840034e076b17b176d703cea153d15262680f53  Sources/VoiceInput/Resources/WeText/zh_itn_verbalizer.fst' | shasum -a 256 -c -
cp "$TEXT_ROOT/source/itn/chinese/data/default/whitelist.tsv" Sources/VoiceInput/Resources/WeText/protected-words.tsv
cp "$TEXT_ROOT/source/LICENSE" Sources/VoiceInput/Resources/NativeLicenses/wetext-LICENSE.txt
cp "$TEXT_ROOT/build/_deps/openfst-src/COPYING" Sources/VoiceInput/Resources/NativeLicenses/openfst-LICENSE.txt
cp "$TEXT_ROOT/build/_deps/glog-src/COPYING" Sources/VoiceInput/Resources/NativeLicenses/glog-LICENSE.txt
cp "$TEXT_ROOT/build/_deps/gflags-src/COPYING.txt" Sources/VoiceInput/Resources/NativeLicenses/gflags-LICENSE.txt
