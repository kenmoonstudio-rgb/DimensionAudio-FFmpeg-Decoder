#!/usr/bin/env python3
"""Validate Media3 FFmpeg AAR contents and ABI-specific ELF metadata."""
from __future__ import annotations
import hashlib
import pathlib
import subprocess
import sys
import tempfile
import zipfile

if len(sys.argv) != 4:
    raise SystemExit("usage: validate_artifact.py AAR LLVM_READELF REPORT")
aar = pathlib.Path(sys.argv[1])
readelf = pathlib.Path(sys.argv[2])
report = pathlib.Path(sys.argv[3])
expected = {"armeabi-v7a": "ARM", "arm64-v8a": "AArch64"}
lines: list[str] = []
with zipfile.ZipFile(aar) as archive:
    names = archive.namelist()
    for required in ("AndroidManifest.xml", "classes.jar"):
        if required not in names or archive.getinfo(required).file_size == 0:
            raise SystemExit(f"Invalid AAR: missing or empty {required}")
    native = sorted(n for n in names if n.startswith("jni/") and n.endswith(".so"))
    actual_abis = {n.split("/")[1] for n in native if len(n.split("/")) > 2}
    if actual_abis != set(expected):
        raise SystemExit(f"Unexpected ABI set: expected {sorted(expected)}, got {sorted(actual_abis)}")
    lines.append(f"AAR: {aar.name}")
    lines.append(f"AAR SHA-256: {hashlib.sha256(aar.read_bytes()).hexdigest()}")
    lines.append("AAR entries:")
    lines.extend(f"  {n}" for n in names)
    lines.append("Native libraries:")
    lines.extend(f"  {n}" for n in native)
    for abi, machine in expected.items():
        prefix = f"jni/{abi}/"
        entries = [n for n in native if n.startswith(prefix)]
        ffmpeg_jni = f"{prefix}libffmpegJNI.so"
        if ffmpeg_jni not in entries:
            raise SystemExit(f"Missing {ffmpeg_jni}; Media3 FFmpeg JNI did not build for {abi}")
        if archive.getinfo(ffmpeg_jni).file_size <= 0:
            raise SystemExit(f"Empty native library: {ffmpeg_jni}")
        # FFmpeg's avcodec/avutil/swresample are linked statically by Media3's official CMake file.
        shared_av = [n for n in entries if pathlib.PurePosixPath(n).name.startswith(("libav", "libswresample"))]
        if shared_av:
            raise SystemExit(f"Unexpected dynamically packaged FFmpeg libraries: {shared_av}")
        cxx = [n for n in entries if pathlib.PurePosixPath(n).name == "libc++_shared.so"]
        if len(cxx) > 1:
            raise SystemExit(f"Duplicate libc++_shared.so entries for {abi}: {cxx}")
        with tempfile.TemporaryDirectory() as temp:
            extracted = pathlib.Path(temp) / "libffmpegJNI.so"
            extracted.write_bytes(archive.read(ffmpeg_jni))
            result = subprocess.run([str(readelf), "-h", str(extracted)], text=True, capture_output=True, check=True)
            header = result.stdout
            actual = next((line.split(":", 1)[1].strip() for line in header.splitlines() if "Machine:" in line), "unknown")
            if machine not in actual:
                raise SystemExit(f"{abi} ELF machine mismatch: expected {machine}, got {actual}")
            dyn = subprocess.run([str(readelf), "-d", str(extracted)], text=True, capture_output=True, check=True).stdout
            needed = [line.strip() for line in dyn.splitlines() if "(NEEDED)" in line]
            if any("libavcodec.so" in line or "libavutil.so" in line or "libswresample.so" in line for line in needed):
                raise SystemExit(f"FFmpeg shared-library dependency unexpectedly remains: {needed}")
            lines.append(f"{abi}: PASS; ELF machine={actual}; NEEDED={'; '.join(needed) if needed else '(none)'}")
            lines.append(f"{abi}: libc++_shared.so entries={len(cxx)}")
    lines.append("ABI coverage: PASS (armeabi-v7a + arm64-v8a)")
report.write_text("\n".join(lines) + "\n")
print(report.read_text(), end="")