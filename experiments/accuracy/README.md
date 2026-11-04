# 한국어 실시간 전사 비교 재현

녹음 앱의 두 단계(말소리 구간 결정 → 로컬 모델의 확정 문장)를 함께 비교합니다. Qwen3-ASR는 비교용 프로그램에서만 실행됩니다. 앱 빌드나 녹음에 Python 또는 Qwen 가중치는 필요하지 않습니다. Core ML 모델 선택 근거는 [정확도 보고서](../../docs/STT-ACCURACY.md), GPU 실행 경로와의 비교는 [확정 지연 보고서](../../docs/STT-LATENCY.md)에 있습니다.

1. Apple Silicon Mac에서 [빌드 가이드](../../docs/BUILDING.md)에 따라 `bash scripts/build-app.sh --package-only`로 빌드합니다.
2. 평가 자료 생성에는 Python, NumPy 2.4.6, SciPy 1.17.1이 필요합니다. Qwen까지 비교하려면 `bash experiments/asr/setup-local-asr.sh qwen17`로 고정된 MLX Audio 환경과 가중치를 준비합니다. 아래의 `python`은 해당 환경의 `.runtime/asr/bin/python`을 사용해도 됩니다.
3. 저장소 루트에서 다음을 실행합니다. 한국어 공개 음성·정답 파일이 없으면 고정된 리비전에서 내려받습니다. 원본 녹음 폴더는 읽거나 수정하지 않습니다.

```sh
out=.build/accuracy-evaluation
python experiments/accuracy/prepare-fixture.py "$out"
python experiments/accuracy/check-score.py

.build/release/AccuracyBenchmark large-v3-turbo energy "$out/test.json" "$out/baseline.jsonl"
.build/release/AccuracyBenchmark large-v3 vad "$out/test.json" "$out/large.jsonl" --silence 0.6
python experiments/accuracy/score.py "$out/test.json" "$out/baseline.jsonl" "$out/large.jsonl"

.build/release/AccuracyBenchmark large-v3 vad "$out/latency.json" "$out/large-live.jsonl" --silence 0.6 --realtime
python experiments/accuracy/score.py "$out/latency.json" "$out/large-live.jsonl"
```

첫 인자는 `large-v3-metal`(whisper.cpp FP16, 3.10GB), `large-v3-turbo`(626 MB), `large-v3`(948 MB), `large-v3-turbo-fp16`(1.64 GB), 비교 전용 `qwen3-asr-1.7b` 중 하나입니다. 최종 앱은 무음에서 또는 입력보다 0.5초 넘게 밀린 미리보기를 취소하고, 함께 대기 중인 요청에서는 확정 전사를 먼저 처리합니다. 기본 앱은 Python 없이 실행되며, Qwen 실험 가중치와 런타임의 출처는 [실험 고지](../asr/ThirdPartyNotices.txt)에 있습니다. 모델 파일을 비교할 때는 [검증한 가중치 해시](model-hashes.json)를 참고하세요. 초기 다섯 모델 비교를 재현하려면 `--eager-previews`를 추가합니다(비교는 한 입력씩 순차 실행). 비교 시 한 번에 한 모델만 실행하고 매번 새 출력 경로를 사용합니다. `energy`는 이전 음량 기준과 0.8초 무음, `vad --silence 0.6`은 Silero 확률 0.5와 0.6초 무음입니다. `dev.json`은 설정 결정, `test.json`은 모델 선택, `confirm.json`은 선택 후 독립 재검증용입니다.

- 기준 음성: [Google FLEURS ko_kr](https://huggingface.co/datasets/google/fleurs/tree/70bb2e84b976b7e960aa89f1c648e09c59f894dd/data/ko_kr), CC BY 4.0. 익명 음성 ID, SHA-256, 사전에 표시한 고유명사·숫자·허용 표기와 발화 종료 추정 시각은 `cases.json`에 있습니다. Google의 문장 정답을 모델 프롬프트나 사후 교정에 넣지 않습니다. 12개 무발화 파일은 고정된 시드로 생성합니다.
- CER는 NFC 한글 음절 기준 편집 거리(삽입 + 삭제 + 치환)의 합을 전체 정답 글자 수로 나눕니다. 대소문자·공백·문장부호·기호만 정규화하고 한글 수사와 아라비아 숫자는 같게 만들지 않습니다. 고유명사는 정답 표기, 숫자는 사전에 허용한 값·단위 조합이 결과에 포함되는지 따로 셉니다. 이 값은 등장 적중률이며 잘못 추가한 고유명사의 정밀도를 뜻하지 않습니다.
- 무발화에는 5·8·12초의 디지털 정적, 합성 잡음, 60Hz 웅웅거림, 클릭음(총 100초)을 사용합니다. 확정 문장의 종결 부호를 세며, 종결 부호 없는 비어 있지 않은 발언은 한 문장입니다. 중간 미리보기는 채점하지 않습니다.
- 빠른 재생은 입력 조각마다 처리를 완료시켜 음성 인식 결과를 비교합니다. 지연 측정은 같은 파이프라인에 20ms마다 실제 속도로 음성을 보내며 재생이 끝나도 2.048초 동안 무음을 보냅니다. 모델을 미리 준비하고 첫 미리보기가 아닌 **마지막 비어 있지 않은 확정 이벤트**를 잽니다. 8개 파일의 마지막 5초 스펙트로그램을 보고 말소리의 끝을 사전에 표시했습니다(일정한 배경음·고립된 클릭 제외). 이 값은 사람의 단어별 정렬 정답이 아닌 추정값입니다. 원래 파일 경계 기준 값, EOF 이후 확정 수, 누락 수도 함께 계산합니다. 앱의 디스크 저장 시간·마이크 드라이버 지연은 포함하지 않습니다.
- 개발 12개와 모델 비교 32개는 서로 다른 문장입니다. 과거 첫 40개 문장군을 제외하고 뽑았지만, 이전의 *확장* 비교와는 각각 4개·9개가 겹칩니다. 마지막 검증 24개는 과거 확장·확인 세트 및 이번 앞선 44개와도 문장 ID가 겹치지 않습니다. 사전학습 데이터에 FLEURS가 들어갔는지는 알 수 없습니다.
