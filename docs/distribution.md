# Distribution (Developer ID + Notarization)

This repo is SwiftPM-based, so we assemble a `.app` bundle manually for Developer ID distribution.

## 1) Build the app bundle

From `app/`:

```bash
scripts/dist/build_app_bundle.sh
```

This creates `app/dist/MacParakeet.app` and bundles:
- `python/macparakeet_stt` into `Contents/Resources/python/`
- `uv` into `Contents/Resources/uv` if `uv` is on your `PATH`

## 2) Sign + notarize (recommended)

Prereqs:
- A **Developer ID Application** certificate in Keychain.
- `notarytool` credentials stored in Keychain:

```bash
xcrun notarytool store-credentials "macparakeet-notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

Then:

```bash
export NOTARYTOOL_PROFILE="macparakeet-notary"
scripts/dist/sign_notarize.sh
```

Outputs:
- `app/dist/MacParakeet.app` (signed + stapled)
- `app/dist/MacParakeet.dmg` (signed + stapled)

## Notes

- The scripts default to a single-arch Release build. For a universal binary:

```bash
UNIVERSAL=1 scripts/dist/build_app_bundle.sh
```

- `MacParakeet` requests microphone permission. The app bundle `Info.plist` includes `NSMicrophoneUsageDescription`.

