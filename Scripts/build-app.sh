#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
[[ -f .native/libaudiocpp.dylib ]] || ./Scripts/build-native.sh
BUILD_DIR="${TMPDIR:-/private/tmp}/voiceinput-swift-build"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/module-cache"
swift build "$@" -c release --cache-path "$BUILD_DIR/package-cache" --scratch-path "$BUILD_DIR"
APP_OUTPUT="$PWD/build/最后的轻语.app"
APP="$BUILD_DIR/最后的轻语.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD_DIR/release/VoiceInput" "$APP/Contents/MacOS/VoiceInput"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$PWD/.native/"*.dylib "$APP/Contents/Frameworks/"
install_name_tool -delete_rpath "$PWD/.native" "$APP/Contents/MacOS/VoiceInput"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/VoiceInput"
for voiceinput_library in "$APP/Contents/Frameworks/"*.dylib; do
    xattr -c "$voiceinput_library"
    codesign --force --sign - "$voiceinput_library"
done
mkdir -p "$APP/Contents/Resources"
cp -R "$BUILD_DIR/release/VoiceInput_VoiceInput.bundle" "$APP/Contents/Resources/"
ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PWD/Assets/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    pixels=$((size * 2))
    sips -z "$pixels" "$pixels" "$PWD/Assets/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VoiceInput</string>
<key>CFBundleIdentifier</key><string>local.voiceinput.mac</string>
<key>CFBundleName</key><string>最后的轻语</string>
<key>CFBundleDisplayName</key><string>最后的轻语</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSMicrophoneUsageDescription</key><string>录制你的语音并转换为输入文字。</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
voiceinput_signed=false
for voiceinput_attempt in 1 2 3; do
    xattr -r -d com.apple.FinderInfo "$APP" 2>/dev/null || true
    xattr -r -d com.apple.ResourceFork "$APP" 2>/dev/null || true
    if codesign --force --sign - "$APP" && codesign --verify --deep --strict "$APP"; then
        voiceinput_signed=true
        break
    fi
done
[[ "$voiceinput_signed" == true ]]
plutil -lint "$APP/Contents/Info.plist"
mkdir -p "$PWD/build"
ditto --norsrc --noextattr "$APP" "$APP_OUTPUT"
voiceinput_output_verified=false
for voiceinput_attempt in 1 2 3; do
    xattr -cr "$APP_OUTPUT"
    if codesign --verify --deep --strict "$APP_OUTPUT"; then
        voiceinput_output_verified=true
        break
    fi
done
[[ "$voiceinput_output_verified" == true ]]
print "已构建：$APP_OUTPUT"
