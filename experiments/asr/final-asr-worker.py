"""Offline-only final ASR worker. One model, sequential bounded speaker regions."""
import json
import os
import sys
from pathlib import Path

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

import numpy as np

model_path, request_path, output_path = map(Path, sys.argv[1:4])
language = sys.argv[4] if len(sys.argv)>4 else "Korean"
request = json.loads(request_path.read_text())
cohere = language == "ko"
if cohere:
    import soundfile as sf
    from mlx_speech.generation import CohereAsrModel
    model = CohereAsrModel.from_path(str(model_path))
else:
    from scipy.io import wavfile
    from mlx_audio.stt import load
    model = load(str(model_path))
audio = {}
for source, path in request["audio"].items():
    if cohere:
        samples = sf.SoundFile(path)
        if samples.samplerate != 16000 or samples.channels != 1:
            raise ValueError("Expected 16 kHz mono audio")
    else:
        rate, samples = wavfile.read(path, mmap=True)
        if rate != 16000 or samples.ndim != 1:
            raise ValueError("Expected 16 kHz mono audio")
    audio[source] = samples
result = []
for index, job in enumerate(request["jobs"]):
    samples = audio[job["source"]]
    start = max(0, round(job["start"] * 16000))
    end = min(len(samples), round(job["end"] * 16000))
    if end <= start or job["end"]-job["start"] > 24.01:
        raise ValueError("Invalid bounded audio range")
    if cohere:
        samples.seek(start)
        decoded = model.transcribe(samples.read(end-start,dtype="float32"), sample_rate=16000, language="ko", punctuation=True,itn=False,max_new_tokens=448)
    else:
        decoded = model.generate(np.asarray(samples[start:end],dtype=np.float32), language=language, max_tokens=512, temperature=0.0, verbose=False)
    result.append(dict(id=job["id"], text=decoded.text))
    print(json.dumps(dict(done=index+1,total=len(request["jobs"]))), flush=True)
# The app commits only a complete result; interrupted workers cannot replace a transcript.
temporary = output_path.with_suffix(".tmp")
temporary.write_text(json.dumps(result,ensure_ascii=False))
temporary.replace(output_path)
