"""Paired corpus CER/WER; no LLM text cleanup, number expansion, or tuning."""
import json
import random
import re
import sys
import unicodedata
from pathlib import Path
from rapidfuzz.distance import Levenshtein

root = Path(sys.argv[1]) if len(sys.argv)>1 else Path(".build/asr-benchmark")
manifest = json.loads((root / "manifest.json").read_text())
samples = manifest["samples"]

def normalize(text):
    text = unicodedata.normalize("NFC", text).lower()
    text = "".join(c for c in text if unicodedata.category(c)[0] not in "PS")
    return " ".join(text.split())

# Sanity checks guard against the common Korean CER errors: decomposed Hangul,
# accidentally scoring spacing as characters, and dropping a missing hypothesis.
assert normalize("가나, API!") == "가나 api"
assert Levenshtein.distance(normalize("가 나.").replace(" ", ""), normalize("가나").replace(" ", "")) == 0
assert Levenshtein.distance("가나다", "가다") == 1
assert Levenshtein.distance("가나다", "") == 3

models = {}
for name in ["whisper", "qwen06", "qwen17", "cohere", "cohere_mlx"]:
    path = root / (name + ".jsonl")
    if not path.exists():
        continue
    predictions = {r["id"]:r for r in map(json.loads, path.read_text().splitlines())}
    if len(predictions) != len(samples):
        print(name, "incomplete", len(predictions), "/", len(samples))
        continue
    details = []
    for sample in samples:
        row = predictions[sample["id"]]
        ref, hyp = normalize(sample["reference"]), normalize(row["text"])
        chars, words = ref.replace(" ", ""), ref.split()
        details.append(dict(id=sample["id"], group=sample["text_id"], ref=sample["reference"], hyp=row["text"],
                            char_errors=Levenshtein.distance(chars, hyp.replace(" ", "")), chars=len(chars),
                            word_errors=Levenshtein.distance(words, hyp.split()), words=len(words),
                            seconds=row["seconds"], duration=sample["duration"], error=row.get("error")))
    ce, cn = sum(d["char_errors"] for d in details), sum(d["chars"] for d in details)
    we, wn = sum(d["word_errors"] for d in details), sum(d["words"] for d in details)
    seconds = sum(d["seconds"] for d in details)
    # First inference can include lazy compilation; warm speed excludes first file.
    warm = sum(d["seconds"] for d in details[1:])
    models[name] = dict(files=len(details), failures=sum(d["error"] is not None for d in details),
                        empty=sum(not normalize(d["hyp"]) for d in details), cer=ce/cn, wer=we/wn,
                        char_errors=ce, reference_characters=cn, word_errors=we, reference_words=wn,
                        inference_seconds=seconds, realtime_factor=seconds/sum(d["duration"] for d in details),
                        warm_realtime_factor=warm/sum(d["duration"] for d in details[1:]), details=details)
ranked = sorted(models, key=lambda name: models[name]["cer"])
comparison = None
if len(ranked) >= 2:
    a, b = ranked[:2]
    groups = sorted({s["text_id"] for s in samples})
    def totals(name, group):
        rows = [d for d in models[name]["details"] if d["group"]==group]
        return sum(d["char_errors"] for d in rows), sum(d["chars"] for d in rows)
    aa, bb = {g:totals(a,g) for g in groups}, {g:totals(b,g) for g in groups}
    rng = random.Random(20261027)
    differences = []
    for _ in range(5000):
        draw = rng.choices(groups, k=len(groups))
        n = sum(aa[g][1] for g in draw)
        differences.append((sum(aa[g][0] for g in draw)-sum(bb[g][0] for g in draw))/n)
    differences.sort()
    comparison = dict(first=a, second=b, cer_difference=models[a]["cer"]-models[b]["cer"],
                      paired_text_cluster_bootstrap_95ci=[differences[125],differences[4874]], replicates=5000, seed=20261027)
report = dict(dataset={k:v for k,v in manifest.items() if k!="samples"}, audio_seconds=sum(s["duration"] for s in samples),
              normalization="NFC + lowercase; remove Unicode punctuation/symbols; collapse whitespace; CER excludes whitespace; WER splits whitespace; numbers retained; no LLM cleanup",
              models=models, ranking=ranked, comparison=comparison,
              limitations=["Fixed subset of public read speech, not spontaneous meetings", "Potential pretraining overlap with public benchmark is unknown", "Precision/runtime differ because these are Mac-deployable candidates", "RSS excludes separate OS/ANE services; MLX includes GPU allocations in its own peak counter"])
(root / "results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps({"audio_seconds":report["audio_seconds"],"models":{n:{k:v for k,v in r.items() if k!="details"} for n,r in models.items()},"comparison":comparison},ensure_ascii=False,indent=2))
