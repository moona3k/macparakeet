# Distribution (Developer ID + Notarization)

This repo is SwiftPM-based, so we assemble a `.app` bundle manually for Developer ID distribution.

## 1) Build the app bundle

From the repo root:

```bash
scripts/dist/build_app_bundle.sh
```

This creates `dist/MacParakeet.app` and bundles:
- `Assets/AppIcon.icns` into `Contents/Resources/AppIcon.icns` (app icon for Dock, Finder, DMG)
- SwiftPM resource bundles into `Contents/Resources/`
- Standalone helper binaries (yt-dlp and FFmpeg) into `Contents/Resources/` when configured by the build scripts
- No Python runtime or `uv` bootstrap is bundled (FluidAudio/CoreML STT is native Swift)

`build_app_bundle.sh` enforces a **portable** FFmpeg binary (no non-system dylib dependencies). If your default Homebrew FFmpeg is Cellar-linked, set `FFMPEG_PATH` explicitly:

```bash
FFMPEG_PATH=/absolute/path/to/portable-ffmpeg scripts/dist/build_app_bundle.sh
```

Quick portability check:

```bash
otool -L /absolute/path/to/portable-ffmpeg | grep -Ev '^/System/Library/|^/usr/lib/' || true
```

Expected: no output from the command above.

Optional licensing config (recommended for production):

```bash
export MACPARAKEET_CHECKOUT_URL="https://..."
export MACPARAKEET_LS_VARIANT_ID="12345"
scripts/dist/build_app_bundle.sh
```

These are embedded into `Info.plist` as:
- `MacParakeetCheckoutURL`
- `MacParakeetLemonSqueezyVariantID`

## 2) Sign + notarize (recommended)

Prereqs:
- A **Developer ID Application** certificate in Keychain.
- `notarytool` credentials stored in Keychain under the profile `AC_PASSWORD` (shared with Oatmeal):

```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "moona3k@gmail.com" \
  --team-id "FYAF2ZD7RM" \
  --password "app-specific-password"
```

Verify credentials work:

```bash
xcrun notarytool history --keychain-profile "AC_PASSWORD"
```

Then:

```bash
NOTARYTOOL_PROFILE="AC_PASSWORD" scripts/dist/sign_notarize.sh
```

Outputs:
- `dist/MacParakeet.app` (signed + stapled)
- `dist/MacParakeet.dmg` (signed + stapled)

## 3) Upload to Cloudflare R2

The signed DMG is hosted on Cloudflare R2 at `downloads.macparakeet.com`.

**Bucket:** `macparakeet-downloads` (Cloudflare R2)
**Custom domain:** `downloads.macparakeet.com`
**Public URL:** `https://downloads.macparakeet.com/MacParakeet.dmg`

Upload a new release:

```bash
npx wrangler r2 object put macparakeet-downloads/MacParakeet.dmg \
  --file dist/MacParakeet.dmg \
  --content-type "application/x-apple-diskimage" \
  --remote
```

Verify:

```bash
curl -sI https://downloads.macparakeet.com/MacParakeet.dmg | head -5
```

Because Cloudflare may serve a cached object briefly, also verify with a cache-busting query:

```bash
curl -sI "https://downloads.macparakeet.com/MacParakeet.dmg?ts=$(date +%s)" | head -10
```

Confirm `content-length`, `last-modified`, and `etag` match the newly uploaded DMG.

## Full release workflow

```bash
# 1. Build app bundle (ALLOW_NON_PORTABLE_FFMPEG=1 if using Homebrew ffmpeg)
ALLOW_NON_PORTABLE_FFMPEG=1 scripts/dist/build_app_bundle.sh

# 2. Sign + notarize (creates .app and .dmg)
NOTARYTOOL_PROFILE="AC_PASSWORD" scripts/dist/sign_notarize.sh

# 3. Upload DMG to R2
npx wrangler r2 object put macparakeet-downloads/MacParakeet.dmg \
  --file dist/MacParakeet.dmg \
  --content-type "application/x-apple-diskimage" \
  --remote

# 4. Verify fresh object metadata (cache-busted HEAD)
curl -sI "https://downloads.macparakeet.com/MacParakeet.dmg?ts=$(date +%s)" | head -10

# 5. Website download buttons already point to:
#    https://downloads.macparakeet.com/MacParakeet.dmg
```

## Notes

- The scripts default to a single-arch Release build. For a universal binary:

```bash
UNIVERSAL=1 scripts/dist/build_app_bundle.sh
```

- `MacParakeet` requests microphone permission. The app bundle `Info.plist` includes `NSMicrophoneUsageDescription`.
- **Users must install to /Applications before launching.** Running directly from a mounted DMG (`/Volumes/MacParakeet/`) will not register with macOS TCC — the app won't appear in System Settings > Privacy & Security > Microphone, and permission requests will silently fail. The DMG includes an Applications symlink for drag-to-install.
- If a user's microphone permission gets stuck as "Denied", reset it with: `tccutil reset Microphone com.macparakeet.MacParakeet`
- The Cloudflare R2 bucket uses a custom domain via `wrangler r2 bucket domain add`. The `r2.dev` public URL is also enabled as a fallback.
- Cloudflare Pages has a 25MB file size limit, so the DMG (27MB) cannot be hosted directly in the website repo's `public/` folder.
