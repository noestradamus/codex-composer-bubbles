# Publishing a Mac release

Public downloads are universal DMGs for Apple silicon and Intel. Recipients install the app in Applications and grant Accessibility on first use. Only the machine building a release needs a signing identity.

## Public beta

Bump both version fields in `Info.plist` and run `./Tests/run.sh`. On the Mac that holds the original beta signing key, package the new release using the app from the previous beta DMG as the reference.

```sh
COMPOSER_BUBBLES_PREVIOUS_APP="/Volumes/Composer Bubbles/Composer Bubbles.app" \
  ./package-dmg.sh --local-beta ./dist
```

For the first beta, omit `COMPOSER_BUBBLES_PREVIOUS_APP`. The packager checks that the app satisfies the project's pinned beta signing requirement. A newly created local signing identity will fail this check. Keep the original signing key available for future beta updates.

The project certificate signs the app. The beta packager puts that app in a plain read-only DMG and a Finder-compatible ZIP. A local certificate on the outer disk image can cause Gatekeeper to block the mount before Finder can present the app.

Before publishing, open a fresh browser download of the DMG in Finder and confirm that the volume mounts. Test a first launch on a Mac without an existing approval when available. Tag the tested source commit and attach both packages and their SHA-256 files to a GitHub **pre-release**. State that the beta app is self-signed and macOS may ask for a first-launch exception. To verify a download, run `shasum -a 256 -c` followed by its checksum filename from the folder containing both files.

## Apple-notarized release

Use an Apple **Developer ID Application** identity in the signing Mac’s keychain. Set up a notarytool keychain profile with your Apple Developer credentials. Only the signing identity name and profile name are passed to the build. [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

```sh
COMPOSER_BUBBLES_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
COMPOSER_BUBBLES_NOTARY_PROFILE="composer-bubbles-notary" \
  ./package-dmg.sh ./dist
```

Keep the bundle ID and Apple Developer team consistent. For subsequent notarized updates, set `COMPOSER_BUBBLES_PREVIOUS_APP` to the app from the previous notarized release. On the first transition from the self-signed beta, tell users macOS may ask them to grant Accessibility once for the new signing identity. [How macOS recognizes a signed update](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
