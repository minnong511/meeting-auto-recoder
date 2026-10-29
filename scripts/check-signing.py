#!/usr/bin/env python3
"""Exercise real macOS signatures with different app versions and tampering."""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("app_signing", Path(__file__).with_name("app-signing.py"))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


def fixture(directory, version):
    app = directory / f"Version{version}.app"
    binaries = app / "Contents/MacOS"
    binaries.mkdir(parents=True)
    for name in ("MeetingRecorder", "MeetingRecorderMCP"):
        shutil.copyfile("/usr/bin/true", binaries / name)
        (binaries / name).chmod(0o755)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "MeetingRecorder", "CFBundleIdentifier": "dev.meetingrecorder.prototype",
        "CFBundleName": "Meeting Recorder", "CFBundlePackageType": "APPL", "CFBundleVersion": str(version),
    }))
    return app


def expect_failure(action):
    try:
        action()
    except RuntimeError:
        return
    raise AssertionError("위험한 업데이트가 차단되지 않았습니다.")


with tempfile.TemporaryDirectory(prefix="recorder-signing-check-") as temporary:
    directory = Path(temporary)
    with patch.object(signing, "CONFIG", directory / "missing.json"):
        expect_failure(signing.configuration)
    print("PASS: missing identity refuses ad-hoc fallback")
    old, new = fixture(directory, 1), fixture(directory, 2)
    with patch.dict(os.environ, {"RECORDER_ALLOW_SIGNING_MIGRATION": "0"}):
        signing.sign(old, directory / "absent.app")
        signing.sign(new, old)
        assert signing.requirement(old) == signing.requirement(new)
        old_hash = signing.run("/usr/bin/codesign", "-d", "--verbose=4", str(old)).stderr
        new_hash = signing.run("/usr/bin/codesign", "-d", "--verbose=4", str(new)).stderr
        assert next(x for x in old_hash.splitlines() if x.startswith("CDHash=")) != next(x for x in new_hash.splitlines() if x.startswith("CDHash="))
        print("PASS: changed app hash preserves certificate-bound identity in both directions")
        foreign = fixture(directory, 3)
        signing.run("/usr/bin/codesign", "--force", "--sign", "-", str(foreign))
        expect_failure(lambda: signing.verify_update(old, foreign))
        print("PASS: same bundle ID with foreign signature is rejected")
        with patch.object(signing, "run", return_value=subprocess.CompletedProcess([], 0, "123\n", "")):
            expect_failure(lambda: signing.install(new, old))
        assert old.exists() and new.exists()
        print("PASS: running app blocks replacement and preserves both bundles")
        with patch.object(Path, "rename", side_effect=[None, OSError("simulated installation failure"), None]) as rename:
            try:
                signing.install(new, old)
            except OSError:
                pass
            else:
                raise AssertionError("Expected simulated failure")
            assert rename.call_count == 3
        print("PASS: installation failure restores previous app")
        info = new / "Contents/Info.plist"
        data = plistlib.loads(info.read_bytes())
        data["CFBundleVersion"] = "tampered"
        info.write_bytes(plistlib.dumps(data))
        assert signing.run("/usr/bin/codesign", "--verify", "--strict", str(new), check=False).returncode != 0
        print("PASS: modified app fails signature verification")
