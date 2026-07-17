#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
source_updater="$script_dir/voiceink-local-updater.sh"
state_dir="$HOME/Library/Application Support/VoiceInk Local Updater"
installed_updater="$state_dir/update.sh"
launch_agents_dir="$HOME/Library/LaunchAgents"
launch_agent="$launch_agents_dir/com.meetshukla.voiceink-local-updater.plist"
log_path="$state_dir/updater.log"
error_log_path="$state_dir/updater-error.log"
user_domain="gui/$(id -u)"

if [[ ! -f "$source_updater" ]]; then
  print -u2 "Updater script not found: $source_updater"
  exit 1
fi

mkdir -p "$state_dir" "$launch_agents_dir"
ditto "$source_updater" "$installed_updater"
chmod 700 "$installed_updater"

plutil -create xml1 "$launch_agent"
plutil -insert Label -string "com.meetshukla.voiceink-local-updater" "$launch_agent"
plutil -insert ProgramArguments -json "[\"/bin/zsh\", \"$installed_updater\"]" "$launch_agent"
plutil -insert RunAtLoad -bool true "$launch_agent"
plutil -insert StartInterval -integer 21600 "$launch_agent"
plutil -insert ProcessType -string "Background" "$launch_agent"
plutil -insert StandardOutPath -string "$log_path" "$launch_agent"
plutil -insert StandardErrorPath -string "$error_log_path" "$launch_agent"

launchctl bootout "$user_domain" "$launch_agent" 2>/dev/null || true
launchctl bootstrap "$user_domain" "$launch_agent"

print "VoiceInk automatic updates are installed and will run every six hours."
print "Running the first update check now..."
"$installed_updater"
