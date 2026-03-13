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

`build_app_bundle.sh` automatically downloads a **statically-linked FFmpeg** from [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de/) (macOS arm64, SHA256-verified). No Homebrew dependency. To use a custom binary instead, set `FFMPEG_PATH`:

```bash
FFMPEG_PATH=/absolute/path/to/static-ffmpeg scripts/dist/build_app_bundle.sh
```

The script verifies the bundled binary has no non-system dylib dependencies (portability check via `otool -L`).

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

**IMPORTANT:** Follow these steps in exact order. Do NOT re-upload the DMG after signing for Sparkle — the file size must match the appcast signature. If another agent is running a parallel build, coordinate to avoid overwriting the R2 object.

### Step 1: Build

```bash
scripts/dist/build_app_bundle.sh
```

Verify: Look for `Embedded Sparkle.framework` and `Adding @executable_path/../Frameworks to rpath` in the output. The script will `exit 1` if Sparkle is missing.

### Step 2: Sign + notarize

```bash
scripts/dist/sign_notarize.sh
```

The script defaults `NOTARYTOOL_PROFILE` to `AC_PASSWORD`. Both app and DMG are signed, notarized, and stapled. Wait for both "Accepted" statuses.

Verify:
```bash
spctl --assess --type execute --verbose=4 dist/MacParakeet.app
# Expected: "accepted / source=Notarized Developer ID"
```

### Step 3: Upload DMG to R2

```bash
npx wrangler r2 object put macparakeet-downloads/MacParakeet.dmg \
  --file dist/MacParakeet.dmg \
  --content-type "application/x-apple-diskimage" \
  --remote
```

Verify — **the file size MUST match `dist/MacParakeet.dmg` exactly:**
```bash
LOCAL_SIZE=$(stat -f%z dist/MacParakeet.dmg)
REMOTE_SIZE=$(curl -sI "https://downloads.macparakeet.com/MacParakeet.dmg?ts=$(date +%s)" | grep -i content-length | awk '{print $2}' | tr -d '\r')
echo "Local: $LOCAL_SIZE  Remote: $REMOTE_SIZE"
# These MUST be identical. If not, re-upload — another process may have overwritten the object.
```

### Step 4: Sign DMG for Sparkle

```bash
.build/artifacts/sparkle/Sparkle/bin/sign_update dist/MacParakeet.dmg
```

This outputs two values you need for the appcast:
```
sparkle:edSignature="..." length="..."
```

**The `length` must match the R2 `content-length` from Step 3.** If they differ, something went wrong — do NOT proceed.

### Step 5: Update appcast.xml

Edit `~/code/macparakeet-website/public/appcast.xml`. Add a new `<item>` (or update existing) with:
- `sparkle:version` = build number from `dist/MacParakeet.app/Contents/Info.plist` (`CFBundleVersion`)
- `sparkle:shortVersionString` = version from Info.plist (`CFBundleShortVersionString`)
- `sparkle:edSignature` and `length` from Step 4
- `pubDate` in RFC 2822 format: `date -R`
- Release notes in `<description>` CDATA block

Get build info:
```bash
plutil -p dist/MacParakeet.app/Contents/Info.plist | grep -E "CFBundleVersion|CFBundleShortVersionString"
```

### Step 6: Deploy website

```bash
cd ~/code/macparakeet-website
git add public/appcast.xml
git commit -m "Update appcast.xml with vX.Y.Z build BUILDNUMBER"
git push
# Then deploy to Cloudflare Pages:
npx astro build && npx wrangler pages deploy dist --project-name macparakeet-website --branch main
```

Verify appcast is live:
```bash
curl -s "https://macparakeet.com/appcast.xml?ts=$(date +%s)" | grep "sparkle:version"
```

### Step 7: Verify end-to-end

1. Confirm R2 file size matches appcast `length`
2. Confirm appcast `sparkle:version` is newer than the installed app's build number
3. Launch the app → "Check for Updates..." from the menu bar → should find and validate the update

### Quick reference (copy-paste)

```bash
# Full pipeline — run from macparakeet repo root
scripts/dist/build_app_bundle.sh
scripts/dist/sign_notarize.sh
npx wrangler r2 object put macparakeet-downloads/MacParakeet.dmg \
  --file dist/MacParakeet.dmg --content-type "application/x-apple-diskimage" --remote
.build/artifacts/sparkle/Sparkle/bin/sign_update dist/MacParakeet.dmg
# → Edit ~/code/macparakeet-website/public/appcast.xml with signature + build info
# → cd ~/code/macparakeet-website && git add -A && git commit && git push
# → npx astro build && npx wrangler pages deploy dist --project-name macparakeet-website --branch main
# → Verify: curl -s "https://macparakeet.com/appcast.xml?ts=$(date +%s)" | grep sparkle:version
```

### Common pitfalls

| Problem | Cause | Fix |
|---------|-------|-----|
| App crashes at launch (dyld) | Sparkle.framework missing from bundle | Build script should catch this. If bypassed, re-run `build_app_bundle.sh` |
| "Improperly signed" update error | R2 file doesn't match appcast signature | Re-upload the **exact same DMG** you ran `sign_update` on. Verify sizes match |
| Appcast not updating | Cloudflare Pages cache / build not triggered | Deploy manually: `npx wrangler pages deploy dist --project-name macparakeet-website` |
| `notarytool` auth failure | Keychain profile missing | Run `xcrun notarytool store-credentials "AC_PASSWORD"` (see Step 2 above) |
| Update found but same version | Build number in appcast ≤ installed build | Ensure `sparkle:version` (build number) is strictly greater |

## Auto-Updates (Sparkle)

MacParakeet uses [Sparkle 2](https://sparkle-project.org/) for in-app auto-updates. Users are prompted when a new version is available — no manual DMG download needed.

### How it works

1. On launch, Sparkle checks `https://macparakeet.com/appcast.xml` for new versions
2. If a newer version exists, a native update dialog appears
3. User clicks "Install Update" → Sparkle downloads the DMG, replaces the app, relaunches

### EdDSA signing keys

The private key is stored in the developer's macOS Keychain (generated once via `generate_keys`). The public key is embedded in `Info.plist` as `SUPublicEDKey`.

To retrieve the public key or verify the Keychain entry:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

### Appcast

The appcast XML lives in the [macparakeet-website](https://github.com/moona3k/macparakeet-website) repo at `public/appcast.xml` and is served at `https://macparakeet.com/appcast.xml`.

Template for a new release:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MacParakeet Updates</title>
    <item>
      <title>Version X.Y.Z</title>
      <link>https://macparakeet.com</link>
      <sparkle:version>BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>X.Y.Z</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <h2>What's New</h2>
        <ul>
          <li>Feature or fix description</li>
        </ul>
      ]]></description>
      <pubDate>DATE_RFC2822</pubDate>
      <enclosure
        url="https://downloads.macparakeet.com/MacParakeet.dmg"
        sparkle:edSignature="SIGNATURE_FROM_SIGN_UPDATE"
        length="FILE_SIZE_BYTES"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
```

### Signing an update

```bash
# Sign the DMG and get the signature + length for appcast.xml
.build/artifacts/sparkle/Sparkle/bin/sign_update dist/MacParakeet.dmg
```

This outputs `sparkle:edSignature="..."` and `length="..."` — paste both into the appcast `<enclosure>` element.

### Auto-generate appcast from a directory of releases

```bash
# Place all versioned DMGs in a directory, then:
.build/artifacts/sparkle/Sparkle/bin/generate_appcast /path/to/releases/
```

This generates/updates `appcast.xml` with signatures and optional delta updates.

### Info.plist keys

These are set automatically by `build_app_bundle.sh`:

| Key | Value |
|-----|-------|
| `SUFeedURL` | `https://macparakeet.com/appcast.xml` |
| `SUPublicEDKey` | `2aqRU0Agz+xxZwt0kLybmKz/SAvZUsyn+z9fU0I6ynY=` |

### Settings UI

Users can control auto-update behavior in Settings > Updates:
- Toggle automatic update checks
- Toggle automatic update downloads
- Manual "Check for Updates..." button

"Check for Updates..." is also available in the app menu and menu bar dropdown.

## Notes

- **Sparkle.framework must be embedded in the .app bundle.** The `build_app_bundle.sh` script copies it to `Contents/Frameworks/`. If the framework is missing, the app will crash immediately at launch with a dyld `Library not loaded: @rpath/Sparkle.framework` error. The script now fails the build if Sparkle.framework cannot be found — do not bypass this check.
- The scripts default to a single-arch Release build. For a universal binary:

```bash
UNIVERSAL=1 scripts/dist/build_app_bundle.sh
```

- `MacParakeet` requests microphone permission. The app bundle `Info.plist` includes `NSMicrophoneUsageDescription`.
- **Users must install to /Applications before launching.** Running directly from a mounted DMG (`/Volumes/MacParakeet/`) will not register with macOS TCC — the app won't appear in System Settings > Privacy & Security > Microphone, and permission requests will silently fail. The DMG includes an Applications symlink for drag-to-install.
- If a user's microphone permission gets stuck as "Denied", reset it with: `tccutil reset Microphone com.macparakeet.MacParakeet`
- The Cloudflare R2 bucket uses a custom domain via `wrangler r2 bucket domain add`. The `r2.dev` public URL is also enabled as a fallback.
- Cloudflare Pages has a 25MB file size limit, so the DMG (27MB) cannot be hosted directly in the website repo's `public/` folder.
