#!/bin/zsh

set -euo pipefail
umask 077

interactive=0
parent_pid=""
ready_file=""
expected_checksum=""
if [[ "${1:-}" == --interactive ]]; then
  [[ $# == 4 && "$2" == <-> ]] || { print -u2 "Invalid interactive updater arguments."; exit 1; }
  interactive=1
  parent_pid="$2"
  ready_file="$3"
  expected_checksum="$4"
elif (( $# )); then
  print -u2 "Unknown updater arguments."
  exit 1
fi

readonly release_base="${VOICEINK_RELEASE_BASE:-https://github.com/meetshukla/VoiceInk/releases/download/local-build}"
readonly archive_url="$release_base/VoiceInk-local.zip"
readonly checksum_url="$release_base/VoiceInk-local.sha256"
readonly bundle_id="com.prakashjoshipax.VoiceInk"
readonly process_name="${VOICEINK_PROCESS_NAME:-VoiceInk}"
readonly app_path="${VOICEINK_APP_PATH:-/Applications/VoiceInk.app}"
readonly state_dir="${VOICEINK_UPDATER_STATE_DIR:-$HOME/Library/Application Support/VoiceInk Local Updater}"
readonly installed_checksum_file="$state_dir/installed.sha256"
readonly lock_dir="$state_dir/update.lock"
readonly signing_identity="VoiceInk Local Auto Update"
readonly signing_keychain="$HOME/Library/Keychains/VoiceInkLocalSigning.keychain-db"
readonly signing_password_file="$state_dir/signing/keychain-password"

mkdir -p "$state_dir"

if ! mkdir "$lock_dir" 2>/dev/null; then
  print "A VoiceInk update is already running."
  if (( interactive )); then exit 1; fi
  exit 0
fi

temp_dir=""
new_app=""
cleanup() {
  if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
    rm -rf "$temp_dir"
  fi
  if [[ -n "$new_app" && -d "$new_app" ]]; then
    rm -rf "$new_app"
  fi
  rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' INT TERM

print "Checking for the latest private VoiceInk build..."

if [[ ! -f "$signing_keychain" || ! -f "$signing_password_file" ]]; then
  print -u2 "The stable VoiceInk signing identity is not configured."
  exit 1
fi

signing_password=$(<"$signing_password_file")
security unlock-keychain -p "$signing_password" "$signing_keychain"
signing_hash=$(
  security find-identity -v -p codesigning "$signing_keychain" \
    | awk -v name="$signing_identity" 'index($0, "\"" name "\"") { print $2; exit }'
)
if [[ -z "$signing_hash" ]]; then
  print -u2 "The stable VoiceInk signing identity is unavailable."
  exit 1
fi

if (( ! interactive )) && pgrep -x "$process_name" >/dev/null 2>&1; then
  print "VoiceInk is running. The updater will retry after it is closed."
  exit 0
fi
stable_requirement_fragment="certificate root = H\"${signing_hash:l}\""
latest_checksum=$(curl -fsSL --retry 3 "$checksum_url" | awk 'NR == 1 { print $1 }')
if (( ${#latest_checksum} != 64 )) || [[ "$latest_checksum" == *[^0-9a-fA-F]* ]]; then
  print -u2 "The published VoiceInk checksum is invalid."
  exit 1
fi
if (( interactive )) && [[ "$latest_checksum" != "$expected_checksum" ]]; then
  print -u2 "The release changed while checking for updates. Check again."
  exit 1
fi

installed_checksum=""
if [[ -f "$installed_checksum_file" ]]; then
  installed_checksum=$(<"$installed_checksum_file")
fi

if [[ -d "$app_path" && "$installed_checksum" == "$latest_checksum" ]]; then
  installed_requirement=$(codesign -dr - "$app_path" 2>&1 || true)
  installed_local_updater=$(/usr/libexec/PlistBuddy -c 'Print :VoiceInkUsesLocalUpdater' "$app_path/Contents/Info.plist" 2>/dev/null || true)
  installed_feed=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app_path/Contents/Info.plist" 2>/dev/null || true)
  installed_build_checksum=$(/usr/libexec/PlistBuddy -c 'Print :VoiceInkLocalBuildChecksum' "$app_path/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$installed_requirement" == *"$stable_requirement_fragment"* && "$installed_local_updater" == true && -z "$installed_feed" && "$installed_build_checksum" == "$latest_checksum" ]]; then
    print "VoiceInk is already up to date."
    exit 0
  fi

  print "The app is current but needs its stable local signature refreshed."
fi

temp_dir=$(mktemp -d "${TMPDIR%/}/voiceink-update.XXXXXX")
archive_path="$temp_dir/VoiceInk-local.zip"
unpack_dir="$temp_dir/unpacked"
mkdir -p "$unpack_dir"

curl -fL --retry 3 --output "$archive_path" "$archive_url"
actual_checksum=$(shasum -a 256 "$archive_path" | awk '{ print $1 }')
if [[ "$actual_checksum" != "$latest_checksum" ]]; then
  print -u2 "VoiceInk download verification failed. The installed app was not changed."
  exit 1
fi

ditto -x -k "$archive_path" "$unpack_dir"
candidate_app="$unpack_dir/VoiceInk.app"
if [[ ! -d "$candidate_app" ]]; then
  print -u2 "The downloaded archive did not contain VoiceInk.app."
  exit 1
fi

candidate_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate_app/Contents/Info.plist")
if [[ "$candidate_bundle_id" != "$bundle_id" ]]; then
  print -u2 "The downloaded app has the wrong bundle identifier."
  exit 1
fi

codesign --verify --deep --strict "$candidate_app"
candidate_local_build=$(/usr/libexec/PlistBuddy -c 'Print :VoiceInkUsesLocalUpdater' "$candidate_app/Contents/Info.plist" 2>/dev/null || true)
if [[ "$candidate_local_build" != true ]]; then
  print -u2 "The release is not marked as a local source build. The installed app was kept."
  exit 1
fi

install_parent="${app_path:h}"
new_app="$install_parent/.VoiceInk.new.$$"
backup_dir="$state_dir/app-backups"
backup_app="$backup_dir/VoiceInk-$(date +%Y%m%d-%H%M%S).app"
mkdir -p "$install_parent" "$backup_dir"

if [[ -e "$new_app" ]]; then
  print -u2 "Temporary install path already exists: $new_app"
  exit 1
fi

ditto "$candidate_app" "$new_app"
xattr -cr "$new_app"
# Prevent even older local builds from switching to the official trial build.
/usr/libexec/PlistBuddy -c 'Delete :SUFeedURL' "$new_app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Delete :VoiceInkUsesLocalUpdater' "$new_app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :VoiceInkUsesLocalUpdater bool true' "$new_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :VoiceInkLocalBuildChecksum' "$new_app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :VoiceInkLocalBuildChecksum string $latest_checksum" "$new_app/Contents/Info.plist"
codesign --force --preserve-metadata=entitlements,flags --sign "$signing_hash" "$new_app"
codesign --verify --deep --strict "$new_app"
signed_requirement=$(codesign -dr - "$new_app" 2>&1)
if [[ "$signed_requirement" != *"$stable_requirement_fragment"* ]]; then
  rm -rf "$new_app"
  print -u2 "VoiceInk did not receive the expected stable signature."
  exit 1
fi

if (( interactive )); then
  # The app exits only after download, validation, and signing have succeeded.
  print ready > "$ready_file"
  for _ in {1..120}; do
    if ! kill -0 "$parent_pid" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$parent_pid" 2>/dev/null; then
    print -u2 "VoiceInk did not exit. The installed app was kept."
    exit 1
  fi
fi

if pgrep -x "$process_name" >/dev/null 2>&1; then
  rm -rf "$new_app"
  print "VoiceInk started while the update was prepared. The updater will retry after it is closed."
  exit 0
fi

if [[ -e "$app_path" ]]; then
  mv "$app_path" "$backup_app"
fi

if ! mv "$new_app" "$app_path"; then
  if [[ -d "$backup_app" && ! -e "$app_path" ]]; then
    mv "$backup_app" "$app_path"
  fi
  print -u2 "VoiceInk installation failed and the previous app was restored."
  exit 1
fi

checksum_temp="$state_dir/installed.sha256.$$"
print -r -- "$latest_checksum" > "$checksum_temp"
mv "$checksum_temp" "$installed_checksum_file"

print "VoiceInk was updated successfully."
print "Your recordings, history, preferences, and Keychain were not modified."
if (( interactive )) && [[ "${VOICEINK_RELAUNCH:-1}" == 1 ]]; then
  open "$app_path"
fi
