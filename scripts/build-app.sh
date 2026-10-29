#!/bin/bash
set -euo pipefail
RECORDER_PACKAGE_ONLY=0
case "${1:-}" in
  "") ;;
  --package-only) RECORDER_PACKAGE_ONLY=1 ;;
  *) echo "Usage: bash scripts/build-app.sh [--package-only]" >&2; exit 2 ;;
esac
RECORDER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RECORDER_ROOT"
python3 scripts/app-signing.py preflight
mkdir -p .build/cache .build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$RECORDER_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$RECORDER_ROOT/.build/ModuleCache"
swift build --configuration release --disable-sandbox --cache-path "$RECORDER_ROOT/.build/cache"
RECORDER_BIN="$(swift build --configuration release --show-bin-path --disable-sandbox --cache-path "$RECORDER_ROOT/.build/cache")"
RECORDER_APP_FINAL="$RECORDER_ROOT/dist/Meeting Recorder.app"
mkdir -p "$RECORDER_ROOT/dist"
RECORDER_STAGE=$(mktemp -d "$RECORDER_ROOT/dist/.app-build.XXXXXX")
trap 'rm -rf "$RECORDER_STAGE"' EXIT
RECORDER_APP="$RECORDER_STAGE/Meeting Recorder.app"
mkdir -p "$RECORDER_APP/Contents/MacOS"
cp "$RECORDER_BIN/MeetingRecorder" "$RECORDER_APP/Contents/MacOS/MeetingRecorder"
cp "$RECORDER_BIN/MeetingRecorderMCP" "$RECORDER_APP/Contents/MacOS/MeetingRecorderMCP"
cp Resources/Info.plist "$RECORDER_APP/Contents/Info.plist"
mkdir -p "$RECORDER_APP/Contents/Resources"
cp -f .build/checkouts/FluidAudio/LICENSE "$RECORDER_APP/Contents/Resources/FluidAudio-LICENSE.txt"
cp -f .build/checkouts/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md "$RECORDER_APP/Contents/Resources/fastcluster-LICENSE.txt"
cp -f .build/checkouts/FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md "$RECORDER_APP/Contents/Resources/VBx-LICENSE.txt"
cp Resources/ThirdPartyNotices.txt "$RECORDER_APP/Contents/Resources/ThirdPartyNotices.txt"
cp -f .build/checkouts/argmax-oss-swift/LICENSE "$RECORDER_APP/Contents/Resources/WhisperKit-LICENSE.txt"
cp -f .build/checkouts/argmax-oss-swift/NOTICES "$RECORDER_APP/Contents/Resources/WhisperKit-NOTICES.txt"
cp -f Resources/Whisper-LICENSE.txt "$RECORDER_APP/Contents/Resources/Whisper-LICENSE.txt"
python3 scripts/app-signing.py sign "$RECORDER_APP" "$RECORDER_APP_FINAL"
if [ "$RECORDER_PACKAGE_ONLY" = "1" ]; then
    RECORDER_PACKAGE_TARGET="$RECORDER_ROOT/dist/package/Meeting Recorder.app"
    mkdir -p "$RECORDER_ROOT/dist/package"
    python3 scripts/app-signing.py install "$RECORDER_APP" "$RECORDER_PACKAGE_TARGET"
    printf '%s\n' "$RECORDER_PACKAGE_TARGET"
else
    python3 scripts/app-signing.py install "$RECORDER_APP" "$RECORDER_APP_FINAL"
    printf '%s\n' "$RECORDER_APP_FINAL"
fi
