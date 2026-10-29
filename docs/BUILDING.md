# 개발자 빌드와 업데이트

## 준비 사항

Apple Silicon Mac, macOS 26 이상, Swift 6.2 도구 모음과 Python 3가 필요합니다. 첫 빌드에서는 Swift 패키지 의존성을 내려받으므로 인터넷이 필요합니다. 설치용 ZIP을 사용하는 사람은 이 개발 환경이 필요하지 않습니다.

아래 절차는 각 Mac의 로컬 개발 인증서를 만듭니다. 배포자의 개인 키를 복사하거나 저장소에 넣지 않습니다. 이 로컬 인증서는 Apple 공증용 Developer ID 인증서와 다릅니다.

이 Mac에서는 **동일한 코드 서명 인증서**를 계속 사용해야 화면·시스템 오디오·마이크 권한이 업데이트 뒤에도 연결됩니다. `codesign --sign -` 임시 서명은 실행 파일 해시로 앱을 구분하므로 업데이트 때 기존 권한과 일치하지 않을 수 있습니다.

최초 한 번:

```sh
python3 scripts/setup-local-signing.py
```

이 스크립트는 로그인 키체인에 `Meeting Recorder Local Development` 인증서와 내보낼 수 없는 개인 키를 보관합니다. 개인 키 접근은 `/usr/bin/codesign`에만 미리 허용하며, 시스템 인증서 신뢰 설정을 추가하거나 변경하지 않습니다. 임시 키 파일은 가져오기가 끝나면 삭제됩니다. 공개 지문과 키체인 경로만 `~/Library/Application Support/Meeting Recorder/signing.json`에 저장합니다. 이후 실행은 같은 인증서를 재사용하며, 설정에 기록된 인증서가 사라지면 자동 재생성하지 않습니다.

이전에 임시 서명으로 설치한 앱을 처음 전환할 때만:

```sh
RECORDER_ALLOW_SIGNING_MIGRATION=1 bash scripts/build-app.sh
```

이 전환 직후 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 이전 Meeting Recorder 항목을 제거하고 `dist/Meeting Recorder.app`을 다시 추가해야 합니다. 이전 서명에 마이크 권한을 부여했다면 마이크 권한도 한 번 다시 허용해야 합니다. 단순히 기존 스위치를 껐다 켜는 것으로는 서명 연결이 갱신되지 않을 수 있습니다.

이후 업데이트:

```sh
# 녹음을 마무리하고 앱을 종료한 뒤 실행합니다.
bash scripts/build-app.sh
open 'dist/Meeting Recorder.app'
```

- 인증서가 없으면 임시 서명으로 대체하지 않고 중단합니다.
- 앱과 MCP 실행 파일을 같은 인증서로 서명합니다.
- 새 앱은 별도 폴더에서 완성하고 서명을 검증합니다. 인증서와 앱 식별자에 기반한 기존·신규 서명 조건이 서로 호환되어야 업데이트를 허용합니다.
- 실행 중인 앱의 교체는 차단합니다. 교체 직전 앱은 `.build/app-backups/`에 보관하고 설치 실패 시 되돌립니다. 기존 MCP 프로세스는 이전 실행 파일을 계속 사용할 수 있습니다.
- 앱을 수동으로 다시 서명하거나 인증서를 매번 새로 만들지 마세요. 앱 식별자만 검사하는 느슨한 서명 조건도 사용하지 않습니다.

검사:

```sh
python3 scripts/check-signing.py
```

다른 버전끼리의 서명 호환성, 인증서 누락 시 중단, 다른 서명 차단, 실행 중 교체 방지, 설치 실패 복구, 파일 변조 탐지를 검사합니다. 실제 시스템 오디오 녹음 여부는 앱의 설정 및 연결 → 15초 테스트로 확인합니다.

이 인증서는 이 Mac에서 개발·개인 사용을 위한 것입니다. 다른 Mac에 공개 배포하려면 Apple Developer ID 서명과 공증을 별도로 준비해야 합니다. 인증서 또는 개인 키를 잃거나 서명 체계를 변경하면 기존 녹음 권한을 다시 허용해야 할 수 있습니다.

## 회귀 검사와 배포 ZIP

```sh
bash scripts/build-app.sh
.build/release/RecorderChecks
python3 scripts/check-signing.py
python3 scripts/package-release.py
python3 scripts/check-release.py releases/Meeting-Recorder-0.8.0-macOS-arm64.zip
```

`package-release.py`는 이미 빌드한 앱을 검증하고 ZIP으로 묶습니다. 앱을 다시 서명하거나 설치하지 않습니다. `check-release.py`는 ZIP을 별도 임시 폴더에 풀어 파일 목록·SHA-256·실행 권한·앱/MCP 서명과 시작 진단을 확인합니다. 새로운 Mac의 시스템 오디오 권한과 실제 녹음까지 검증하는 절차는 아니므로 대상 Mac에서도 테스트해야 합니다.

녹음 중인 기존 앱을 교체하지 않고 배포본만 만들 때는 다음을 사용합니다. 결과는 별도 `dist/package/`에 저장되며 기존 앱의 실행 파일을 교체하지 않습니다.

```sh
bash scripts/build-app.sh --package-only
python3 scripts/package-release.py --app 'dist/package/Meeting Recorder.app'
```

공개 배포를 준비할 때는 Apple이 발급한 Developer ID Application 인증서, 공증, 공증 티켓 스테이플링이 필요합니다. `--require-notarized` 검사는 이 조건들을 확인하며 기존 로컬 서명 앱에서는 실패하는 것이 정상입니다. 서명 주체 변경은 의도적인 마이그레이션으로 별도 진행해야 합니다.

[Apple의 Developer ID 배포 안내](https://developer.apple.com/developer-id/)
