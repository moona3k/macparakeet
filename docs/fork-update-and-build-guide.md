# Fork guide: update from upstream, push, and build for your Mac

> Building in Xcode, the Keychain error, troubleshooting, and adding features:
> see [`fork-developer-guide.md`](./fork-developer-guide.md).

Remotes in this checkout:

- `origin` = upstream project (`moona3k/macparakeet`) - pull updates from here.
- `fork` = your copy (`rtsysEmbedded/macparakeet`) - push your work here.

Work on branch `feature/transcript-translation`. Keep the working tree clean
(commit or stash first).

## 1. Update your branch with the latest upstream

```bash
git fetch origin
git rev-list --left-right --count HEAD...origin/main   # left = yours, right = upstream-only
git merge origin/main
```

If there are conflicts, `git status` lists files marked `UU`. Open each, find
`<<<<<<<`, `=======`, `>>>>>>>`, keep both sides' intent (upstream's new code
plus your feature lines), delete the markers, then:

```bash
grep -rnE '^(<<<<<<<|>>>>>>>)' Sources Tests spec   # must print nothing
git add -A Sources Tests spec
git commit --no-edit
```

Last time the conflicts were in `TranscriptResultView.swift` (upstream re-indented
the summary buttons; the fix was to keep upstream's layout and re-add the
`resultTranslateMenu(for: promptResult)` line) and in
`spec/adr/032-llm-task-group-routing.md` (keep upstream's formatter line plus
the translation bullets).

## 2. Test the areas you touched

Use focused tests, not the full suite:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --filter 'DictationTranslationTests|LiveCaptionSessionTests|CloudSTTModelCatalogTests|CloudTranscribeEngineTests|RealtimeTranscribeEngineTests|DictationHistoryViewModelTests|LLMServiceTests|DatabaseManagerTests|TranscriptTranslation'
```

## 3. Push to your fork

```bash
git push fork feature/transcript-translation
```

Optional - make your fork's `main` match (a plain fast-forward):

```bash
git push fork feature/transcript-translation:main
git branch -f main HEAD
```

The first push asks for a GitHub username and a personal access token
(classic, `repo` scope); macOS Keychain remembers it afterwards. An open pull
request (moona3k/macparakeet#1260) updates automatically when you push the branch.

## 4. Build the app for your Mac

Requirements: Xcode installed in `/Applications`, and Node.js + npm (24.13.1 is
what the project pins). `xcode-select` points at the Command Line Tools on this
Mac, so select Xcode per command with `DEVELOPER_DIR` (no sudo needed).

If Node is not installed, download the official tarball once and put it on PATH
for the build only:

```bash
mkdir -p ~/tools/node && cd ~/tools/node
curl -LO https://nodejs.org/dist/v24.13.1/node-v24.13.1-darwin-arm64.tar.gz
tar xzf node-v24.13.1-darwin-arm64.tar.gz
```

Build:

```bash
cd ~/projects/macparakeet
PATH="$HOME/tools/node/node-v24.13.1-darwin-arm64/bin:$PATH" \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
scripts/dist/build_app_bundle.sh
```

Takes a few minutes and produces `dist/MacParakeet.app`. Set `VERSION=X.Y.Z` in
front of the command to stamp a version (default shows 0.0.0).

## 5. Sign it locally (needed to run)

The release certificate belongs to the original author, so sign ad hoc, the same
way `scripts/dev/run_app.sh` does:

```bash
E=$(mktemp -t ent) && cp scripts/dist/MacParakeet.entitlements "$E"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$E"
codesign --force --sign - --options runtime --entitlements "$E" --deep dist/MacParakeet.app
rm -f "$E"
codesign --verify --deep --strict dist/MacParakeet.app && echo VERIFIED
```

## 6. Install

Drag `dist/MacParakeet.app` into `/Applications`. First launch: right-click ->
Open. Grant microphone and accessibility permissions again. The build is not
notarized, so it only runs on your own Mac, and the built-in updater will not
work - repeat this guide to update.

## Troubleshooting

- `xcodebuild requires Xcode` -> set `DEVELOPER_DIR` as above.
- `Building Ask requires Node.js and npm` -> put Node on PATH (step 4).
- `code has no resources but signature indicates they must be present` -> run step 5.
- `gh` fails with "bad CPU type" -> it is an Intel build; download the
  `macOS_arm64` zip from https://github.com/cli/cli/releases.
