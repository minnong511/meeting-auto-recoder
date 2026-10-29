"""Download immutable public test data and the exact local inference weights."""
import hashlib
import json
import tarfile
import urllib.request
from scipy.io import wavfile
from pathlib import Path

from huggingface_hub import snapshot_download

ROOT = Path(__file__).resolve().parents[2] / ".build/asr-benchmark"
REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
ROOT.mkdir(parents=True, exist_ok=True)
base = f"https://huggingface.co/datasets/google/fleurs/resolve/{REVISION}/data/ko_kr"
for remote, local in [("test.tsv", ROOT / "test.tsv"), ("audio/test.tar.gz", ROOT / "test.tar.gz")]:
    if not local.exists():
        print("Downloading", remote, flush=True)
        urllib.request.urlretrieve(f"{base}/{remote}", local)
audio = ROOT / "audio"
if not audio.exists():
    audio.mkdir()
    with tarfile.open(ROOT / "test.tar.gz") as archive:
        archive.extractall(audio, filter="data")
files = {p.name: p for p in audio.rglob("*.wav")}
rows = []
for line in (ROOT / "test.tsv").read_text().splitlines():
    c = line.split("\t")
    path = files[c[1]]
    rate, samples = wavfile.read(path)
    assert rate == 16000 and samples.ndim == 1
    duration = len(samples) / rate
    rows.append(dict(id=c[1][:-4], text_id=c[0], path=str(path), reference=c[3],
                     raw_reference=c[2], gender=c[-1], duration=duration,
                     sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
# Selection is fixed BEFORE seeing any hypotheses.
# Select whole text groups so bootstrap uncertainty can account for repeated prompts.
groups = sorted({r["text_id"] for r in rows}, key=lambda k: hashlib.sha256(("meeting-recorder-v1:"+k).encode()).hexdigest())
selected = set(groups[:40])
subset = [r for r in rows if r["text_id"] in selected]
manifest = dict(dataset="google/fleurs", config="ko_kr", split="test", revision=REVISION,
                license="CC-BY-4.0", source=f"https://huggingface.co/datasets/google/fleurs/tree/{REVISION}/data/ko_kr",
                selection="First 40 text IDs sorted by SHA256('meeting-recorder-v1:'+text_id); all recordings for each ID",
                total_test_files=len(rows), test_text_groups=len(groups), samples=subset)
(ROOT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
print("Dataset", len(subset), "files", round(sum(r["duration"] for r in subset)/60, 2), "minutes; full", len(rows), flush=True)
models = [
    ("mlx-community/Qwen3-ASR-0.6B-4bit", "313d850181767edf09f00a9c289becca70e58cd0", "qwen06", None),
    ("mlx-community/Qwen3-ASR-1.7B-4bit", "78a389c776a5483b2d0d4ea5494e11012e0d6159", "qwen17", None),
    ("FluidInference/cohere-transcribe-03-2026-coreml", "7ca8c223e84c817a7e125c567c2582559dcd8e32", "cohere",
     ["q8/cohere_encoder.mlmodelc/**", "q8/cohere_decoder_cache_external_v2.mlmodelc/**", "vocab.json", "README.md", "config.json", "metadata.json"]),
    ("appautomaton/cohere-asr-mlx", "7b94c61ed284f07c24deaeec175698a441e5076c", "cohere-canonical",
     ["mlx-int8/*", "README.md", "LICENSE"]),
]
for repo, revision, folder, patterns in models:
    print("Downloading", repo, flush=True)
    snapshot_download(repo, revision=revision, local_dir=ROOT / "models" / folder, allow_patterns=patterns, max_workers=4)
(ROOT / "model-revisions.json").write_text(json.dumps(models, indent=2))
