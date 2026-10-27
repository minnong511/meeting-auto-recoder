#!/bin/bash
set -euo pipefail
RECORDER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RECORDER_ROOT"
mkdir -p .build/cache .build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$RECORDER_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$RECORDER_ROOT/.build/ModuleCache"
swift build --configuration release --disable-sandbox --cache-path "$RECORDER_ROOT/.build/cache"
RECORDER_BIN="$(swift build --configuration release --show-bin-path --disable-sandbox --cache-path "$RECORDER_ROOT/.build/cache")"
RECORDER_APP="$RECORDER_ROOT/dist/Meeting Recorder.app"
mkdir -p "$RECORDER_APP/Contents/MacOS"
cp "$RECORDER_BIN/MeetingRecorder" "$RECORDER_APP/Contents/MacOS/MeetingRecorder"
# Sign a separate file, then replace the executable atomically. Existing MCP
# clients keep using the old inode until their sessions end.
RECORDER_MCP_STAGED="$RECORDER_APP/Contents/MacOS/.MeetingRecorderMCP.next"
cp "$RECORDER_BIN/MeetingRecorderMCP" "$RECORDER_MCP_STAGED"
codesign --force --sign - --options runtime "$RECORDER_MCP_STAGED"
mv -f "$RECORDER_MCP_STAGED" "$RECORDER_APP/Contents/MacOS/MeetingRecorderMCP"
cp Resources/Info.plist "$RECORDER_APP/Contents/Info.plist"
mkdir -p "$RECORDER_APP/Contents/Resources"
cp -f .build/checkouts/FluidAudio/LICENSE "$RECORDER_APP/Contents/Resources/FluidAudio-LICENSE.txt"
cp -f .build/checkouts/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md "$RECORDER_APP/Contents/Resources/fastcluster-LICENSE.txt"
cp -f .build/checkouts/FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md "$RECORDER_APP/Contents/Resources/VBx-LICENSE.txt"
cp Resources/ThirdPartyNotices.txt "$RECORDER_APP/Contents/Resources/ThirdPartyNotices.txt"
cp -f .build/checkouts/argmax-oss-swift/LICENSE "$RECORDER_APP/Contents/Resources/WhisperKit-LICENSE.txt"
cp -f .build/checkouts/argmax-oss-swift/NOTICES "$RECORDER_APP/Contents/Resources/WhisperKit-NOTICES.txt"
cp -f Resources/Whisper-LICENSE.txt "$RECORDER_APP/Contents/Resources/Whisper-LICENSE.txt"
cp Resources/final-asr-worker.py "$RECORDER_APP/Contents/Resources/final-asr-worker.py"
RECORDER_WORKSPACE="$RECORDER_ROOT" python3 - <<'PY'
import json,os
from pathlib import Path
root=Path(os.environ['RECORDER_WORKSPACE'])
selection=json.loads((root/'Resources/ASRSelection.json').read_text())
model_path='.runtime/models/cohere' if selection['engine']=='cohere' else '.runtime/models/qwen17'
python_path='.runtime/cohere/bin/python' if selection['engine']=='cohere' else '.runtime/asr/bin/python'
selection.update(python=str(root/python_path), model=str(root/model_path),
                 models={name:str(root/'.runtime/models'/name) for name in ['cohere','qwen17']},
                 runtimes={'cohere':str(root/'.runtime/cohere/bin/python'),'qwen17':str(root/'.runtime/asr/bin/python')},
                 worker=str(root/'dist/Meeting Recorder.app/Contents/Resources/final-asr-worker.py'))
(root/'dist/Meeting Recorder.app/Contents/Resources/LocalASR.json').write_text(json.dumps(selection,ensure_ascii=False,indent=2))
PY
codesign --force --sign - --options runtime --entitlements Resources/Entitlements.plist "$RECORDER_APP"
printf '%s\n' "$RECORDER_APP"
