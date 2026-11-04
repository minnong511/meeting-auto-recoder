#!/usr/bin/env python3
"""Exercise the bundled updater on signed disposable apps; never open the real recorder."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PROGRAM = Path("Meeting Recorder.app/Contents/MacOS/MeetingRecorderUpdater")
HELPER = next((ROOT / folder / PROGRAM for folder in ("dist/package", "dist") if (ROOT / folder / PROGRAM).is_file()),
              ROOT / ".build/release/MeetingRecorderUpdater")
spec = importlib.util.spec_from_file_location("app_signing", ROOT / "scripts/app-signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


def build_app(app, version, binary):
    mac = app / "Contents/MacOS"
    mac.mkdir(parents=True)
    shutil.copy2(binary, mac / "MeetingRecorder")
    shutil.copy("/usr/bin/true", mac / "MeetingRecorderMCP")
    res = app / "Contents/Resources"
    res.mkdir()
    (res / "test.txt").write_text(version)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "dev.meetingrecorder.prototype", "CFBundleExecutable": "MeetingRecorder",
        "CFBundleName": "Recorder Update Test", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version, "CFBundleVersion": "1", "LSMinimumSystemVersion": "26.0",
    }))
    signing.sign(app, app.parent / "absent.app")


def pack(folder, path):
    subprocess.run(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent", folder, path], check=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    with tempfile.TemporaryDirectory(prefix="recorder-update-test-") as tmp:
        base = Path(tmp).resolve()
        opened = base / "reopened"
        source, binary = base / "probe.c", base / "probe"
        source.write_text('#include <stdio.h>\nint main(void) { FILE *f = fopen(' +
                          json.dumps(str(opened)) + ', "w"); if (!f) return 1; return fclose(f); }\n')
        subprocess.run(["xcrun", "clang", source, "-o", binary], check=True)
        target = base / "Apps [QA]+" / "Meeting Recorder.app"
        bundle = base / "Meeting-Recorder-0.8.3-macOS-arm64"
        new = bundle / target.name
        build_app(target, "0.8.2", binary)
        build_app(new, "0.8.3", binary)
        archive = base / (bundle.name + ".zip")
        pack(bundle, archive)
        mcp = Path("Contents/MacOS/MeetingRecorderMCP")
        inode = (target / mcp).stat().st_ino
        lock = target.parent / ".meeting-recorder-install.lock"

        def args(file=archive, version="0.8.3", sha=None):
            return [str(HELPER), str(target), version, sha or digest(file), str(file)]

        def reject(argv, message):
            result = subprocess.run(argv, input="", text=True, capture_output=True, timeout=15)
            assert result.returncode and message in result.stdout, result
            assert (target / mcp).stat().st_ino == inode and not opened.exists()

        reject(args(sha="0" * 64), "SHA-256")
        reject(args(version="0.8.2"), "새로운 버전")
        lock.mkdir()
        reject(args(), "잠글 수")
        lock.rmdir()
        malicious = base / "paths.zip"
        with zipfile.ZipFile(malicious, "w") as output:
            output.writestr(bundle.name + "/../unexpected", "test")
        reject(args(malicious), "허용되지 않은")
        (new / "Contents/Resources/test.txt").write_text("changed after signing")
        invalid = base / "signature.zip"
        pack(bundle, invalid)
        reject(args(invalid), "서명")
        print("PASS checksum, downgrade, install lock, archive paths, and tampered code rejection", flush=True)

        # EOF before INSTALL models both user quit and new work starting during verification.
        probe = subprocess.run(args(), input="", text=True, capture_output=True, timeout=15)
        assert probe.returncode == 0 and probe.stdout == "READY\n", probe
        assert (target / mcp).stat().st_ino == inode and not opened.exists() and not lock.exists()
        print("PASS prepare and withdraw leaves the old app running", flush=True)

        # The helper must observe its real parent exit before it can exchange the bundles.
        parent = """
import subprocess, sys
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
msg = p.stdout.readline()
assert msg == "READY\\n", msg
p.stdin.write("INSTALL\\n")
p.stdin.close()
"""
        subprocess.run([sys.executable, "-c", parent, *args()], check=True, timeout=15)
        deadline = time.monotonic() + 25
        while (not opened.exists() or lock.exists()) and time.monotonic() < deadline:
            time.sleep(0.1)
        assert opened.exists() and not lock.exists(), "updated test executable did not reopen"
        backup, = (target.parent / ".meeting-recorder-backups").glob("previous-*/*.app")
        assert (backup / mcp).stat().st_ino == inode and (target / mcp).stat().st_ino != inode
        for app, version in [(backup, "0.8.2"), (target, "0.8.3")]:
            assert plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"] == version
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", target], check=True)
        print("PASS atomic replacement after parent exit, original MCP inode, and real Launch Services reopen")


if __name__ == "__main__":
    main()
