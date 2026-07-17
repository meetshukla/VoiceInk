#!/bin/zsh

set -euo pipefail

readonly identity_name="VoiceInk Local Auto Update"
readonly keychain_name="VoiceInkLocalSigning.keychain"
readonly keychain_path="$HOME/Library/Keychains/VoiceInkLocalSigning.keychain-db"
readonly state_dir="$HOME/Library/Application Support/VoiceInk Local Updater"
readonly signing_dir="$state_dir/signing"
readonly password_file="$signing_dir/keychain-password"
readonly certificate_file="$signing_dir/VoiceInkLocalSigningCertificate.pem"

umask 077
mkdir -p "$signing_dir"

add_keychain_to_search_list() {
  local -a current_keychains
  local item
  local found=0

  current_keychains=("${(@f)$(security list-keychains -d user | tr -d ' \"')}")
  for item in "${current_keychains[@]}"; do
    if [[ "$item" == "$keychain_path" ]]; then
      found=1
      break
    fi
  done

  if (( ! found )); then
    security list-keychains -d user -s "${current_keychains[@]}" "$keychain_path"
  fi
}

if [[ -f "$keychain_path" && -f "$password_file" ]]; then
  keychain_password=$(<"$password_file")
  security unlock-keychain -p "$keychain_password" "$keychain_path"
  add_keychain_to_search_list

  if security find-identity -v -p codesigning "$keychain_path" | grep -Fq "\"$identity_name\""; then
    print "The stable VoiceInk signing identity is already configured."
    exit 0
  fi

  print -u2 "The VoiceInk signing keychain exists but its identity is unavailable."
  exit 1
fi

if [[ -e "$keychain_path" || -e "$password_file" ]]; then
  print -u2 "A partial VoiceInk signing configuration exists. No files were changed."
  exit 1
fi

temp_dir=$(mktemp -d "${TMPDIR%/}/voiceink-signing.XXXXXX")
cleanup() {
  rm -rf "$temp_dir"
}
trap cleanup EXIT INT TERM

# Keep this at 32 ASCII characters. macOS's legacy PKCS#12 importer rejects
# some longer passwords even though OpenSSL accepts them.
keychain_password="$(uuidgen | tr -d '-')"

openssl req -x509 -newkey rsa:3072 -nodes -days 10950 \
  -keyout "$temp_dir/private-key.pem" \
  -out "$temp_dir/certificate.pem" \
  -subj "/CN=$identity_name/O=Meet Shukla/" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  >/dev/null 2>&1

openssl pkcs12 -export \
  -legacy \
  -out "$temp_dir/identity.p12" \
  -inkey "$temp_dir/private-key.pem" \
  -in "$temp_dir/certificate.pem" \
  -passout "pass:$keychain_password" \
  >/dev/null 2>&1

security create-keychain -p "$keychain_password" "$keychain_name"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$temp_dir/identity.p12" \
  -k "$keychain_path" \
  -P "$keychain_password" \
  -T /usr/bin/codesign \
  >/dev/null
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$keychain_password" \
  "$keychain_path" \
  >/dev/null
security add-trusted-cert \
  -d \
  -r trustRoot \
  -p codeSign \
  -k "$keychain_path" \
  "$temp_dir/certificate.pem"

print -r -- "$keychain_password" > "$password_file"
ditto "$temp_dir/certificate.pem" "$certificate_file"
add_keychain_to_search_list

if ! security find-identity -v -p codesigning "$keychain_path" | grep -Fq "\"$identity_name\""; then
  print -u2 "VoiceInk signing identity creation failed."
  exit 1
fi

print "Created the stable local VoiceInk signing identity."
print "Its private key remains only in: $keychain_path"
