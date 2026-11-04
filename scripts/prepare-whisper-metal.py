#!/usr/bin/env python3
"""Build the pinned, statically linked whisper.cpp Metal backend for this arm64 app."""
import fcntl
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".build/native-whisper"
REVISION = "306c88f4d1286aec1bf96e544632897886af5501"
ARCHIVE_SHA256 = "f3585ebf64df3e41b26c45d93bdb38b423ca1de0bf40cc4b6d320254867a75df"

def digest(path):
    with path.open("rb") as stream:
        h = hashlib.sha256()
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            h.update(chunk)
        return h.hexdigest()

def build():
    CACHE.mkdir(parents=True, exist_ok=True)
    recipe = hashlib.sha256(Path(__file__).read_bytes() +
        subprocess.check_output(["xcrun", "clang", "--version"]) +
        subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"])).hexdigest()
    artifact = CACHE / recipe / "whisper.xcframework"
    with (CACHE / "build.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not (artifact / "macos-arm64/libwhisper.a").is_file():
            compile_artifact(artifact)
        link = CACHE / "whisper.xcframework"
        if link.resolve() != artifact:
            with tempfile.TemporaryDirectory(dir=CACHE) as temporary:
                staged = Path(temporary) / "link"
                staged.symlink_to(artifact.relative_to(CACHE), target_is_directory=True)
                staged.replace(link)

def compile_artifact(artifact):
    tool = shutil.which("cmake")
    env = dict(os.environ)
    if tool:
        cmake = [tool]
    elif shutil.which("uv"):
        cmake = ["uv", "tool", "run", "--from", "cmake==4.1.3", "cmake"]
        env["UV_CACHE_DIR"] = str(CACHE / "uv-cache")
        env["UV_TOOL_DIR"] = str(CACHE / "uv-tools")
    else:
        raise SystemExit("소스 첫 빌드에는 CMake 3.28 이상 또는 uv가 필요합니다.")
    with tempfile.TemporaryDirectory(dir=CACHE) as temporary:
        stage = Path(temporary)
        tarball = CACHE / (REVISION + ".tar.gz")
        if not tarball.exists() or digest(tarball) != ARCHIVE_SHA256:
            download = stage / "source.tar.gz"
            subprocess.run(["curl", "--fail", "--show-error", "--silent", "--location", "--retry", "2",
                            "--proto", "=https", "--proto-redir", "=https",
                            "https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/" + REVISION, "-o", str(download)], check=True)
            if digest(download) != ARCHIVE_SHA256:
                raise SystemExit("whisper.cpp 소스 체크섬이 다릅니다.")
            download.replace(tarball)
        src, output = stage / "src", stage / "build"
        src.mkdir()
        subprocess.run(["/usr/bin/tar","-xzf",str(tarball),"-C",str(src),"--strip-components","1"],check=True)
        subprocess.run(cmake + ["-S", str(src), "-B", str(output), "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0", "-DBUILD_SHARED_LIBS=OFF",
            "-DGGML_NATIVE=OFF", "-DGGML_METAL=ON", "-DGGML_METAL_EMBED_LIBRARY=ON",
            "-DGGML_BLAS=ON", "-DGGML_BLAS_VENDOR=Apple", "-DWHISPER_COREML=OFF",
            "-DWHISPER_BUILD_EXAMPLES=OFF", "-DWHISPER_BUILD_TESTS=OFF", "-DWHISPER_BUILD_SERVER=OFF"], env=env,check=True)
        subprocess.run(cmake + ["--build",str(output),"--target","whisper","--parallel","4"],env=env,check=True)
        package = stage / "whisper.xcframework"
        slice_dir = package / "macos-arm64"
        headers = slice_dir / "Headers"
        headers.mkdir(parents=True)
        archives = ["src/libwhisper.a","ggml/src/libggml.a","ggml/src/libggml-cpu.a",
                    "ggml/src/ggml-blas/libggml-blas.a","ggml/src/ggml-metal/libggml-metal.a","ggml/src/libggml-base.a"]
        subprocess.run(["xcrun","libtool","-static","-o",str(slice_dir / "libwhisper.a"),
                        *(str(output / name) for name in archives)],check=True)
        for header in [src / "include/whisper.h", *(src / "ggml/include").glob("*.h")]:
            shutil.copyfile(header, headers / header.name)
        (headers / "module.modulemap").write_text('module whisper { header "whisper.h" export * link "c++" link framework "Metal" link framework "MetalKit" link framework "Accelerate" }\n')
        (package / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundlePackageType":"XFWK", "XCFrameworkFormatVersion":"1.0", "AvailableLibraries":[{
                "LibraryIdentifier":"macos-arm64", "LibraryPath":"libwhisper.a", "HeadersPath":"Headers",
                "SupportedArchitectures":["arm64"], "SupportedPlatform":"macos"}]}))
        artifact.parent.mkdir(parents=True, exist_ok=True)
        package.rename(artifact)

if __name__=="__main__":
    build()
