#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
app_path=${1:-"$project_dir/屏幕词典.app"}
scratch_dir=${2:-"$project_dir/.build"}
if [[ -e "$app_path" ]]; then
    print -u2 "输出位置已有文件。请选择新的 .app 路径。"
    exit 1
fi

signing_identity=${SCREEN_DICTIONARY_SIGNING_IDENTITY:-}
if [[ -z "$signing_identity" ]]; then
    signing_identity=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Apple Development: / { print $2; exit }')
fi
if [[ -z "$signing_identity" ]]; then
    signing_identity=-
    print -u2 "未找到 Apple Development 签名。本次使用临时签名，重新构建后可能需要再次授权。"
fi

swift build --package-path "$project_dir" --scratch-path "$scratch_dir" --configuration release --product ScreenDictionary
binary_dir=$(swift build --package-path "$project_dir" --scratch-path "$scratch_dir" --configuration release --show-bin-path)
mkdir -p "${app_path:h}"
stage_dir=$(mktemp -d "${app_path:h}/.screendictionary-XXXXXXXX")
trap 'rm -rf -- "$stage_dir"' EXIT
staged_app="$stage_dir/${app_path:t}"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
install -m 755 "$binary_dir/ScreenDictionary" "$staged_app/Contents/MacOS/ScreenDictionary"
install -m 644 "$project_dir/Packaging/Info.plist" "$staged_app/Contents/Info.plist"
install -m 644 "$project_dir/Packaging/Resources/ECDICT.sqlite3" "$staged_app/Contents/Resources/ECDICT.sqlite3"
install -m 644 "$project_dir/Packaging/Resources/ECDICT-LICENSE.txt" "$staged_app/Contents/Resources/ECDICT-LICENSE.txt"
codesign --force --sign "$signing_identity" --timestamp=none "$staged_app"
mv -n "$staged_app" "$app_path"
if [[ -e "$staged_app" ]]; then
    print -u2 "输出位置已有文件。请选择新的 .app 路径。"
    exit 1
fi
print -r -- "$app_path"
