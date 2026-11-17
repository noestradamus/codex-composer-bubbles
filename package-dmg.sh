#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: ./package-dmg.sh [--local-beta] [output-directory]
The default builds a universal Developer ID DMG and notarizes it with Apple.
Set COMPOSER_BUBBLES_SIGN_IDENTITY and COMPOSER_BUBBLES_NOTARY_PROFILE first.
--local-beta uses the pinned beta signing certificate and skips notarization.
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
image_sign=(--identifier "$app_id.dmg")
if "$beta"; then
  name="$name-beta"
  identity="${identity:-Composer Bubbles Local Signing}"
  requirement="$(cat "$project_dir/release/beta-signing-requirement.txt")"
  [[ -n "$requirement" ]] || { echo "Missing beta signing requirement." >&2; exit 1; }
else
  : "${identity:?Set COMPOSER_BUBBLES_SIGN_IDENTITY to your Developer ID Application identity.}"
  : "${COMPOSER_BUBBLES_NOTARY_PROFILE:?Set COMPOSER_BUBBLES_NOTARY_PROFILE to your notarytool Keychain profile.}"
  requirement="identifier \"$app_id\" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
  image_sign+=(--timestamp)
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
/usr/bin/codesign --sign "$identity" "${image_sign[@]}" "$image"

if ! "$beta"; then
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
  /usr/sbin/spctl --assess --type open --context context:primary-signature "$image"
fi

/usr/bin/codesign --verify --strict "$image"
/usr/bin/hdiutil verify -quiet "$image"
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mountpoint" "$image"
mounted=true
mounted_app="$mountpoint/Composer Bubbles.app"
/usr/bin/codesign --verify --strict --all-architectures -R "=$requirement" "$mounted_app"
for architecture in arm64 x86_64; do
  xcrun lipo "$mounted_app/Contents/MacOS/ComposerBubbles" -verify_arch "$architecture"
done
[[ "$(readlink "$mountpoint/Applications")" == /Applications ]]
/usr/bin/hdiutil detach -quiet "$mountpoint"
mounted=false

(cd "$scratch" && /usr/bin/shasum -a 256 "$name.dmg" > "$name.dmg.sha256")
mv -f "$image" "$scratch/$name.dmg.sha256" "$output_dir/"
echo "$output_dir/$name.dmg"
echo "$output_dir/$name.dmg.sha256"
