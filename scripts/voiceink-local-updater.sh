#!/bin/zsh

set -euo pipefail

readonly release_base="${VOICEINK_RELEASE_BASE:-https://github.com/meetshukla/VoiceInk/releases/download/local-build}"
readonly archive_url="$release_base/VoiceInk-local.zip"
readonly checksum_url="$release_base/VoiceInk-local.sha256"
readonly bundle_id="com.prakashjoshipax.VoiceInk"
readonly process_name="${VOICEINK_PROCESS_NAME:-VoiceInk}"
readonly app_path="${VOICEINK_APP_PATH:-/Applications/VoiceInk.app}"
readonly state_dir="${VOICEINK_UPDATER_STATE_DIR:-$HOME/Library/Application Support/VoiceInk Local Updater}"
readonly installed_checksum_file="$state_dir/installed.sha256"
readonly lock_dir="$state_dir/update.lock"

mkdir -p "$state_dir"

if ! mkdir "$lock_dir" 2>/dev/null; then
  print "A VoiceInk update is already running."
  exit 0
fi

temp_dir=""
cleanup() {
  if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
    rm -rf "$temp_dir"
  fi
  rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

print "Checking for the latest private VoiceInk build..."
latest_checksum=$(curl -fsSL --retry 3 "$checksum_url" | awk 'NR == 1 { print $1 }')
if (( ${#latest_checksum} != 64 )) || [[ "$latest_checksum" == *[^0-9a-fA-F]* ]]; then
  print -u2 "The published VoiceInk checksum is invalid."
  exit 1
fi

installed_checksum=""
if [[ -f "$installed_checksum_file" ]]; then
  installed_checksum=$(<"$installed_checksum_file")
fi

if [[ -d "$app_path" && "$installed_checksum" == "$latest_checksum" ]]; then
  print "VoiceInk is already up to date."
  exit 0
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

was_running=0
if pgrep -x "$process_name" >/dev/null 2>&1; then
  was_running=1
  osascript -e 'tell application id "com.prakashjoshipax.VoiceInk" to quit' 2>/dev/null || true
  for _ in {1..20}; do
    if ! pgrep -x "$process_name" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi

if pgrep -x "$process_name" >/dev/null 2>&1; then
  rm -rf "$new_app"
  print -u2 "VoiceInk did not quit, so the installed app was not changed."
  exit 1
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

if (( was_running )); then
  open "$app_path"
fi

print "VoiceInk was updated successfully."
print "Your recordings, history, preferences, and Keychain were not modified."
