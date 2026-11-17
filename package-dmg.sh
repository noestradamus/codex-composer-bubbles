#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: ./package-dmg.sh [--local-beta] [output-directory]
The default builds a universal Developer ID DMG and notarizes it with Apple.
Set COMPOSER_BUBBLES_SIGN_IDENTITY and COMPOSER_BUBBLES_NOTARY_PROFILE first.
--local-beta packages the beta-signed app in a plain DMG and a ZIP without notarization.
Set COMPOSER_BUBBLES_PREVIOUS_APP to check against a previous release's .app.
The output directory defaults to .build/release in this repository.
USAGE
}

beta=false
case "${1:-}" in
  --local-beta) beta=true; shift ;;
  --help|-h) usage; exit 0 ;;
esac
if [[ $# -gt 1 || "${1:-}" == -* ]]; then usage >&2; exit 2; fi
output_dir="${1:-$project_dir/.build/release}"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$project_dir/Info.plist")"
name="Composer-Bubbles-${version}-macOS-universal"
app_id="local.composerbubbles.mac"
identity="${COMPOSER_BUBBLES_SIGN_IDENTITY:-}"
if "$beta"; then
  name="$name-beta"
  identity="${identity:-Composer Bubbles Local Signing}"
  requirement="$(cat "$project_dir/release/beta-signing-requirement.txt")"
  [[ -n "$requirement" ]] || { echo "Missing beta signing requirement." >&2; exit 1; }
else
  : "${identity:?Set COMPOSER_BUBBLES_SIGN_IDENTITY to your Developer ID Application identity.}"
  : "${COMPOSER_BUBBLES_NOTARY_PROFILE:?Set COMPOSER_BUBBLES_NOTARY_PROFILE to your notarytool Keychain profile.}"
  requirement="identifier \"$app_id\" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
scratch="$(mktemp -d "$output_dir/.composer-bubbles-release.XXXXXXXX")"
image_root="$scratch/volume"
app="$image_root/Composer Bubbles.app"
image="$scratch/$name.dmg"
mountpoint="$scratch/mounted"
mounted=false
cleanup() {
  if "$mounted" && ! /usr/bin/hdiutil detach -quiet "$mountpoint"; then
    echo "Eject $mountpoint before removing the temporary directory $scratch." >&2
    return
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT
mkdir "$image_root" "$mountpoint"

COMPOSER_BUBBLES_PREVIOUS_APP="${COMPOSER_BUBBLES_PREVIOUS_APP:-}" \
  COMPOSER_BUBBLES_SIGN_IDENTITY="$identity" "$project_dir/build.sh" --universal "$app"
if ! /usr/bin/codesign --verify --strict --all-architectures -R "=$requirement" "$app"; then
  echo "The app signature does not match this release channel." >&2
  exit 1
fi
if ! "$beta"; then
  # codesign requests a secure timestamp by default for Developer ID signatures.
  signature="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)"
  if ! /usr/bin/grep -q '^Timestamp=' <<< "$signature"; then
    echo "The Developer ID signature requires a secure timestamp." >&2
    exit 1
  fi
fi
ln -s /Applications "$image_root/Applications"
/usr/bin/hdiutil create -quiet -format UDZO -fs HFS+ -volname "Composer Bubbles" \
  -srcfolder "$image_root" "$image"

if ! "$beta"; then
  /usr/bin/codesign --sign "$identity" --identifier "$app_id.dmg" --timestamp "$image"
  echo "Submitting $name.dmg to Apple for notarization."
  response="$scratch/notarization.plist"
  if ! xcrun notarytool submit "$image" --keychain-profile "$COMPOSER_BUBBLES_NOTARY_PROFILE" \
       --wait --output-format plist > "$response"; then
    [[ ! -s "$response" ]] || /usr/bin/plutil -p "$response" >&2
    exit 1
  fi
  status="$(/usr/bin/plutil -extract status raw -o - "$response")"
  if [[ "$status" != "Accepted" ]]; then
    /usr/bin/plutil -p "$response" >&2
    exit 1
  fi
  xcrun stapler staple "$image"
  xcrun stapler validate "$image"
  /usr/bin/codesign --verify --strict "$image"
  /usr/sbin/spctl --assess --type open --context context:primary-signature "$image"
elif /usr/bin/codesign --display "$image" >/dev/null 2>&1; then
  echo "The beta disk image must be plain. Its app carries the beta signature." >&2
  exit 1
fi

verify_packaged_app() {
  local bundle="$1" architecture
  /usr/bin/codesign --verify --strict --all-architectures -R "=$requirement" "$bundle"
  for architecture in arm64 x86_64; do
    xcrun lipo "$bundle/Contents/MacOS/ComposerBubbles" -verify_arch "$architecture"
  done
}

/usr/bin/hdiutil verify -quiet "$image"
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mountpoint" "$image"
mounted=true
verify_packaged_app "$mountpoint/Composer Bubbles.app"
[[ "$(readlink "$mountpoint/Applications")" == /Applications ]]
/usr/bin/hdiutil detach -quiet "$mountpoint"
mounted=false

packages=("$name.dmg")
if "$beta"; then
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$scratch/$name.zip"
  /usr/bin/ditto -x -k "$scratch/$name.zip" "$scratch/unpacked"
  verify_packaged_app "$scratch/unpacked/Composer Bubbles.app"
  packages+=("$name.zip")
fi
for file in "${packages[@]}"; do
  (cd "$scratch" && /usr/bin/shasum -a 256 "$file" > "$file.sha256")
done
for file in "${packages[@]}"; do
  mv -f "$scratch/$file" "$scratch/$file.sha256" "$output_dir/"
  echo "$output_dir/$file"
  echo "$output_dir/$file.sha256"
done
