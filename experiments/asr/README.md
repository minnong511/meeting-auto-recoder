# 과거 ASR 비교 실험

이 폴더는 이전 음성인식 모델 비교를 재현하기 위한 자료입니다. **0.8.0 앱의 실행·빌드·설치에 Python 런타임이나 이 모델들은 필요하지 않습니다.**

- `ASRSelection.json`: 당시 선택한 Qwen 모델, 고정 리비전, 낭독 음성 평가 범위
- `final-asr-worker.py`: 앱에서 제거한 종료 후 재인식 워커의 보관본
- `prepare-asr-benchmark.py`, `score-asr-benchmark.py`: FLEURS 데이터 준비와 평가
- `benchmark-qwen.py`, `benchmark-cohere-mlx.py`: 모델별 로컬 실험 실행
- `setup-local-asr.sh`, `*.lock.txt`: 선택적인 실험 환경 준비
- `ASRBenchmark/main.swift`: WhisperKit/FluidAudio 비교용 Swift 실행 대상
- `ThirdPartyNotices.txt`: 당시 사용한 별도 실험 런타임과 모델의 출처

실험 데이터는 `.build/asr-benchmark/`, Python 환경과 가중치는 `.runtime/`에 저장하며 Git에 넣지 않습니다. 준비 스크립트는 대용량 공개 데이터와 모델을 다운로드할 수 있습니다. 실험이 필요한 경우에만 별도로 실행하세요.

```sh
# 저장소 루트에서 선택적으로 실행
bash experiments/asr/setup-local-asr.sh qwen17
# 또는 cohere
```

기록된 CER/WER는 고정된 공개 낭독 음성 부분집합의 결과입니다. 자연스러운 한국어 회의나 동시 발화에서의 우수성을 입증하지 않습니다. 실험 모델과 SDK의 라이선스는 각 배포처를 확인하세요.
