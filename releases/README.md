# 배포본

- [Meeting Recorder 0.8.0 — macOS arm64 ZIP](Meeting-Recorder-0.8.0-macOS-arm64.zip)
- [설치 방법](../docs/INSTALL.md)
- [SHA-256 목록](SHA256SUMS)

ZIP 안에는 `Meeting Recorder.app`, 설치용 `README.md`, `LICENSE`, `CHANGELOG.md`, 배포 정보와 소스 파일 해시 목록이 들어 있습니다. 모델, 녹음, 개인 환경 설정, 서명 개인 키는 포함하지 않습니다.

현재 파일은 로컬 개발 인증서로 서명한 **비공증 배포본**입니다. Apple Silicon 및 macOS 26 이상에서 사용하며, 다른 Mac에서는 앱별 실행 승인이 필요할 수 있습니다. 새 Mac에서의 설치·녹음은 별도로 확인해야 합니다.

## 명령어로 설치

```sh
curl -fsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/minnong511/meeting-auto-recoder-/main/scripts/install.sh | /bin/bash
```

앱·MCP 서버 설치와 Whisper 모델 준비를 수행합니다. macOS 실행 승인과 녹음 권한 허용은 직접 해야 합니다. 옵션과 업데이트 안내는 [설치 README](../docs/INSTALL.md#터미널-명령으로-설치)에 있습니다. 기존 0.8.0 ZIP과 SHA-256은 그대로 유지하며, ZIP 안의 README는 수동 설치를 안내합니다. 최신 명령어 설치 안내는 저장소 문서를 확인하세요.

## 무결성 확인

저장소 루트에서 실행합니다.

```sh
cd releases
shasum -a 256 -c SHA256SUMS
```

파일 해시 일치는 전달 과정의 파일 변경 여부를 확인합니다. Apple 공증이나 배포자 신원 검증을 대체하지 않습니다.

## 새 배포본 만들기

`Resources/Info.plist`의 버전과 빌드 번호, 설치 안내와 변경 이력을 갱신한 뒤 실행합니다.

```sh
# 진행 중인 녹음을 마치고 앱을 종료합니다.
bash scripts/build-app.sh
.build/release/RecorderChecks
python3 scripts/package-release.py
python3 scripts/check-release.py releases/Meeting-Recorder-0.8.0-macOS-arm64.zip
```

공증 배포만 허용하는 검사에는 `python3 scripts/package-release.py --require-notarized`를 사용합니다. Developer ID 서명·Gatekeeper 승인·스테이플된 공증 티켓을 확인합니다. 현재 로컬 개발 인증서의 앱은 이 검사를 통과하지 않습니다. 이 옵션은 서명이나 공증을 대신 수행하지 않습니다.

실행 중인 앱을 유지하려면 `bash scripts/build-app.sh --package-only`로 별도 빌드한 뒤 `python3 scripts/package-release.py --app 'dist/package/Meeting Recorder.app'`로 묶습니다.

이미 만든 같은 버전의 ZIP은 기본적으로 덮어쓰지 않습니다. 아직 배포하지 않은 파일을 의도적으로 다시 만들 때만 `--replace`를 사용하세요. `releases/`의 배포 ZIP과 README, 해시 목록을 함께 커밋합니다. 설치용 앱 폴더인 `dist/`는 커밋하지 않습니다.

새 버전을 원격 저장소에 올린 다음 `scripts/install.sh`의 `version`, `release_commit`, `expected_sha`를 해당 배포본으로 갱신하고 문서의 버전 안내를 맞추세요. 다운로드 주소는 배포 커밋에 고정하므로 `main`의 파일이 바뀌어도 설치할 ZIP은 바뀌지 않습니다. 변경 후 `python3 scripts/check-installer.py`로 실제 ZIP을 이용한 설치·업데이트 검사를 실행하세요.
