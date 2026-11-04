#!/usr/bin/env python3
"""Exercise the real binary installer in temporary folders, without opening apps."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time


def run(*args, check=True):
    result = subprocess.run(args, text=True, capture_output=True, timeout=90)
    if check and result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download", action="store_true", help="also download the pinned ZIP from GitHub")
    parser.add_argument("--previous-version", help="exercise an upgrade from a published local ZIP, e.g. 0.8.0")
    options = parser.parse_args()
    if options.previous_version and not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", options.previous_version):
        parser.error("--previous-version requires a three-part release version")
    root = Path(__file__).resolve().parent.parent
    installer = root / "scripts/install.sh"
    version = re.search(r"local version=([0-9.]+)", installer.read_text()).group(1)
    archive = root / f"releases/Meeting-Recorder-{version}-macOS-arm64.zip"
    checks = []

    def passed(name):
        checks.append(name)
        print(f"PASS {name}", flush=True)

    with tempfile.TemporaryDirectory(prefix="recorder-installer-") as temporary:
        workspace = Path(temporary).resolve()
        # Spaces and regex metacharacters also exercise the process-path check.
        destination = workspace / "Apps [test]+ (local)"
        target = destination / "Meeting Recorder.app"
        binary = target / "Contents/MacOS/MeetingRecorder"
        mcp = target / "Contents/MacOS/MeetingRecorderMCP"

        def install(folder=destination, zip_path=archive, download=False):
            args = ["/bin/bash", str(installer), "--install-dir", str(folder), "--skip-model", "--no-open"]
            if not download:
                args += ["--archive", str(zip_path)]
            return run(*args, check=False)

        run("/bin/bash", "-n", str(installer))
        assert run("/bin/bash", str(installer), "--help").returncode == 0
        passed("system Bash syntax and help")

        result = install()
        assert result.returncode == 0, result.stdout + result.stderr
        with (target / "Contents/Info.plist").open("rb") as handle:
            assert plistlib.load(handle)["CFBundleShortVersionString"] == version
        assert binary.is_file() and mcp.is_file()
        old_inode = mcp.stat().st_ino
        passed("signed ZIP installs app and MCP into an isolated folder")

        clean_home = workspace / "new-user-home"
        clean_home.mkdir()
        clean_destination = workspace / "new-user-apps"
        result = subprocess.run(
            ["/bin/bash", str(installer), "--install-dir", str(clean_destination), "--skip-model", "--no-open", "--archive", str(archive)],
            text=True, capture_output=True, timeout=90, env={**os.environ, "HOME": str(clean_home)},
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert (clean_destination / "Meeting Recorder.app/Contents/MacOS/MeetingRecorder").is_file()
        assert not (clean_home / "Library/Application Support/Meeting Recorder/signing.json").exists()
        passed("release installs for a user with no signing configuration")

        result = install()
        assert result.returncode == 0, result.stdout + result.stderr
        backups = list((destination / ".meeting-recorder-backups").glob("*/Meeting Recorder.app"))
        assert len(backups) == 1
        assert (backups[0] / "Contents/MacOS/MeetingRecorderMCP").stat().st_ino == old_inode
        assert mcp.stat().st_ino != old_inode
        passed("same-signer update retains the old MCP executable inode")

        current_inode = mcp.stat().st_ino
        damaged = workspace / "damaged.zip"
        damaged.write_bytes(archive.read_bytes() + b"tampered")
        result = install(zip_path=damaged)
        assert result.returncode != 0 and "SHA-256" in result.stderr
        assert mcp.stat().st_ino == current_inode
        passed("checksum mismatch leaves the installed app untouched")

        lock = destination / ".meeting-recorder-install.lock"
        lock.mkdir()
        result = install()
        assert result.returncode != 0 and lock.is_dir()
        assert mcp.stat().st_ino == current_inode
        lock.rmdir()
        passed("concurrent installer lock is respected")

        # Simulate this exact executable path in argv without opening a recorder.
        process = subprocess.Popen(["/bin/bash", "-c", 'exec -a "$1" /bin/sleep 60', "bash", str(binary)])
        try:
            expression = "^" + re.escape(str(binary)) + r"([[:space:]]|$)"
            deadline = time.monotonic() + 3
            while run("/usr/bin/pgrep", "-f", expression, check=False).returncode != 0:
                assert time.monotonic() < deadline, "test process did not start"
                time.sleep(0.02)
            result = install()
            assert result.returncode != 0 and "실행 중" in result.stderr, result.stdout + result.stderr
            assert mcp.stat().st_ino == current_inode
        finally:
            process.terminate()
            process.wait(timeout=5)
        passed("running target blocks replacement, including paths with metacharacters")

        invalid_folder = workspace / "Invalid existing app"
        invalid_app = invalid_folder / "Meeting Recorder.app"
        invalid_app.mkdir(parents=True)
        sentinel = invalid_app / "preserve.txt"
        sentinel.write_text("existing user file")
        sentinel_inode = sentinel.stat().st_ino
        result = install(folder=invalid_folder)
        assert result.returncode != 0 and "기존 앱 서명" in result.stderr
        assert sentinel.stat().st_ino == sentinel_inode and sentinel.read_text() == "existing user file"
        passed("invalid existing app is refused without altering its files")

        link_folder = workspace / "Linked app"
        link_folder.mkdir()
        (link_folder / target.name).symlink_to(target)
        result = install(folder=link_folder)
        assert result.returncode != 0 and "심볼릭 링크" in result.stderr
        assert (link_folder / target.name).is_symlink() and mcp.stat().st_ino == current_inode
        passed("symlink targets are refused")

        assert run("/bin/bash", str(installer), "--install-dir", check=False).returncode != 0
        assert run("/bin/bash", str(installer), "--unknown", check=False).returncode != 0
        assert run("/bin/bash", str(installer), "--install-dir", "relative", check=False).returncode != 0
        assert run("/bin/bash", str(installer), "--ollama-model", "qwen3.5:4b", check=False).returncode != 0
        assert run("/bin/bash", str(installer), "--with-ollama", "--ollama-model", "qwen3:cloud", check=False).returncode != 0
        passed("invalid arguments are rejected")

        if options.previous_version:
            previous = options.previous_version
            assert tuple(map(int, previous.split("."))) < tuple(map(int, version.split("."))), "expected an older release"
            name = f"Meeting-Recorder-{previous}-macOS-arm64"
            previous_zip = root / "releases" / (name + ".zip")
            run(sys.executable, str(root / "scripts/check-release.py"), str(previous_zip))
            old_stage = workspace / "Old release"
            run("/usr/bin/ditto", "-x", "-k", str(previous_zip), str(old_stage))
            folder = workspace / "Upgrade"
            folder.mkdir()
            old_app = folder / "Meeting Recorder.app"
            (old_stage / name / old_app.name).rename(old_app)
            mcp_path = Path("Contents/MacOS/MeetingRecorderMCP")
            inode = (old_app / mcp_path).stat().st_ino
            result = install(folder=folder)
            assert result.returncode == 0, result.stdout + result.stderr
            backup, = (folder / ".meeting-recorder-backups").glob("*/Meeting Recorder.app")
            for bundle, expected in [(old_app, version), (backup, previous)]:
                assert plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"] == expected
            assert (backup / mcp_path).stat().st_ino == inode and (old_app / mcp_path).stat().st_ino != inode
            passed(f"published {previous} upgrades to {version} and preserves the previous MCP executable")

        if options.download:
            result = install(folder=workspace / "Downloaded", download=True)
            assert result.returncode == 0, result.stdout + result.stderr
            passed("pinned GitHub download and full app installation")

    print(f"{len(checks)}/{len(checks)} installer checks passed. Model preparation and GUI launch were skipped.")


if __name__ == "__main__":
    main()
