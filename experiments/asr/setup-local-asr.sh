#!/bin/bash
set -euo pipefail
RECORDER_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$RECORDER_ROOT"
export UV_CACHE_DIR="$RECORDER_ROOT/.runtime/uv-cache"
export UV_PYTHON_INSTALL_DIR="$RECORDER_ROOT/.runtime/python"
export HF_HUB_DISABLE_XET=1
mkdir -p .runtime
command -v uv >/dev/null || { echo 'uv가 필요합니다: https://docs.astral.sh/uv/getting-started/installation/' >&2; exit 1; }
RECORDER_ENGINE="${1:-$(python3 -c 'import json; print(json.load(open("experiments/asr/ASRSelection.json"))["engine"])')}"
case "$RECORDER_ENGINE" in
  cohere)
    RECORDER_RUNTIME="$RECORDER_ROOT/.runtime/cohere"
    if [ ! -x "$RECORDER_RUNTIME/bin/python" ]; then uv venv --python 3.14 "$RECORDER_RUNTIME"; fi
    uv pip install --python "$RECORDER_RUNTIME/bin/python" --constraint experiments/asr/cohere-runtime-requirements.lock.txt mlx-speech==0.5.4
    ;;
  qwen17)
    RECORDER_RUNTIME="$RECORDER_ROOT/.runtime/asr"
    if [ ! -x "$RECORDER_RUNTIME/bin/python" ]; then uv venv --python 3.11 "$RECORDER_RUNTIME"; fi
    uv pip install --python "$RECORDER_RUNTIME/bin/python" --constraint experiments/asr/asr-benchmark-requirements.lock.txt mlx-audio==0.6.2
    ;;
  whisper) echo 'Whisper uses the existing native model cache.'; exit 0 ;;
  *) echo 'Unknown experimental ASR engine' >&2; exit 1 ;;
esac
RECORDER_WORKSPACE="$RECORDER_ROOT" RECORDER_ASR_ENGINE="$RECORDER_ENGINE" HF_HOME="$RECORDER_ROOT/.runtime/hf" "$RECORDER_RUNTIME/bin/python" - <<'PY'
import json,os,shutil,subprocess
from pathlib import Path
from huggingface_hub import snapshot_download
root=Path(os.environ['RECORDER_WORKSPACE'])
engine=os.environ['RECORDER_ASR_ENGINE']
if engine=='selected': engine=json.loads((root/'experiments/asr/ASRSelection.json').read_text())['engine']
if engine=='whisper':
    print('Whisper uses the existing native model cache.'); raise SystemExit(0)
if engine=='cohere':
    repo='appautomaton/cohere-asr-mlx'
    revision='7b94c61ed284f07c24deaeec175698a441e5076c'
    source=root/'.build/asr-benchmark/models/cohere-canonical/mlx-int8'
    evidence=root/'.build/asr-benchmark/cohere-canonical-revision.txt'
    can_copy=evidence.exists() and evidence.read_text()==revision
elif engine=='qwen17':
    repo='mlx-community/Qwen3-ASR-1.7B-4bit'
    revision='78a389c776a5483b2d0d4ea5494e11012e0d6159'
    source=root/'.build/asr-benchmark/models/qwen17'
    provenance=root/'.build/asr-benchmark/model-revisions.json'
    recorded=json.loads(provenance.read_text()) if provenance.exists() else []
    can_copy=any(m[1]==revision for m in recorded)
else: raise ValueError('Unsupported experimental ASR engine: '+engine)
target=root/'.runtime/models'/engine
marker=target/'.ready-revision'
if not marker.exists() or marker.read_text()!=revision:
    if source.exists() and can_copy:
        for path in source.rglob('*'):
            if not path.is_file() or '.cache' in path.parts: continue
            dest=target/path.relative_to(source); dest.parent.mkdir(parents=True,exist_ok=True)
            # APFS clone when available; no extra full copy of 1.6 GB weights.
            if subprocess.run(['/bin/cp','-c',str(path),str(dest)],capture_output=True).returncode:
                shutil.copy2(path,dest)
        if engine=='cohere' and (source.parent/'README.md').exists():
            shutil.copy2(source.parent/'README.md',target/'Model-README.md')
    else:
        if engine=='cohere':
            download=target/'.download'
            snapshot_download(repo,revision=revision,local_dir=download,allow_patterns=['mlx-int8/*','README.md','LICENSE'],max_workers=4)
            for path in (download/'mlx-int8').iterdir():
                shutil.move(str(path),str(target/path.name))
            for name in ['README.md','LICENSE']:
                if (download/name).exists(): shutil.copy2(download/name,target/('Model-'+name))
            shutil.rmtree(download)
        else:
            snapshot_download(repo,revision=revision,local_dir=target,max_workers=4)
    marker.write_text(revision)
print('Local ASR runtime ready:',target)
PY
