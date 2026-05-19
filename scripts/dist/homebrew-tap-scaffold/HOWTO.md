# How to release `macparakeet-cli` through Homebrew

This file lives in the macparakeet repo for reference. The tap repo
itself is a separate GitHub repository.

## One-time tap setup

### 1. Create the tap repo on GitHub

```bash
gh repo create moona3k/homebrew-tap --public \
  --description "Homebrew tap for moona3k packages (macparakeet-cli, ...)"
```

Local clone + initial commit:

```bash
git clone https://github.com/moona3k/homebrew-tap ~/code/homebrew-tap
cd ~/code/homebrew-tap
mkdir -p Formula
cp ~/code/macparakeet/scripts/dist/homebrew-tap-scaffold/README.md .
cp ~/code/macparakeet/scripts/dist/homebrew-tap-scaffold/macparakeet-cli.rb Formula/
# Edit README.md — strip the leading "scaffold" preamble.
```

Don't push the tap yet — the formula's `sha256` field is a placeholder
until the release tarball exists (next steps).

## Cutting a CLI release

The examples below use the current release version; update it before each
release:

```bash
export VERSION=2.3.0
```

### 2. Build the standalone CLI binary

In the macparakeet repo, from the commit you intend to tag:

```bash
swift build -c release --product macparakeet-cli
mkdir -p "dist/macparakeet-cli-${VERSION}-darwin-arm64"
cp .build/release/macparakeet-cli "dist/macparakeet-cli-${VERSION}-darwin-arm64/"
```

### 3. Sign + notarize the binary

Use the same Developer ID identity already set up for the `.app`. The
exact identity is in `scripts/dist/sign_notarize.sh`.

```bash
codesign --sign "Developer ID Application: <YOUR NAME> (<TEAMID>)" \
         --options runtime \
         --timestamp \
         "dist/macparakeet-cli-${VERSION}-darwin-arm64/macparakeet-cli"

# Pack for notarization
ditto -c -k --keepParent "dist/macparakeet-cli-${VERSION}-darwin-arm64" \
      "dist/macparakeet-cli-${VERSION}-darwin-arm64.zip"
shasum -a 256 "dist/macparakeet-cli-${VERSION}-darwin-arm64.zip" \
  | tee "dist/macparakeet-cli-${VERSION}-darwin-arm64.zip.sha256"

# Submit. The notarytool keychain profile name is whatever was set up
# previously (search scripts/dist/ for the actual name).
xcrun notarytool submit "dist/macparakeet-cli-${VERSION}-darwin-arm64.zip" \
      --keychain-profile <profile-name>
```

Poll the returned submission ID with
`xcrun notarytool info <id> --keychain-profile <profile>` until it reads
`Accepted`. Do not use `notarytool submit --wait`; the app release pipeline
avoids it because it can SIGBUS-crash on some macOS/Xcode combinations.

### 4. Tar + checksum

```bash
cd dist
COPYFILE_DISABLE=1 tar -czf "macparakeet-cli-${VERSION}-darwin-arm64.tar.gz" \
        "macparakeet-cli-${VERSION}-darwin-arm64"
shasum -a 256 "macparakeet-cli-${VERSION}-darwin-arm64.tar.gz" \
  | tee "macparakeet-cli-${VERSION}-darwin-arm64.tar.gz.sha256"
# Copy the SHA256 hex into the formula's `sha256` field.
```

### 5. Publish the GitHub release

```bash
gh release create "cli-v${VERSION}" \
  "dist/macparakeet-cli-${VERSION}-darwin-arm64.tar.gz" \
  "dist/macparakeet-cli-${VERSION}-darwin-arm64.tar.gz.sha256" \
  "dist/macparakeet-cli-${VERSION}-darwin-arm64.zip" \
  "dist/macparakeet-cli-${VERSION}-darwin-arm64.zip.sha256" \
  --title "macparakeet-cli ${VERSION}" \
  --notes-file <release-notes.md>
```

Tag pattern: `cli-v<major>.<minor>.<patch>` — keeps CLI tags distinct
from the app's release tags.

### 6. Push the tap

```bash
cd ~/code/homebrew-tap
# Update Formula/macparakeet-cli.rb's `sha256` line with the value from step 4.
git add Formula/macparakeet-cli.rb
git commit -m "macparakeet-cli ${VERSION}"
git push
```

### 7. Verify end-to-end

```bash
brew untap moona3k/tap 2>/dev/null   # if previously tapped
brew tap moona3k/tap
brew install macparakeet-cli

macparakeet-cli --version    # 2.3.0
macparakeet-cli health --json
```

## After the first release

For each subsequent CLI release:

1. Bump `version` in `Sources/CLI/MacParakeetCLI.swift`.
2. Add an entry to `Sources/CLI/CHANGELOG.md` per semver discipline.
3. Repeat steps 2–6 above with the new version number.

Bottle support (faster install via pre-built `.bottle.tar.gz` per macOS
version) is a later phase. Homebrew CI can build bottles automatically;
see `brew tap-new --pull-label` and the Homebrew bottles docs.

## Why this approach

- **Pre-built signed binary** rather than `swift build` in the formula:
  faster install (no ~30s SwiftPM compile), no need for users to have
  Xcode CLT, simpler caveats. Recommended in the canonical plan at
  `plans/active/cli-as-canonical-parakeet-surface.md`.
- **Tap separate from main repo:** keeps Homebrew's expected layout
  (`Formula/<name>.rb`), allows future formulae (`macparakeet-cli`,
  potentially other tools) to share infrastructure.
- **Keeping FFmpeg + yt-dlp as `depends_on`** rather than bundling:
  smaller release tarball, lets users keep one canonical FFmpeg, lets
  brew handle dep upgrades.
