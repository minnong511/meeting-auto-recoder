# 개발자 빌드와 업데이트

## 준비 사항

Metal 전사 엔진은 소스 빌드 때 한 번 컴파일합니다. CMake 3.28 이상 또는 uv가 있어야 합니다. 일반 사용자의 Mac에는 이 빌드 도구가 필요하지 않습니다.

Apple Silicon Mac, macOS 26 이상, Swift 6.2 도구 모음과 Python 3가 필요합니다. 첫 빌드에서는 Swift 패키지 의존성을 내려받으므로 인터넷이 필요합니다. 설치용 ZIP을 사용하는 사람은 이 개발 환경이 필요하지 않습니다.

아래 절차는 소스를 빌드하는 개발자를 위한 것입니다. **배포본 사용자에게는 인증서, 개인 키 또는 `signing.json`이 필요하지 않습니다.** 배포된 앱은 원래 서명 그대로 설치하며, 각 사용자가 Mac에서 녹음 권한을 허용합니다.

각 개발 Mac의 로컬 개발 인증서는 다른 Mac의 인증서와 별개입니다. 서로 다른 인증서로 만든 앱은 같은 업데이트 계열이 아니므로, 일반 사용자에게 배포할 버전은 기존 배포 서명 키를 보유한 환경에서 서명해야 합니다. 개인 키를 저장소나 배포본에 넣지 않습니다. 이 로컬 인증서는 Apple 공증용 Developer ID 인증서와 다릅니다.

이 Mac에서는 **동일한 코드 서명 인증서**를 계속 사용해야 화면·시스템 오디오·마이크 권한이 업데이트 뒤에도 연결됩니다. `codesign --sign -` 임시 서명은 실행 파일 해시로 앱을 구분하므로 업데이트 때 기존 권한과 일치하지 않을 수 있습니다.

이 Mac에 기존 개발용 앱이나 배포 서명 키가 없는 경우에만 최초 설정:

```sh
python3 scripts/setup-local-signing.py
```

이 스크립트는 로그인 키체인에 `Meeting Recorder Local Development` 인증서와 내보낼 수 없는 개인 키를 보관합니다. 개인 키 접근은 `/usr/bin/codesign`에만 미리 허용하며, 시스템 인증서 신뢰 설정을 추가하거나 변경하지 않습니다. 임시 키 파일은 가져오기가 끝나면 삭제됩니다. 공개 지문과 키체인 경로만 `~/Library/Application Support/Meeting Recorder/signing.json`에 저장합니다. 이후 실행은 같은 인증서를 재사용하며, 설정에 기록된 인증서가 사라지면 자동 재생성하지 않습니다.

**기존 빌드·배포 환경에서 설정이나 키가 사라진 경우 위 명령을 복구 수단으로 실행하지 마세요.** 기존 `signing.json`과 그 파일이 가리키는 키체인의 인증서 및 개인 키를 복구해야 합니다. `signing.json`만으로는 서명할 수 없고, 앱에 포함된 공개 인증서에서도 개인 키를 복원할 수 없습니다. 현재 개인 키는 내보낼 수 없도록 생성되므로, 백업 복구 가능 여부를 미리 확인하고 서명 환경을 보존하세요. 복구할 수 없는 경우 서명 전환과 기존 사용자 권한 재등록을 별도 계획해야 합니다.

설정과 인증서가 모두 없더라도 `dist`, `dist/package`, `/Applications`, `~/Applications`의 기본 앱 위치에서 기존 앱을 발견하면 새 인증서 생성을 차단합니다. 사용자 지정 위치나 다른 Mac의 앱까지 발견할 수는 없으므로, 기존 배포에 사용한 서명 키가 있는지 개발자가 직접 확인해야 합니다.

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

이 인증서는 로컬 개발과 비공증 배포에 사용할 수 있습니다. 다른 Mac에서는 앱별 실행 승인이 필요할 수 있으며 조직 정책에 따라 실행이 제한될 수 있습니다. Gatekeeper에서 별도 예외 승인 없이 배포하려면 Apple Developer ID 서명과 공증이 필요합니다. 인증서 또는 개인 키를 잃거나 서명 체계를 변경하면 기존 녹음 권한을 다시 허용해야 할 수 있습니다.

## 회귀 검사와 배포 ZIP

개발 중인 설치 스크립트는 `--with-ollama`로 Ollama를 선택적으로 준비합니다. 모델은 자동으로 내려받지 않으며, 원하면 `--ollama-model gemma4:e2b`처럼 기본 라이브러리 모델을 직접 지정합니다. 스크립트가 가리키는 앱 배포본은 별도 갱신해야 개발 중인 앱 변경 사항이 포함됩니다. 앱의 설정에서 내려받은 모델을 선택하며, 이미 다듬은 문단은 유지되고 이후 처리한 문단에 사용한 모델이 기록됩니다. CPU와 메모리 요구량 및 한국어 결과는 모델마다 다릅니다.

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

별도 실행 승인 없는 공증 배포에는 Apple이 발급한 Developer ID Application 인증서, 공증, 공증 티켓 스테이플링이 필요합니다. `--require-notarized` 검사는 이 조건들을 확인하며 기존 로컬 서명 앱에서는 실패하는 것이 정상입니다. 서명 주체 변경은 의도적인 마이그레이션으로 별도 진행해야 합니다.

[Apple의 Developer ID 배포 안내](https://developer.apple.com/developer-id/)

## 로컬 음성 인식

메모리 16GB 이상 Mac에서는 Whisper large-v3 FP16을 whisper.cpp의 Metal 경로로 실행합니다. 가중치 파일(약 3.10GB)은 고정 리비전에서 처음 한 번 내려받아 SHA-256으로 검사합니다. 16GB 미만 Mac은 기존 Core ML 모델(약 948MB)을 기본으로 사용합니다. Silero 말소리 감지는 두 경로가 공유합니다. 소스 첫 빌드에는 CMake 3.28 이상 또는 uv가 필요합니다. 빌드 스크립트는 체크섬으로 고정한 whisper.cpp 1.9.2 소스를 받아 arm64 Metal 코드를 실행 파일에 정적으로 연결합니다. 빌드 결과를 재사용하고 앱에는 라이선스를 포함합니다. 설치 직후 미리 준비하려면 아래 명령을 사용합니다.

```sh
'dist/Meeting Recorder.app/Contents/MacOS/MeetingRecorder' --prepare-speech
```

직접 선택한 모델은 그대로 사용합니다. 업데이트 후 권장 모델 준비에 실패하고 음성 인식 모델을 직접 선택하지 않았다면, 캐시에 있는 Core ML large-v3, Turbo 순으로 대체 모델을 선택합니다. 말소리 감지 모델을 준비하지 못하면 이전 음량 기준으로 녹음을 계속합니다. 실제 사용한 방식과 예외는 회의 메타데이터에 남깁니다. Qwen3-ASR 비교 도구의 Python 환경은 앱과 별개입니다. [평가 재현](../experiments/accuracy/README.md)
