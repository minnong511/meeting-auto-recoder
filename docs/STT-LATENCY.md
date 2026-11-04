# 미팅 레코더 한국어 전사 확정 시간

Apple M5 · 메모리 16GiB · macOS 26.5.1 · 2026년 11월 4일. 같은 Whisper large-v3 계열에서 Core ML 압축 모델을 whisper.cpp의 Metal FP16 모델로 바꿨습니다. 확정 중앙값 목표는 2.46초였고 새 경로의 두 측정값은 **2.19초, 2.24초**였습니다.

| 지표 | 적용 전 | 적용 후 |
|---|---:|---:|
| 발화 종료 → 확정, 중앙값 / P95 | 이전 3.72초 / 6.44초 · 재측정 3.60초 / 6.18초 | 1회 2.19초 / 2.76초 · 2회 2.24초 / 2.71초 |
| 32문장 CER | 8.18% (138/1,688자) | 8.18% (138/1,688자) |
| 32문장 고유명사 / 숫자 적중 | 27/33 · 16/19 | 27/33 · 16/19 |
| 별도 24문장 CER | 1.50% (17/1,133자) | 1.41% (16/1,133자) |
| 별도 24문장 고유명사 / 숫자 적중 | 16/16 · 6/8 | 16/16 · 7/8 |
| 무음·합성 잡음 100초에서 만든 확정 문장 | 0개 | 0개 |
| 모델 파일 크기 | 약 0.95GB | 3.10GB |

속도를 잰 8개 음성은 32문장에 포함됩니다. 이 8개만 계산하면 기존 70/392자, 새 경로 첫 측정 71/392자, 두 번째 71/392자 오류였습니다. 기존 재측정과 최종 빌드 두 차례 모두 8개 음성의 마지막 확정 문장이 전달됐습니다. 고유명사는 지명과 기관명 등을 포함하며, 숫자는 사전에 지정한 값과 단위의 허용 표기를 기준으로 셌습니다.

## 측정 조건

이전 측정에서 고정한 한국어 낭독 음성과 정답, 무음·잡음, 발화 종료 시각을 그대로 사용했습니다. 음성을 20ms 단위로 실제 속도로 보내고, 마지막 비어 있지 않은 확정 문장이 앱 처리기에 도착한 시각에서 음성 스펙트로그램으로 미리 표시한 말소리 끝을 뺐습니다. P95는 8개 값 사이의 선형 보간입니다. 기존 경로도 이 Mac에서 다시 측정했고, 실행 파일에 GPU 코드를 내장한 최종 빌드에서 같은 8개를 두 차례 재생했습니다. 모든 지연 측정은 한 번에 한 엔진만 실행했습니다. 다운로드·모델 준비 시간과 UI·파일 저장 지연은 제외했습니다. 실제 사용자 회의와 장시간 연속 녹음에서의 정확도·지연은 측정하지 않았습니다.

말소리 감지, 0.6초 무음 대기, 시작 전 0.3초 보존, 미리보기와 확정 구분, 마이크·시스템 음성의 독립 처리 조건은 같았습니다. 한글 한 글자를 여러 토큰으로 나눴을 때도 원래 UTF-8 바이트를 합친 뒤 단어 시각을 저장합니다. GPU 컨텍스트 하나를 두 입력이 공유합니다.

새 실행 경로의 전사 프로세스 최대 메모리 사용량(footprint)은 3.44, 3.43GiB였습니다. Core ML 재측정 프로세스는 0.33GiB였고 별도 Core ML 시스템 서비스의 메모리는 이 수치에 합산되지 않습니다. 이 Mac과 같은 16GB 이상 기기에서 Metal 모델을 기본으로 선택합니다. 16GB 미만 기기의 기본값은 기존 Core ML 모델입니다. 사용자가 직접 고른 모델은 계속 사용합니다.

## 재현

저장소의 평가 지침으로 같은 자료를 준비한 뒤 아래 예처럼 한 번에 한 엔진만 실행합니다. 정확도는 같은 명령에서 `latency.json`을 `test.json` 또는 `confirm.json`으로 바꾸고 `--realtime`을 뺀 뒤 해당 파일로 채점합니다. 각 실행은 새로운 결과 경로를 사용합니다. [평가 자료와 채점 도구](https://github.com/minnong511/meeting-auto-recoder/tree/main/experiments/accuracy)

```sh
out=.build/accuracy-evaluation
.build/release/AccuracyBenchmark large-v3 vad "$out/latency.json" "$out/before-live.jsonl" --realtime
.build/release/AccuracyBenchmark large-v3-metal vad "$out/latency.json" "$out/after-live.jsonl" --realtime
python3 experiments/accuracy/score.py "$out/latency.json" "$out/before-live.jsonl" "$out/after-live.jsonl"
```

공개 음성은 Google FLEURS 한국어 시험 자료(CC BY 4.0), 기존 엔진은 Argmax 1.1.1과 947MB 변환판, 새 엔진은 whisper.cpp 1.9.2와 GGML FP16 가중치를 사용했습니다. 고정된 소스와 가중치를 각각 SHA-256으로 검증합니다. [FLEURS](https://huggingface.co/datasets/google/fleurs) · [Argmax 모델](https://huggingface.co/argmaxinc/whisperkit-coreml) · [whisper.cpp 1.9.2](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.2) · [FP16 가중치](https://huggingface.co/ggerganov/whisper.cpp/blob/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin)

앱 검사 48개, 마이크와 시스템 소리 동시 전사, 한국어 단어 재생 시각, 서명 호환성, 압축을 푼 패키지의 실행을 확인했습니다.
