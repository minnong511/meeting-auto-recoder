"""Use the checkpoint author's matching runtime, with original 16 kHz samples."""
import json
import resource
import sys
import time
from pathlib import Path
import mlx.core as mx
import soundfile as sf
from mlx_speech.generation import CohereAsrModel

manifest, model_path, output_path = map(Path, sys.argv[1:4])
samples = json.loads(manifest.read_text())["samples"]
done = {json.loads(l)["id"] for l in output_path.read_text().splitlines()} if output_path.exists() else set()
start = time.monotonic()
model = CohereAsrModel.from_path(str(model_path))
print("LOAD_SECONDS",time.monotonic()-start,flush=True)
with output_path.open("a") as out:
    for i,sample in enumerate(samples):
        if sample["id"] in done: continue
        start=time.monotonic(); text="";error=None
        try:
            audio,rate=sf.read(sample["path"],dtype="float32")
            assert rate==16000 and audio.ndim==1
            result=model.transcribe(audio,sample_rate=rate,language="ko",punctuation=True,itn=False,max_new_tokens=448)
            text=result.text
            mx.synchronize()
        except Exception as exc:error=str(exc)
        row=dict(id=sample["id"],text=text,seconds=time.monotonic()-start,duration=sample["duration"],error=error)
        out.write(json.dumps(row,ensure_ascii=False)+"\n");out.flush()
        print(f"cohere-mlx {i+1}/{len(samples)} {row['seconds']:.2f}s {error or 'OK'}",flush=True)
print("MAX_RSS_BYTES",resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,"MLX_PEAK_BYTES",mx.get_peak_memory(),flush=True)
