# 로컬 문장 다듬기 성능 측정

같은 `qwen3.5:4b` 모델·지시문·합성 한국어 입력으로 기존 CPU 실행과 자동 GPU 선택을 비교합니다. 녹음 파일이나 사용자 회의 기록은 읽거나 수정하지 않습니다. 인터넷에 입력을 보내지 않으며 모델을 자동 다운로드하지 않습니다.

실측 결과와 해석 범위: [성능 보고서](../../docs/PERFORMANCE.md). 수치 원본: [2026-11-04 M5](results/2026-11-04-m5.json).

## 준비

- Ollama 앱과 `qwen3.5:4b` 모델이 이미 설치된 Mac.
- 시스템 Python 3. 별도 패키지는 필요하지 않습니다.
- 두 방식을 **순차적으로** 실행하세요. 다른 모델 실행이나 빌드를 동시에 진행하면 비교에 영향을 줍니다.

## 엔진 반복 비교

```sh
python3 experiments/polishing/benchmark.py --rounds 3 --output .build/polishing-benchmark
```

6문단 × 3회 × 2방식으로 측정합니다. 라운드별 순서를 CPU→GPU, GPU→CPU로 바꾸고 매 배치마다 프로세스를 다시 실행합니다. 실제 앱의 지시문과 동일한 요청을 사용하며 첫 요청도 통계에 포함합니다. 결과 파일에는 문단별 응답 시간, 토큰 수, 생성 처리량, 응답 텍스트, 지정 표현 포함 여부가 들어갑니다. 서버 시작 시간과 CPU 누적 시간, 200ms 간격으로 관찰한 최대 RSS도 기록합니다.

`--mode cpu` 또는 `--mode metal`, `--cases 1`로 실행 범위를 줄일 수 있습니다. `metal`은 엔진의 자동 장치 선택 설정을 뜻하며 GPU 사용을 강제하는 이름은 아닙니다. 다른 기기에서는 GPU 인식 여부도 확인하세요.

```sh
/Applications/Ollama.app/Contents/Resources/llama-server --list-devices
```

## 실제 앱 실행 경로 확인

기존 서명을 유지한 별도 시험용 앱을 만든 후, GUI와 같은 `LocalTranscriptPolisher`를 호출합니다.

```sh
bash scripts/build-app.sh --package-only
"dist/package/Meeting Recorder.app/Contents/MacOS/MeetingRecorder" \
  --benchmark-polishing experiments/polishing/cases.json \
  --polish-compute automatic > .build/polishing-app-auto.json
"dist/package/Meeting Recorder.app/Contents/MacOS/MeetingRecorder" \
  --benchmark-polishing experiments/polishing/cases.json \
  --polish-compute cpu > .build/polishing-app-cpu.json
```

`--polish-model`로 설치된 다른 모델을 지정할 수 있습니다. 결과의 `startupMode`는 성공한 시작 설정입니다. `automatic`에서 `cpu`로 바뀌면 첫 시작이 실패해 CPU로 재시도한 것입니다. 이 필드는 실제 GPU 사용량 측정값은 아닙니다.

## 실패·취소 검사

```sh
python3 experiments/polishing/check-lifecycle.py
```

실제 워커 소스와 작은 Swift 검사 실행 파일을 임시 폴더에서 컴파일합니다. 로컬 가짜 서버로 초기화 실패→CPU 재시도, 이전 프로세스 종료, 재시도 상한, 취소 시 재시도 금지, 종료 후 요청 거부, 잘린 응답 거부를 검사합니다. 실제 모델은 필요하지 않습니다.

표현 포함 검사는 완전한 문장 정확도 평가가 아닙니다. 원문과 결과를 직접 비교하고, 음성인식 CER/WER나 배터리 수치와 구분해서 해석하세요.
