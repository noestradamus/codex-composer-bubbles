#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/composer-bubbles-tests.XXXXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT

for test in StoreIsolationChecks NumberChecks; do
  xcrun swiftc -swift-version 5 -module-cache-path "$scratch_dir/module-cache" \
    "$project_dir/Source/BubbleStore.swift" "$project_dir/Tests/$test.swift" -o "$scratch_dir/$test"
  "$scratch_dir/$test"
done

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$scratch_dir/module-cache" \
  "$project_dir/Source/LocalChatCatalog.swift" "$project_dir/Tests/ChatCatalogChecks.swift" -o "$scratch_dir/ChatCatalogChecks"
"$scratch_dir/ChatCatalogChecks"

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$scratch_dir/module-cache" \
  "$project_dir"/Source/{BubbleStyle,BubbleGlass,GlassTabDrawing,SaveButtonDrawing,ShelfPlacement,CodexWindowGeometry}.swift \
  "$project_dir"/Tests/{EmptyShelfChecks,DisplayPlacementChecks,WindowPlacementChecks,WindowInventoryChecks,SaveConfirmationChecks}.swift -o "$scratch_dir/EmptyShelfChecks"
"$scratch_dir/EmptyShelfChecks"
