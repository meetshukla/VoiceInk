#!/bin/zsh
set -euo pipefail
umask 077

script_dir="${0:A:h}"
fixture="${1:-/Applications/VoiceInk.app}"
test_dir=$(mktemp -d /private/tmp/voiceink-updater-test.XXXXXX)
test_parent=""
test_installer=""
cleanup() {
  [[ -z "$test_parent" ]] || kill "$test_parent" 2>/dev/null || true
  [[ -z "$test_installer" ]] || kill "$test_installer" 2>/dev/null || true
  rm -rf "$test_dir"
}
trap cleanup EXIT

mkdir -p "$test_dir/release" "$test_dir/state"
ln -s "$HOME/Library/Application Support/VoiceInk Local Updater/signing" "$test_dir/state/signing"
ditto "$fixture" "$test_dir/release/VoiceInk.app"
mkdir -p "$test_dir/release/VoiceInk.app/Contents/Resources"
ditto "$script_dir/voiceink-local-updater.sh" "$test_dir/release/VoiceInk.app/Contents/Resources/voiceink-local-updater.sh"
/usr/libexec/PlistBuddy -c 'Delete :VoiceInkUsesLocalUpdater' "$test_dir/release/VoiceInk.app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :VoiceInkUsesLocalUpdater bool true' "$test_dir/release/VoiceInk.app/Contents/Info.plist"
codesign --force --preserve-metadata=entitlements,flags --sign - "$test_dir/release/VoiceInk.app"
ditto -c -k --keepParent "$test_dir/release/VoiceInk.app" "$test_dir/release/VoiceInk-local.zip"
checksum=$(shasum -a 256 "$test_dir/release/VoiceInk-local.zip" | awk '{print $1}')
print "$checksum  VoiceInk-local.zip" > "$test_dir/release/VoiceInk-local.sha256"

export VOICEINK_RELEASE_BASE="file://$test_dir/release"
export VOICEINK_APP_PATH="$test_dir/VoiceInk.app"
export VOICEINK_UPDATER_STATE_DIR="$test_dir/state"
export VOICEINK_PROCESS_NAME=VoiceInkUpdaterTestFixture
export VOICEINK_RELAUNCH=0

sleep 60 &
test_parent=$!
/bin/zsh "$script_dir/voiceink-local-updater.sh" --interactive "$test_parent" "$test_dir/status" "$checksum" > "$test_dir/update.log" 2>&1 &
test_installer=$!
for _ in {1..40}; do
  [[ ! -f "$test_dir/status" ]] || break
  kill -0 "$test_installer" 2>/dev/null || { tail -20 "$test_dir/update.log"; exit 1; }
  sleep 0.5
done
[[ -f "$test_dir/status" && ! -e "$VOICEINK_APP_PATH" ]]
print "PASS: download and signing complete before the old app exits."
kill "$test_parent"
wait "$test_parent" 2>/dev/null || true
test_parent=""
wait "$test_installer"
test_installer=""
codesign --verify --deep --strict "$VOICEINK_APP_PATH"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :VoiceInkLocalBuildChecksum' "$VOICEINK_APP_PATH/Contents/Info.plist")" == "$checksum" ]]
! /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$VOICEINK_APP_PATH/Contents/Info.plist" 2>/dev/null
print "PASS: install preserves the stable signature and records the exact build."

/bin/zsh "$script_dir/voiceink-local-updater.sh" | rg -q 'already up to date'
print "PASS: checking the installed release does not replace it."

if /bin/zsh "$script_dir/voiceink-local-updater.sh" --interactive $$ "$test_dir/status-bad" "$(printf '%064d' 0)" > "$test_dir/bad.log" 2>&1; then exit 1; fi
rg -q 'release changed' "$test_dir/bad.log"
codesign --verify --deep --strict "$VOICEINK_APP_PATH"
print "PASS: a changed release is rejected before the installed app is changed."
