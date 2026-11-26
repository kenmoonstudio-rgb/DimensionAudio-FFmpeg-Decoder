# DimensionAudio Media3 1.4.1 FFmpeg FLAC Builder

An isolated GitHub Actions project for building the official AndroidX Media3 1.4.1 FFmpeg decoder extension with only the FLAC decoder enabled, for `armeabi-v7a` and `arm64-v8a`. It does not edit or depend on the DimensionAudio Android checkout.

## Pinned inputs

See [`versions.lock`](versions.lock). The build uses the Media3 `1.4.1` tag and FFmpeg `n6.0` (FFmpeg 6.0), which Media3 1.4.1 documents as its recommended FFmpeg version. The workflow uses Ubuntu 24.04, JDK 17, Android NDK r26b (`26.1.10909125`), Android API 27 as the artifact/native minimum, compile SDK 34, and CMake 3.22.1. The actual resolved Git commit for both source tags is recorded in `output/build-manifest.txt` for each run.

The Media3 documentation says the extension should be built from its source checkout, recommends FFmpeg 6.0, and documents NDK r26b plus the ABI/API relationship. This project keeps the official 1.4.1 `build_ffmpeg.sh` and applies a checked, minimal transformation that removes only x86/x86_64 targets. It fails closed if the upstream script layout changes.

## Run in GitHub Actions

1. Create a separate GitHub repository for this folder and push its contents.
2. In Actions, run **Build Media3 1.4.1 FFmpeg FLAC AAR** (or push to `main`/`master`).
3. Download the workflow artifact `media3-1.4.1-ffmpeg-flac-armv7-arm64`.

The workflow uploads `output/` even if the build fails, so logs and failure status remain available. On success it contains:

- `media3-decoder-ffmpeg-1.4.1-flac-armv7-arm64.aar`
- `build.log`
- `build-manifest.txt` (source commit IDs, versions, API, and AAR SHA-256)
- `aar-validation.txt` (AAR entries and per-ABI ELF validation)
- `media3-1.4.1-build_ffmpeg.sh` (the unmodified upstream script used as source)
- `media3-official-build-script.sha256`
- `build-status.txt`
- `SHA256SUMS.txt`

## Feature and ABI scope

The official FFmpeg build script is configured with `--disable-everything --enable-decoder=flac`. The required static `avcodec`, `avutil`, and `swresample` components are linked into Media3's `libffmpegJNI.so`; no FFmpeg shared `libav*.so`, video pipeline, encoder set, or avformat demuxer is added. Media3's own FLAC extractor remains part of Media3 and is not replaced.

The build overrides Media3 1.4.1 default minSdk 19 to 27 in the isolated checkout, controlling AAR metadata and Gradle CMake target. FFmpeg cross-compilation also uses API 27, matching Android 8.1. A successful build proves both ABI binaries were compiled against that API target, but loading must still be confirmed on actual API 27 hardware in the later integration step.

## AAR and native-library notes

This is the Media3 decoder module AAR, not a standalone player. The Media3 module declares its normal Media3 1.4.1 dependencies; the build does not bundle or change those modules. The validator checks for `libffmpegJNI.so` under both requested ABI folders, ELF machine type, absence of dynamically packaged FFmpeg component libraries, and at most one `libc++_shared.so` entry per ABI.

The validator cannot prove that this AAR can be merged with DimensionAudio's native libraries without duplicate-path conflicts because this independent project intentionally does not perform the integration. It will make any `libc++_shared.so` included in this AAR visible in the validation report. The downstream Gradle merge must then be checked against the app's `dimension_audio_core` packaging. FFmpeg's component libraries are static here, so they do not introduce `libavcodec.so`, `libavutil.so`, or `libswresample.so` names that could collide with app libraries.

## Licensing

The Media3 source is Apache-2.0. FFmpeg is separately licensed; this configuration enables only its FLAC decoder and required LGPL-compatible components, without GPL/nonfree options. Review the exact FFmpeg license obligations and provide required notices when distributing the AAR or an app that includes it.