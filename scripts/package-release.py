#!/usr/bin/env python3
"""Package the already-built, signed app without changing its signing identity."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, check=True):
    return subprocess.run(args, text=True, capture_output=True, check=check)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "dist/Meeting Recorder.app")
    parser.add_argument("--output", type=Path, default=ROOT / "releases")
    parser.add_argument("--replace", action="store_true", help="Replace an unpublished archive of the same version")
    parser.add_argument("--require-notarized", action="store_true", help="Require Developer ID, Gatekeeper acceptance and a stapled ticket")
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version):
        raise RuntimeError("배포 버전 형식이 올바르지 않습니다.")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    executables = [app / "Contents/MacOS" / name for name in ("MeetingRecorder", "MeetingRecorderMCP")]
    for executable in executables:
        run("/usr/bin/codesign", "--verify", "--strict", str(executable))
        if run("/usr/bin/lipo", "-archs", str(executable)).stdout.strip() != "arm64":
            raise RuntimeError("현재 설치 안내와 배포 검사는 arm64 실행 파일만 지원합니다.")
    signature = run("/usr/bin/codesign", "-dv", "--verbose=2", str(app)).stderr
    developer_id = "Authority=Developer ID Application:" in signature
    assessment = run("/usr/sbin/spctl", "--assess", "--type", "execute", str(app), check=False)
    stapled = False
    if developer_id:
        stapled = run("/usr/bin/xcrun", "stapler", "validate", str(app), check=False).returncode == 0
    notarized = developer_id and assessment.returncode == 0 and stapled
    if args.require_notarized and not notarized:
        raise RuntimeError("공개 배포 검사 실패: Developer ID 서명, Gatekeeper 승인, 스테이플된 공증 티켓이 필요합니다. 현재 앱을 재서명하거나 보안 검사를 우회하지 않았습니다.")

    name = f"Meeting-Recorder-{version}-macOS-arm64"
    args.output.mkdir(parents=True, exist_ok=True)
    destination = args.output / (name + ".zip")
    if destination.exists() and not args.replace:
        raise RuntimeError("같은 버전의 배포본이 있습니다. 버전을 올리거나 미배포 파일에만 --replace를 사용하세요.")
    with tempfile.TemporaryDirectory(prefix="meeting-recorder-release-") as temporary:
        temporary = Path(temporary)
        bundle = temporary / name
        bundle.mkdir()
        run("/usr/bin/ditto", "--norsrc", str(app), str(bundle / app.name))
        for source, target in [("docs/INSTALL.md", "README.md"), ("LICENSE", "LICENSE"), ("CHANGELOG.md", "CHANGELOG.md")]:
            shutil.copyfile(ROOT / source, bundle / target)
        if f"**{version}**" not in (bundle / "README.md").read_text():
            raise RuntimeError("설치 README의 버전이 앱 버전과 다릅니다.")
        sources = [ROOT / "Package.swift", ROOT / "Package.resolved"]
        for folder in ("Sources", "Resources"):
            sources.extend(p for p in (ROOT / folder).rglob("*") if p.is_file() and not p.name.startswith("."))
        lines = [hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.relative_to(ROOT).as_posix() for p in sorted(sources)]
        manifest = "\n".join(lines) + "\n"
        (bundle / "source-files.sha256").write_text(manifest)
        metadata = dict(version=version, build=info["CFBundleVersion"], architecture="arm64",
                        minimum_macos=info["LSMinimumSystemVersion"],
                        signing="developer-id" if developer_id else "local-development",
                        notarized_and_stapled=notarized,
                        gatekeeper_accepted=assessment.returncode == 0,
                        source_manifest_sha256=hashlib.sha256(manifest.encode()).hexdigest())
        (bundle / "release-info.json").write_text(json.dumps(metadata, indent=2) + "\n")
        archive = temporary / destination.name
        run("/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent", str(bundle), str(archive))
        shutil.copyfile(archive, destination)
    sums = []
    for archive in sorted(args.output.glob("Meeting-Recorder-*.zip")):
        sums.append(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name)
    (args.output / "SHA256SUMS").write_text("\n".join(sums) + "\n")
    print(destination)
    print("Apple 공증 완료" if notarized else "로컬 개발 서명 · Apple 비공증 배포본")


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
