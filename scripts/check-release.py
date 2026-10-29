#!/usr/bin/env python3
"""Verify archive contents, hashes, extracted signatures and live-only startup."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import stat
import subprocess
import tempfile
import zipfile


def verify(archive):
    archive = archive.resolve()
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    expected = dict((line.split(None, 1)[1].strip(), line.split(None, 1)[0])
                    for line in (archive.parent / "SHA256SUMS").read_text().splitlines() if line.strip())
    if expected.get(archive.name) != digest:
        raise ValueError("배포 ZIP의 SHA-256이 일치하지 않습니다.")
    forbidden = {"Recordings", ".audio-parts", ".runtime", ".build", ".git", ".DS_Store", "LocalASR.json", "final-asr-worker.py"}
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        if sum(item.file_size for item in entries) > 256 * 1024 * 1024:
            raise ValueError("배포본의 압축 해제 크기가 검사 한도를 넘습니다.")
        roots = set()
        for item in entries:
            path = PurePosixPath(item.filename)
            if path.is_absolute() or ".." in path.parts or not path.parts:
                raise ValueError("안전하지 않은 ZIP 경로입니다.")
            roots.add(path.parts[0])
            if forbidden.intersection(path.parts) or path.suffix.lower() in {".p12", ".pfx", ".key", ".pem", ".m4a", ".wav"}:
                raise ValueError("배포본에 제외해야 하는 파일이 있습니다: " + item.filename)
            if stat.S_ISLNK(item.external_attr >> 16):
                raise ValueError("이 배포 형식은 심볼릭 링크를 허용하지 않습니다.")
        if len(roots) != 1:
            raise ValueError("ZIP 최상위 폴더는 하나여야 합니다.")
        root = next(iter(roots))
        allowed = {"Meeting Recorder.app", "README.md", "LICENSE", "CHANGELOG.md", "release-info.json", "source-files.sha256"}
        for item in entries:
            parts = PurePosixPath(item.filename).parts
            if len(parts) > 1 and parts[1] not in allowed:
                raise ValueError("알 수 없는 배포 파일입니다: " + item.filename)

    with tempfile.TemporaryDirectory(prefix="meeting-recorder-release-check-") as temporary:
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), temporary], check=True)
        bundle = Path(temporary) / root
        for name in allowed:
            if not (bundle / name).exists():
                raise ValueError("필수 배포 파일이 없습니다: " + name)
        app = bundle / "Meeting Recorder.app"
        metadata = json.loads((bundle / "release-info.json").read_text())
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if metadata["version"] != info["CFBundleShortVersionString"] or metadata["build"] != info["CFBundleVersion"]:
            raise ValueError("배포 정보와 앱 버전이 다릅니다.")
        if root != f"Meeting-Recorder-{metadata['version']}-macOS-arm64":
            raise ValueError("배포 폴더 이름과 버전이 다릅니다.")
        manifest = (bundle / "source-files.sha256").read_bytes()
        if hashlib.sha256(manifest).hexdigest() != metadata["source_manifest_sha256"]:
            raise ValueError("소스 파일 해시 목록이 변경되었습니다.")
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        for name in ("MeetingRecorder", "MeetingRecorderMCP"):
            executable = app / "Contents/MacOS" / name
            if not os.access(executable, os.X_OK):
                raise ValueError("실행 권한이 보존되지 않았습니다: " + name)
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(executable)], check=True)
            architecture = subprocess.check_output(["/usr/bin/lipo", "-archs", str(executable)], text=True).strip()
            if architecture != "arm64":
                raise ValueError("실행 파일 아키텍처가 다릅니다.")
        result = subprocess.run([str(app / "Contents/MacOS/MeetingRecorder"), "--diagnose"], text=True, capture_output=True, check=True, timeout=30)
        diagnostic = json.loads(result.stdout)
        if diagnostic.get("transcriptionMode") != "live-only" or diagnostic.get("postProcessingEnabled") is not False:
            raise ValueError("배포 앱이 실시간 전사 전용으로 설정되지 않았습니다.")
        report = dict(version=metadata["version"], sha256=digest,
                      extracted_bytes=sum(item.file_size for item in entries),
                      notarized_and_stapled=metadata["notarized_and_stapled"],
                      verified=["archive hash", "allowlisted contents", "source manifest", "app and MCP signatures", "arm64", "executable permissions", "extracted live-only startup"])
        print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    verify(args.archive)
