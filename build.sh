#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/output"
WORK="$ROOT/work"
MEDIA_VERSION=1.4.1
MEDIA_REF=1.4.1
MEDIA_URL=https://github.com/androidx/media.git
FFMPEG_VERSION=6.0
FFMPEG_REF=n6.0
FFMPEG_URL=https://github.com/FFmpeg/FFmpeg.git
NDK_VERSION=26.1.10909125
MIN_API=27
CMAKE_VERSION=3.22.1
COMPILE_SDK=34

mkdir -p "$OUT" "$WORK"
exec > >(tee "$OUT/build.log") 2>&1

echo '=== Ubuntu runner ==='
cat /etc/os-release
echo '=== Java ==='
java -version 2>&1
echo '=== NDK ==='
trap 'status=$?; if (( status != 0 )); then printf "build_status=FAILED\nexit_code=%s\n" "$status" > "$OUT/build-status.txt"; fi' EXIT

: "${ANDROID_SDK_ROOT:=${ANDROID_HOME:-}}"
: "${ANDROID_SDK_ROOT:?ANDROID_SDK_ROOT or ANDROID_HOME must be set}"
export ANDROID_SDK_ROOT
NDK="$ANDROID_SDK_ROOT/ndk/$NDK_VERSION"
[[ -x "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]] || { echo "Pinned NDK missing: $NDK"; exit 2; }
grep '^Pkg.Revision' "$NDK/source.properties"
"$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" --version
cmake --version | head -1

MEDIA_DIR="$WORK/androidx-media"
FFMPEG_DIR="$WORK/ffmpeg"
if [[ ! -d "$MEDIA_DIR/.git" ]]; then
  git clone --filter=blob:none --no-checkout "$MEDIA_URL" "$MEDIA_DIR"
fi
git -C "$MEDIA_DIR" fetch --depth 1 origin "+refs/tags/$MEDIA_REF:refs/tags/$MEDIA_REF"
git -C "$MEDIA_DIR" checkout --detach "$MEDIA_REF"
git -C "$MEDIA_DIR" reset --hard "$MEDIA_REF"
MEDIA_COMMIT="$(git -C "$MEDIA_DIR" rev-parse HEAD)"

# Override Media3 1.4.1's default minSdk 19 in the isolated checkout to target API 27.
MEDIA_CONSTANTS="$MEDIA_DIR/constants.gradle"
[[ -f "$MEDIA_CONSTANTS" ]] || { echo "Media3 constants.gradle missing"; exit 3; }
cp "$MEDIA_CONSTANTS" "$OUT/media3-1.4.1-constants.gradle.original"
sha256sum "$MEDIA_CONSTANTS" | tee "$OUT/media3-1.4.1-constants.gradle.original.sha256"
python3 - "$MEDIA_CONSTANTS" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = 'minSdkVersion = 19'
if text.count(old) != 1:
    raise SystemExit('Unexpected Media3 1.4.1 minSdk definition; refusing to patch')
path.write_text(text.replace(old, 'minSdkVersion = 27'))
PY

if [[ ! -d "$FFMPEG_DIR/.git" ]]; then
  git clone --filter=blob:none --no-checkout "$FFMPEG_URL" "$FFMPEG_DIR"
fi
git -C "$FFMPEG_DIR" fetch --depth 1 origin "+refs/tags/$FFMPEG_REF:refs/tags/$FFMPEG_REF"
git -C "$FFMPEG_DIR" checkout --detach "$FFMPEG_REF"
git -C "$FFMPEG_DIR" reset --hard "$FFMPEG_REF"
FFMPEG_COMMIT="$(git -C "$FFMPEG_DIR" rev-parse HEAD)"

MODULE_MAIN="$MEDIA_DIR/libraries/decoder_ffmpeg/src/main"
MODULE_GRADLE="$MEDIA_DIR/libraries/decoder_ffmpeg/build.gradle"
[[ -f "$MODULE_GRADLE" ]] || { echo "Media3 FFmpeg module build.gradle missing"; exit 3; }
cp "$MODULE_GRADLE" "$OUT/media3-1.4.1-decoder_ffmpeg-build.gradle.original"
sha256sum "$MODULE_GRADLE" | tee "$OUT/media3-1.4.1-decoder_ffmpeg-build.gradle.original.sha256"
python3 - "$MODULE_GRADLE" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
anchor = "android.namespace = 'androidx.media3.decoder.ffmpeg'\n"
if text.count(anchor) != 1:
    raise SystemExit('Unexpected Media3 FFmpeg module Gradle file; refusing to patch')
abi_filter = """android {
    defaultConfig {
        ndk {
            abiFilters 'armeabi-v7a', 'arm64-v8a'
        }
    }
}
"""
path.write_text(text.replace(anchor, anchor + '\n' + abi_filter))
PY
JNI_DIR="$MODULE_MAIN/jni"
OFFICIAL_SCRIPT="$JNI_DIR/build_ffmpeg.sh"
[[ -f "$OFFICIAL_SCRIPT" ]] || { echo "Media3 1.4.1 official FFmpeg build script missing"; exit 3; }
if [[ -e "$JNI_DIR/ffmpeg" || -L "$JNI_DIR/ffmpeg" ]]; then
  [[ -L "$JNI_DIR/ffmpeg" ]] || { echo "Unexpected non-symlink at $JNI_DIR/ffmpeg"; exit 3; }
  rm "$JNI_DIR/ffmpeg"
fi
ln -s "$FFMPEG_DIR" "$JNI_DIR/ffmpeg"

# Keep the official Media3 1.4.1 build script logic, removing only its x86 and x86_64 blocks.
# This avoids compiling unrequested ABIs while retaining the official FFmpeg configure flags.
cp "$OFFICIAL_SCRIPT" "$OUT/media3-1.4.1-build_ffmpeg.sh"
sha256sum "$OFFICIAL_SCRIPT" | tee "$OUT/media3-official-build-script.sha256"
python3 - "$OFFICIAL_SCRIPT" "$WORK/build_ffmpeg_arm_only.sh" <<'PY'
from pathlib import Path
import sys
src, dst = map(Path, sys.argv[1:])
text = src.read_text()
marker = './configure \\\n    --libdir=android-libs/x86 \\\n'
if text.count(marker) != 1:
    raise SystemExit('Unexpected official Media3 build script layout; refusing to patch')
text = text.split(marker, 1)[0].rstrip() + '\n'
dst.write_text(text)
PY
chmod +x "$WORK/build_ffmpeg_arm_only.sh"
"$WORK/build_ffmpeg_arm_only.sh" "$MODULE_MAIN" "$NDK" linux-x86_64 "$MIN_API" flac

cd "$MEDIA_DIR"
./gradlew --no-daemon --stacktrace :lib-decoder-ffmpeg:assembleRelease
AAR="$(find libraries/decoder_ffmpeg/build/outputs/aar -maxdepth 1 -type f -name '*.aar' -print -quit)"
[[ -n "$AAR" && -f "$AAR" ]] || { echo 'Gradle completed but no decoder FFmpeg AAR was found'; exit 4; }
cp "$AAR" "$OUT/media3-decoder-ffmpeg-1.4.1-flac-armv7-arm64.aar"

python3 "$ROOT/scripts/validate_artifact.py" \
  "$OUT/media3-decoder-ffmpeg-1.4.1-flac-armv7-arm64.aar" \
  "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf" \
  "$OUT/aar-validation.txt"
sha256sum "$OUT"/*.aar > "$OUT/SHA256SUMS.txt"

NDK_REVISION="$(grep '^Pkg.Revision' "$NDK/source.properties" | head -1 | cut -d= -f2- | xargs)"
cat > "$OUT/build-manifest.txt" <<EOF
Media3 version: $MEDIA_VERSION
Media3 ref: $MEDIA_REF
Media3 commit: $MEDIA_COMMIT
FFmpeg version: $FFMPEG_VERSION
FFmpeg ref: $FFMPEG_REF
FFmpeg commit: $FFMPEG_COMMIT
NDK package: $NDK_VERSION
NDK source.properties revision: $NDK_REVISION
Media3 minSdk override: 27
Compile SDK: $COMPILE_SDK
CMake: $CMAKE_VERSION
Android native minimum API: $MIN_API
ABIs: armeabi-v7a, arm64-v8a
Enabled FFmpeg decoder: flac
FFmpeg components: static avcodec/avutil/swresample; no avformat/video pipeline
AAR SHA-256: $(sha256sum "$OUT/media3-decoder-ffmpeg-1.4.1-flac-armv7-arm64.aar" | cut -d' ' -f1)
EOF
printf 'build_status=SUCCESS\n' > "$OUT/build-status.txt"
cat "$OUT/build-manifest.txt"
echo 'AAR validation:'
cat "$OUT/aar-validation.txt"