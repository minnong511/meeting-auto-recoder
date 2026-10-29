#!/usr/bin/env python3
"""Sign staged releases and refuse identity changes before replacing the app."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

CONFIG = Path.home() / "Library/Application Support/Meeting Recorder/signing.json"


def run(*arguments, check=True):
    result = subprocess.run(arguments, text=True, capture_output=True)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or "명령을 실행하지 못했습니다.")
    return result


def configuration():
    if not CONFIG.is_file():
        raise RuntimeError("고정 서명 설정이 없습니다. 먼저 python3 scripts/setup-local-signing.py 를 실행하세요. 임시 서명으로 대체하지 않습니다.")
    config = json.loads(CONFIG.read_text())
    if not re.fullmatch(r"[A-Fa-f0-9]{40}", config["identity"]) or not Path(config["keychain"]).is_file():
        raise RuntimeError("서명 설정이 올바르지 않습니다.")
    identities = run("/usr/bin/security", "find-identity", "-p", "codesigning", config["keychain"]).stdout
    if config["identity"].upper() not in identities.upper():
        raise RuntimeError("고정 인증서의 개인 키가 키체인에 없습니다. 인증서를 재생성하지 말고 키체인을 확인하세요.")
    return config


def requirement(app):
    result = run("/usr/bin/codesign", "-d", "-r-", str(app))
    for line in (result.stdout + result.stderr).splitlines():
        line = line.removeprefix("# ")
        if line.startswith("designated => "):
            return line.removeprefix("designated => ")
    raise RuntimeError("앱의 서명 식별 조건을 찾을 수 없습니다.")


def verify_update(old, new):
    old_requirement, new_requirement = requirement(old), requirement(new)
    forward = run("/usr/bin/codesign", "--verify", "--strict", "-R=" + old_requirement, str(new), check=False)
    backward = run("/usr/bin/codesign", "--verify", "--strict", "-R=" + new_requirement, str(old), check=False)
    if forward.returncode or backward.returncode:
        if os.environ.get("RECORDER_ALLOW_SIGNING_MIGRATION") != "1":
            raise RuntimeError("기존 앱과 서명 식별 조건이 달라 업데이트를 중단했습니다. 최초 전환에만 RECORDER_ALLOW_SIGNING_MIGRATION=1 을 사용하고 녹음 권한을 한 번 재등록하세요.")
        print("주의: 서명 인증서를 전환합니다. 이번 한 번은 macOS 녹음 권한을 재등록해야 합니다.", file=sys.stderr)
    else:
        print("업데이트 전후 서명 식별 조건 호환 확인 완료.")


def sign(staged, target):
    config = configuration()
    options = ["--force", "--sign", config["identity"], "--keychain", config["keychain"], "--timestamp=none", "--options", "runtime"]
    run("/usr/bin/codesign", *options, "--identifier", "dev.meetingrecorder.prototype.mcp", str(staged / "Contents/MacOS/MeetingRecorderMCP"))
    root = Path(__file__).resolve().parent.parent
    run("/usr/bin/codesign", *options, "--entitlements", str(root / "Resources/Entitlements.plist"), str(staged))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged))
    for code in (staged, staged / "Contents/MacOS/MeetingRecorderMCP"):
        run("/usr/bin/codesign", "--verify", "-R=certificate leaf = H\"" + config["identity"] + "\"", str(code))
    if target.exists():
        verify_update(target, staged)


def install(staged, target):
    # Never replace the executable under an active recording. MCP clients keep
    # their existing executable inode when the complete bundle is swapped.
    executable = target / "Contents/MacOS/MeetingRecorder"
    running = run("/usr/bin/pgrep", "-f", "^" + re.escape(str(executable)) + r"($|\s)", check=False)
    if running.returncode == 0:
        raise RuntimeError("Meeting Recorder가 실행 중입니다. 녹음을 마치고 앱을 종료한 뒤 업데이트하세요. 기존 앱은 변경하지 않았습니다.")
    if running.returncode != 1:
        raise RuntimeError("실행 중인 앱을 확인하지 못해 업데이트를 중단했습니다.")
    backup = None
    if target.exists():
        backups = Path(__file__).resolve().parent.parent / ".build/app-backups"
        backups.mkdir(parents=True, exist_ok=True)
        backup = Path(tempfile.mkdtemp(prefix="previous-", dir=backups)) / target.name
        target.rename(backup)
    try:
        staged.rename(target)
    except BaseException:
        if backup is not None:
            backup.rename(target)
        raise
    if backup:
        print(f"이전 앱 백업: {backup}")


if __name__ == "__main__":
    try:
        command = sys.argv[1]
        if command == "preflight":
            configuration()
        elif command == "sign":
            sign(Path(sys.argv[2]), Path(sys.argv[3]))
        elif command == "install":
            install(Path(sys.argv[2]), Path(sys.argv[3]))
        elif command == "verify-update":
            verify_update(Path(sys.argv[2]), Path(sys.argv[3]))
        else:
            raise RuntimeError("알 수 없는 서명 명령입니다.")
    except (RuntimeError, ValueError, KeyError, OSError, IndexError) as error:
        raise SystemExit(str(error))
