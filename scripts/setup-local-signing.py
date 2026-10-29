#!/usr/bin/env python3
"""Create once, then reuse a private local code-signing identity in Keychain."""
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile

LABEL = "Meeting Recorder Local Development"
CONFIG = Path.home() / "Library/Application Support/Meeting Recorder/signing.json"


def run(*args, check=True):
    result = subprocess.run(args, capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or "명령을 실행하지 못했습니다.")
    return result


def main():
    os.umask(0o077)
    keychain = run("/usr/bin/security", "default-keychain", "-d", "user").stdout.strip().strip('"')
    if not Path(keychain).is_file():
        raise RuntimeError("로그인 키체인을 찾을 수 없습니다.")
    existing = run("/usr/bin/security", "find-certificate", "-a", "-c", LABEL, "-p", keychain, check=False)
    certificates = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", existing.stdout, re.S)
    if len(certificates) > 1:
        raise RuntimeError("같은 이름의 인증서가 여러 개입니다. 기존 인증서를 삭제하거나 새로 만들지 말고 먼저 확인하세요.")
    with tempfile.TemporaryDirectory(prefix="meeting-recorder-signing-") as temporary:
        directory = Path(temporary)
        certificate = directory / "certificate.pem"
        if certificates:
            certificate.write_text(certificates[0] + "\n")
        else:
            if CONFIG.exists():
                raise RuntimeError("저장된 인증서가 키체인에 없습니다. 새 인증서를 생성하면 권한 연결이 바뀌므로 중단합니다.")
            key = directory / "private-key.pem"
            extensions = directory / "openssl.cnf"
            extensions.write_text("""[req]
distinguished_name = subject
x509_extensions = code_signing
prompt = no
[subject]
CN = Meeting Recorder Local Development
[code_signing]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
""")
            run("/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-nodes",
                "-sha256", "-days", "3650", "-config", str(extensions), "-keyout", str(key), "-out", str(certificate))
            identity = directory / "identity.p12"
            transfer_password = secrets.token_hex(24)
            password_file = directory / "transfer-password"
            password_file.write_text(transfer_password)
            run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(certificate),
                "-name", LABEL, "-out", str(identity), "-passout", "file:" + str(password_file))
            # The PKCS#12 uses a random, temporary transfer password, not a user password.
            # Imported private keys are non-extractable and only codesign is pre-authorized.
            run("/usr/bin/security", "import", str(identity), "-k", keychain, "-f", "pkcs12",
                "-P", transfer_password, "-x", "-T", "/usr/bin/codesign")
        fingerprint = run("/usr/bin/openssl", "x509", "-in", str(certificate), "-noout", "-fingerprint", "-sha1").stdout
        fingerprint = fingerprint.split("=", 1)[1].strip().replace(":", "").upper()
        if not re.fullmatch(r"[A-F0-9]{40}", fingerprint):
            raise RuntimeError("인증서 지문을 읽을 수 없습니다.")
        if CONFIG.exists() and json.loads(CONFIG.read_text())["identity"] != fingerprint:
            raise RuntimeError("기존에 고정한 인증서와 다릅니다. 자동으로 교체하지 않습니다.")
        # Prove the identity can sign before changing the app or its build config.
        probe = directory / "signing-probe"
        probe.write_bytes(Path("/usr/bin/true").read_bytes())
        result = run("/usr/bin/codesign", "--force", "--sign", fingerprint, "--keychain", keychain,
                     "--timestamp=none", "--identifier", "dev.meetingrecorder.signing-probe", str(probe), check=False)
        if result.returncode:
            raise RuntimeError("인증서는 키체인에 보관했지만 서명 확인이 실패했습니다. 인증서를 재생성하지 마세요.\n" + result.stderr)
        run("/usr/bin/codesign", "--verify", "--strict", str(probe))
        CONFIG.parent.mkdir(parents=True, exist_ok=True)
        config_next = CONFIG.with_suffix(".next")
        config_next.write_text(json.dumps({"identity": fingerprint, "keychain": keychain, "label": LABEL}, indent=2) + "\n")
        config_next.replace(CONFIG)
        print("로컬 서명 인증서 준비 완료. 개인 키는 키체인에만 보관됩니다.")
        print(f"설정: {CONFIG}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        raise SystemExit(str(error))
