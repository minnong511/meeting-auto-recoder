import json
import resource
import sys
import time
from pathlib import Path
import mlx.core as mx
from mlx_audio.stt import load

manifest_path, model_path, output_path = map(Path, sys.argv[1:4])
language = sys.argv[4] if len(sys.argv)>4 else "Korean"
samples = json.loads(manifest_path.read_text())["samples"]
done = {json.loads(l)["id"] for l in output_path.read_text().splitlines()} if output_path.exists() else set()
start = time.monotonic()
model = load(str(model_path))
print("LOAD_SECONDS", time.monotonic()-start, flush=True)
with output_path.open("a") as output:
    for i, sample in enumerate(samples):
        if sample["id"] in done:
            continue
        start = time.monotonic()
        error, text = None, ""
        try:
            result = model.generate(sample["path"], language=language, max_tokens=512, temperature=0.0, verbose=False)
            text = result.text
            mx.synchronize()
        except Exception as exc:
            error = str(exc)
        row = dict(id=sample["id"], text=text, seconds=time.monotonic()-start, duration=sample["duration"], error=error)
        output.write(json.dumps(row, ensure_ascii=False)+"\n")
        output.flush()
        print(f"{model_path.name} {i+1}/{len(samples)} {row['seconds']:.2f}s {error or 'OK'}", flush=True)
print("MAX_RSS_BYTES", resource.getrusage(resource.RUSAGE_SELF).ru_maxrss, "MLX_PEAK_BYTES", mx.get_peak_memory(), flush=True)
