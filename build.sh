#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
architectures=("$(uname -m)")
if [[ "${1:-}" == "--universal" ]]; then
  architectures=(arm64 x86_64)
  shift
fi
bundle_dir="${1:-$project_dir/Composer Bubbles.app}"
app_id=local.composerbubbles.mac
local_signer="Composer Bubbles Local Signing"
mkdir -p "$(dirname "$bundle_dir")"
scratch_dir="$(mktemp -d "$(dirname "$bundle_dir")/.composer-bubbles-build.XXXXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT
candidate="$scratch_dir/Composer Bubbles.app"

# A release may be built into a staging folder before the running app is replaced.
# Check both the installed copy and an existing output before changing either.
references=()
for reference in "$project_dir/Composer Bubbles.app" "$bundle_dir"; do
  [[ -e "$reference" || -L "$reference" ]] || continue
  if [[ -L "$reference" || ! -f "$reference/Contents/Info.plist" ]] ||
     [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$reference/Contents/Info.plist")" != "$app_id" ]]; then
    echo "Expected a Composer Bubbles bundle at $reference" >&2
    exit 1
  fi
  /usr/bin/codesign --verify --strict --all-architectures "$reference"
  if /usr/bin/codesign -dv --verbose=2 "$reference" 2>&1 | /usr/bin/grep -q '^Signature=adhoc$'; then
    continue  # The initial migration gets a fresh Accessibility grant from the user.
  fi
  references+=("$reference")
done

identity="${COMPOSER_BUBBLES_SIGN_IDENTITY:-}"
if [[ -z "$identity" && ${#references[@]} -gt 0 ]]; then
  /usr/bin/codesign -d --extract-certificates="$scratch_dir/previous-cert" "${references[0]}"
  identity="$(/usr/bin/shasum -a 1 "$scratch_dir/previous-cert0" | /usr/bin/awk '{ print $1 }')"
fi
local_cert="$HOME/Library/Application Support/Composer Bubbles/Signing/local-signer.der"
if [[ -z "$identity" && -f "$local_cert" ]]; then
  identity="$(/usr/bin/shasum -a 1 "$local_cert" | /usr/bin/awk '{ print $1 }')"
fi
identity="${identity:-$local_signer}"
if [[ "$identity" == "-" ]]; then
  echo "Provide a certificate-backed signing identity so updates keep the Accessibility grant." >&2
  exit 1
fi

binaries=()
for architecture in "${architectures[@]}"; do
  binary="$scratch_dir/ComposerBubbles-$architecture"
  xcrun swiftc -swift-version 5 -O -target "${architecture}-apple-macosx13.0" \
    -module-cache-path "$scratch_dir/module-cache" \
    "$project_dir"/Source/*.swift -o "$binary"
  binaries+=("$binary")
done
executable="${binaries[0]}"
if [[ "${#binaries[@]}" -gt 1 ]]; then
  executable="$scratch_dir/ComposerBubbles"
  xcrun lipo -create "${binaries[@]}" -output "$executable"
fi
mkdir -p "$candidate/Contents/MacOS"
install -m 755 "$executable" "$candidate/Contents/MacOS/ComposerBubbles"
install -m 644 "$project_dir/Info.plist" "$candidate/Contents/Info.plist"
if ! /usr/bin/codesign --force --options runtime --sign "$identity" --identifier "$app_id" "$candidate"; then
  echo "Unlock the signing keychain, or set up the Composer Bubbles signing identity as described in README.md." >&2
  exit 1
fi
/usr/bin/codesign --verify --strict --all-architectures "$candidate"
for reference in ${references[@]+"${references[@]}"}; do
  prior_requirement="$(/usr/bin/codesign -d -r- "$reference" 2>&1 |
    /usr/bin/sed -nE 's/^#? ?designated => (.+)$/\1/p')"
  if [[ -z "$prior_requirement" ]] ||
     ! /usr/bin/codesign --verify --strict --all-architectures -R "=$prior_requirement" "$candidate"; then
    echo "This update must satisfy the previous version's signing requirement." >&2
    exit 1
  fi
done

# Stage on the output volume. Publish the fully signed bundle in a single rename.
xcrun swift -module-cache-path "$scratch_dir/module-cache" - "$candidate" "$bundle_dir" <<'SWIFT'
import Darwin
let source = CommandLine.arguments[1], destination = CommandLine.arguments[2]
if renamex_np(source, destination, UInt32(RENAME_EXCL)) != 0 {
    guard errno == EEXIST, renamex_np(source, destination, UInt32(RENAME_SWAP)) == 0 else {
        perror("Publishing Composer Bubbles")
        exit(1)
    }
}
SWIFT
