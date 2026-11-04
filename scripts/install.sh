#!/bin/bash
# Binary installer for macOS; compatible with the system Bash 3.2.
# Keep the release commit and checksum pinned when updating this installer.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

fail() { printf '설치 중단: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'HELP'
Meeting Recorder 0.8.1 설치
  bash install.sh [옵션]

  --install-dir 경로  앱을 넣을 절대 경로 (예: "$HOME/Applications")
  --skip-model       음성인식 모델은 첫 녹음 때 준비
  --no-open          설치 후 앱을 열지 않음
  --with-ollama      Ollama 앱을 추가로 준비 (모델 다운로드 생략)
  --ollama-model 이름  내려받을 로컬 모델을 직접 선택 (--with-ollama 필요)
  --archive 경로     다운로드 대신 로컬의 공식 ZIP 사용 (같은 SHA-256 검사)
  --help            이 안내 표시

기존 /Applications 또는 ~/Applications의 앱 위치를 우선 사용합니다.
새 설치는 /Applications에 쓰기 가능하면 그곳에, 아니면 ~/Applications에 합니다.
앱·MCP 서버를 설치하고 권장 Whisper 모델을 준비합니다. 녹음 권한과 저장 폴더는
앱에서 확인하세요. 회의를 요약할 때는 연결 설정에서 Codex 또는 Claude Code를 선택하세요.
배포본 설치에는 개인 서명 인증서나 개발자 계정이 필요하지 않습니다.
HELP
}

prepare_ollama() {
    local app='' cli='' archive_file downloaded ollama_version=0.40.14
    local ollama_sha=9047386fb6811f54fc98b12ce4fea42a6ee5ce9e1bbc0c8196499f347054bcb5
    local ollama_model=$1
    if [ -d '/Applications/Ollama.app' ]; then app='/Applications/Ollama.app'
    elif [ -d "$HOME/Applications/Ollama.app" ]; then app="$HOME/Applications/Ollama.app"
    else
        printf 'Ollama %s 다운로드 (약 219 MB)\n' "$ollama_version"
        archive_file="$work_dir/ollama.zip"
        curl --fail --location --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --connect-timeout 20 --retry 3 --output "$archive_file" \
            "https://github.com/ollama/ollama/releases/download/v${ollama_version}/Ollama-darwin.zip"
        downloaded=$(shasum -a 256 "$archive_file" | awk '{print $1}')
        [ "$downloaded" = "$ollama_sha" ] || fail 'Ollama 배포본 SHA-256이 일치하지 않습니다.'
        mkdir -p "$work_dir/ollama"
        ditto -x -k "$archive_file" "$work_dir/ollama"
        codesign --verify --deep --strict "$work_dir/ollama/Ollama.app" || fail 'Ollama 서명을 확인하지 못했습니다.'
        codesign --verify --strict -R='anchor apple generic and identifier "com.electron.ollama" and certificate leaf[subject.OU] = "3MU9H2V9Y9"' "$work_dir/ollama/Ollama.app" || fail 'Ollama 배포자 서명이 일치하지 않습니다.'
        if [ -w /Applications ]; then app='/Applications/Ollama.app'
        else mkdir -p "$HOME/Applications"; app="$HOME/Applications/Ollama.app"; fi
        [ ! -e "$app" ] || fail "Ollama 설치 위치가 이미 사용 중입니다: $app"
        mv "$work_dir/ollama/Ollama.app" "$app"
        printf 'Ollama 설치 완료: %s\n' "$app"
    fi
    cli="$app/Contents/Resources/ollama"
    [ -x "$cli" ] || fail '기존 Ollama 앱에서 실행 파일을 찾지 못했습니다. Ollama 설치를 확인하세요.'
    if [ -z "$ollama_model" ]; then
        printf '모델 다운로드 생략. 모델을 준비하려면 --ollama-model 이름을 지정하세요.\n'
        return
    fi
    printf 'Ollama를 시작하고 %s 모델을 준비합니다. 모델 다운로드에 수 GB의 공간과 시간이 필요할 수 있습니다.\n' "$ollama_model"
    open "$app" || fail 'Ollama를 시작하지 못했습니다. 앱을 직접 열고 다시 시도하세요.'
    local attempt=0
    until curl --silent --fail --connect-timeout 1 http://127.0.0.1:11434/api/tags >/dev/null; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 60 ] || fail 'Ollama 서버가 시작되지 않았습니다. 앱을 열어 초기 설정을 마친 뒤 다시 시도하세요.'
        sleep 1
    done
    OLLAMA_HOST=127.0.0.1:11434 "$cli" pull "$ollama_model" || fail '모델 준비에 실패했습니다. 앱 설치는 유지됩니다. 네트워크와 저장 공간을 확인한 뒤 다시 시도하세요.'
}

cleanup() {
    local result=$?
    trap - EXIT
    # Restore the old bundle if a signal or failed move interrupted the swap.
    if [ -n "$backup_app" ] && [ -d "$backup_app" ] && [ ! -e "$target_app" ]; then
        mv "$backup_app" "$target_app" || printf '이전 앱을 직접 복원하세요: %s\n' "$backup_app" >&2
    fi
    [ -z "$work_dir" ] || rm -rf "$work_dir"
    [ "$lock_owned" = 0 ] || rmdir "$lock_dir" || true
    exit "$result"
}

assert_not_running() {
    local expression result
    expression=$(printf '%s' "$target_app/Contents/MacOS/MeetingRecorder" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
    if pgrep -f "^${expression}([[:space:]]|$)" >/dev/null; then
        fail "설치할 위치의 앱이 실행 중입니다. 녹음을 마치고 앱을 종료한 뒤 다시 실행하세요."
    else
        result=$?
        [ "$result" = 1 ] || fail '실행 중인 앱을 확인할 수 없습니다.'
    fi
}

requirement() {
    codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'
}

check_existing_app() {
    [ ! -L "$target_app" ] || fail "설치 경로가 심볼릭 링크입니다: $target_app"
    if [ -e "$target_app" ]; then
        [ -d "$target_app" ] || fail "설치 경로에 앱이 아닌 파일이 있습니다: $target_app"
        codesign --verify --deep --strict "$target_app" || fail '기존 앱 서명이 유효하지 않습니다. 기존 앱은 변경하지 않았습니다.'
        local old_requirement new_requirement
        old_requirement=$(requirement "$target_app")
        new_requirement=$(requirement "$staged_app")
        [ -n "$old_requirement" ] && [ -n "$new_requirement" ] || fail '앱의 서명 식별 조건을 읽지 못했습니다.'
        codesign --verify --strict "-R=$old_requirement" "$staged_app" &&
            codesign --verify --strict "-R=$new_requirement" "$target_app" ||
            fail '기존 앱과 새 앱의 서명이 다릅니다. 앱을 재서명하거나 삭제하지 말고 배포자에게 호환되는 업데이트를 요청하세요. 기존 앱과 녹음은 변경하지 않았습니다.'
    fi
}

main() {
    local version=0.8.1 release_commit=0f2c23fa2c93d096a26141b4c1a3d7fdf3e973fe
    local expected_sha=9a4613febba9658b8a668ceab10fc6a66ad8ab56c5d50e66331c346f93eaae26
    local install_dir='' archive='' skip_model=0 no_open=0 with_ollama=0 has_ollama_model=0 ollama_model='' major downloaded_sha
    local archive_name="Meeting-Recorder-${version}-macOS-arm64.zip"
    local base_url="https://raw.githubusercontent.com/minnong511/meeting-auto-recoder/${release_commit}/releases"
    work_dir='' backup_app='' target_app='' lock_dir='' lock_owned=0
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --install-dir|--archive|--ollama-model)
                [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 뒤에 경로를 입력하세요."
                case "$1" in --install-dir) install_dir=$2 ;; --archive) archive=$2 ;; --ollama-model) ollama_model=$2; has_ollama_model=1 ;; esac
                shift 2 ;;
            --skip-model) skip_model=1; shift ;;
            --no-open) no_open=1; shift ;;
            --with-ollama) with_ollama=1; shift ;;
            --help|-h) usage; return ;;
            *) fail "알 수 없는 옵션: $1 (--help 참고)" ;;
        esac
    done
    [ "$has_ollama_model" = 0 ] || [ "$with_ollama" = 1 ] || fail '--ollama-model은 --with-ollama와 함께 사용하세요.'
    if [ "$has_ollama_model" = 1 ]; then
        case "$ollama_model" in *:cloud|*:cloud/*) fail '클라우드 모델은 지원하지 않습니다.' ;; esac
        [[ "$ollama_model" =~ ^[a-z0-9][a-z0-9._-]*:[a-z0-9][a-z0-9._-]*$ ]] || fail '모델 이름은 qwen3.5:4b 형식의 기본 라이브러리 모델이어야 합니다.'
    fi
    [ "$(uname -s)" = Darwin ] || fail 'macOS 전용 설치 프로그램입니다.'
    if [ "$(uname -m)" != arm64 ]; then
        [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || fail 'Apple Silicon Mac이 필요합니다.'
    fi
    major=$(sw_vers -productVersion); major=${major%%.*}
    [ "$major" -ge 26 ] || fail 'macOS 26 이상이 필요합니다.'
    [ "$(id -u)" != 0 ] || fail 'sudo 없이 현재 사용자로 실행하세요. 모델은 현재 사용자에게 설치됩니다.'

    if [ -z "$install_dir" ]; then
        if [ -e '/Applications/Meeting Recorder.app' ] && [ -e "$HOME/Applications/Meeting Recorder.app" ]; then
            fail '두 응용 프로그램 폴더에 앱이 있습니다. --install-dir로 업데이트할 폴더를 선택하세요.'
        elif [ -e '/Applications/Meeting Recorder.app' ]; then install_dir=/Applications
        elif [ -e "$HOME/Applications/Meeting Recorder.app" ]; then install_dir="$HOME/Applications"
        elif [ -w /Applications ]; then install_dir=/Applications
        else install_dir="$HOME/Applications"; fi
    fi
    case "$install_dir" in /*) ;; *) fail '--install-dir에는 절대 경로를 입력하세요.' ;; esac
    mkdir -p "$install_dir" || fail "설치 폴더를 만들 수 없습니다: $install_dir"
    install_dir=$(cd "$install_dir" && pwd -P)
    [ -w "$install_dir" ] || fail "설치 폴더에 쓰기 권한이 없습니다. --install-dir로 다른 폴더를 선택하세요: $install_dir"
    target_app="$install_dir/Meeting Recorder.app"
    lock_dir="$install_dir/.meeting-recorder-install.lock"
    mkdir "$lock_dir" 2>/dev/null || fail "다른 설치가 진행 중이거나 이전 설치가 강제 종료되었습니다. 실행 중인 설치가 없는지 확인하세요: $lock_dir"
    lock_owned=1
    assert_not_running
    work_dir=$(mktemp -d "$install_dir/.meeting-recorder-install.XXXXXX")

    if [ -z "$archive" ]; then
        archive="$work_dir/$archive_name"
        printf '[1/4] Meeting Recorder %s 다운로드\n' "$version"
        curl --fail --location --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --connect-timeout 20 --retry 3 --output "$archive" "$base_url/$archive_name"
    else
        printf '[1/4] 로컬 배포본 사용: %s\n' "$archive"
    fi
    [ -f "$archive" ] || fail '배포 ZIP 파일을 찾을 수 없습니다.'
    downloaded_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
    [ "$downloaded_sha" = "$expected_sha" ] || fail '배포본 SHA-256이 일치하지 않습니다. 앱을 설치하지 않았습니다.'

    printf '[2/4] 무결성 및 앱 서명 확인\n'
    ditto -x -k "$archive" "$work_dir/extracted"
    staged_app="$work_dir/extracted/Meeting-Recorder-${version}-macOS-arm64/Meeting Recorder.app"
    [ "$(plutil -extract CFBundleIdentifier raw -o - "$staged_app/Contents/Info.plist")" = dev.meetingrecorder.prototype ] || fail '앱 식별자가 올바르지 않습니다.'
    [ "$(plutil -extract CFBundleShortVersionString raw -o - "$staged_app/Contents/Info.plist")" = "$version" ] || fail '앱 버전이 올바르지 않습니다.'
    codesign --verify --deep --strict "$staged_app" || fail '앱 서명이 유효하지 않습니다.'
    codesign --verify --strict "$staged_app/Contents/MacOS/MeetingRecorderMCP" || fail 'MCP 서버 서명이 유효하지 않습니다.'
    check_existing_app
    assert_not_running
    if [ -e "$target_app" ]; then
        mkdir -p "$install_dir/.meeting-recorder-backups"
        backup_app="$(mktemp -d "$install_dir/.meeting-recorder-backups/previous.XXXXXX")/Meeting Recorder.app"
        mv "$target_app" "$backup_app"
    fi
    mv "$staged_app" "$target_app"
    printf '앱과 MCP 서버 설치 완료: %s\n' "$target_app"
    [ -z "$backup_app" ] || printf '이전 앱 백업 (연결된 MCP 보존): %s\n' "$backup_app"
    printf '현재 배포본은 Apple 공증을 받지 않았습니다. macOS가 차단하면 신뢰하는 출처인지 확인한 뒤 시스템 설정에서 앱별 실행을 승인하세요.\n'

    if [ "$skip_model" = 0 ]; then
        printf '[3/4] 권장 Whisper 모델 준비 (메모리 16GB 이상 약 3.10GB, 그 미만 약 948MB + 추가 캐시)\n'
        if ! "$target_app/Contents/MacOS/MeetingRecorder" --prepare-speech; then
            printf '앱 설치는 완료했으나 모델 준비에 실패했습니다. 인터넷 연결과 macOS 실행 승인을 확인한 뒤 설치 명령을 다시 실행하거나 첫 녹음 때 재시도하세요.\n' >&2
            exit 2
        fi
    else
        printf '[3/4] 모델 준비 생략: 첫 녹음 때 내려받습니다.\n'
    fi
    if [ "$with_ollama" = 1 ]; then prepare_ollama "$ollama_model"; fi
    if [ "$no_open" = 0 ]; then
        printf '[4/4] 앱 열기\n'
        open "$target_app" || fail "앱은 설치되었습니다. Finder에서 직접 여세요: $target_app"
    else
        printf '[4/4] 앱 실행 생략\n'
    fi
    printf '설치 완료. 앱에서 저장 폴더와 macOS 녹음 권한을 확인하세요. 회의를 요약하려면 설정 및 연결 → 연결에서 Codex 또는 Claude Code를 선택하세요.\n'
}

# The entry point is last so a truncated download cannot start installation.
main "$@"
