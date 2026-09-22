# Historical browser extension experiment — not part of MacParakeet

**Retired on 2026-09-19.** Voice Control uses native macOS Accessibility, including the current browser. Users do not install an extension, register a native host, pair a tab, or restart their browser. This directory preserves an earlier experiment and its qualification evidence only.

The Swift implementation and tests are archived in [historical-browser-extension](../../docs/research/2026-09-19-jev-voice-control/historical-browser-extension/README.md); its executable target and app packaging were removed. Do not follow the historical setup instructions below for the current product. Existing user browser installations and settings were left untouched.

---

# Original experimental notes

This optional Chromium Manifest V3 extension connects an explicitly chosen tab to MacParakeet. Speech recognition and Jev credentials remain in the native app. The extension observes visible controls, executes typed operations, and returns effect receipts. It does not run model-generated JavaScript and does not use CDP.

## Setup

The dev and distribution app builders embed `macparakeet-browser-host` in `Contents/MacOS` and the unpacked extension in `Contents/Resources/VoiceControlBrowser`. Distribution signing already signs every auxiliary executable in `Contents/MacOS`. No helper starts merely because it is bundled.

1. Open **Voice Control → Setup** in a complete MacParakeet build. Choose **Open extension folder**.
2. Open the browser's extensions page, enable Developer mode, and choose **Load unpacked** for that folder. Copy the resulting extension ID.
3. Return to Voice Control setup, select the matching browser, enter its exact extension ID, and register it. Registration writes only user-scoped files; it never launches or restarts the browser. An explicit **Replace existing pairing** choice is required to change a different paired extension.
4. Enable the browser bridge in Voice Control. Open the extension popup in the intended tab and choose **Connect this tab**.
5. Use the native Voice Control UI. **Disconnect** in the extension ends browser authorization. Selecting another tab or navigating to a different origin disconnects. Same-origin navigation invalidates old observations and binds the new document automatically.

Registration keeps the secret in a private mode-0600 file, checks ownership and symlinks, stages both files before publishing, and holds the same exclusive lock as the running bridge. Disconnect the bridge before reconfiguration. A repeated registration for the same extension preserves its secret and updates the owned native-host executable path when the app moves. An unrelated registration is preserved even when replacement is selected.

This removes terminal-only setup, but still uses an unpacked extension. Chrome Web Store publication, a stable published extension ID, and compatibility qualification across browser channels remain separate release work. Loading the extension from an app bundle requires keeping that app at its registered location; repeat registration after moving it.

For developer automation, build `swift build --product macparakeet-browser-host` and run `python3 integrations/voice-control-browser/install.py --extension-id YOUR_EXTENSION_ID --host /absolute/path/to/macparakeet-browser-host`. Optional `--browser chromium` or `--browser chrome-for-testing` changes the registration directory. `--user-data-dir` supports an explicit disposable/custom browser profile. The script preserves existing configuration; the native setup UI owns deliberate replacement. After an abnormal termination, the app recovers only an owned private stale socket whose listener refuses connections. An exclusive bridge lock and file identity checks protect live listeners and parallel worktrees. Symlinks, nonowned paths, and regular files are never unlinked.

## Protocol and authority

The service worker uses `runtime.connectNative('com.macparakeet.voice_control')`. Chrome launches a small host process whose standard input/output use 32-bit native-byte-order length prefixes followed by UTF-8 JSON. Application frames are limited to 256 KiB in both directions.

The host verifies Chrome's caller-origin argument against the exact paired extension ID, then authenticates to the native app with a randomly generated secret from a mode-0600 file. The private socket directory is mode 0700 and socket mode 0600. The app replies with `hostReady` only after authentication. The pairing secret and Jev key are never sent to the extension. This is a same-user local trust boundary; it does not defend against malware already controlling the user's account.

The extension explicitly sends `authorize` with a context comprising its profile installation UUID, window, tab, document, and a fresh authorization nonce. The app issues a session ID. Each `observe` or `execute` has a request ID, session/context, and deadline. Replies echo session/request identity. Navigation sends `invalidate` before rebinding; old pending requests are rejected. Disconnect discards all pending continuations.

Execution requires a current observation UUID and an offered target/operation. The isolated content script consumes the observation before effects, retains the actual DOM node, and rechecks connection, semantic fingerprint, value/selection, enabled state, visibility, and occlusion. Secure/password/file/hidden/one-time-code fields are excluded before value reads. Observations carry explicit completeness and text-truncation flags. No page `postMessage` channel exists.

The native authority check is serialized with socket dispatch. An already dispatched remote effect cannot be unsent by Stop. Remote execution expires after 750 ms; cancellation sends revocation, and missing acknowledgements produce an **unknown** receipt rather than a retry. This boundary must be reflected in the UI. Browser presses with a meaningful observed control/dialog/status/navigation change return **transitionObserved**, allowing a new observation without claiming task success. Presses with no such evidence return **unknown** and pause rather than repeat.

## Supported operations and limits

- Visible buttons/links, ordinary text fields, select options, page scroll, open shadow roots.
- Exact field replacement and insertion at a known selection; focus state and selected text are included for native direct-command routing.
- Top document only. Cross-origin frames, closed shadow roots, offscreen controls, rich editor insertion, file pickers, secure fields, arbitrary key shortcuts, and native dialogs are not exposed as supported operations.
- Dynamic elements are discovered on every observation. Node numbers never become persistent selectors.
- No background-tab automation: dispatch checks the bound tab is active in the focused browser window.
- Native AX remains available without pairing. After browser selection, losing authorization never silently redirects the command to a different native app.

## Verification

`tests/dom.test.cjs` runs real DOM interactions through Playwright with a mocked extension message entrypoint. It verifies secure-field exclusion, exact fill, consume-once execution, stale-value rejection, option selection, removed targets, occlusion, expired dispatch, and wrong-document rejection. It does **not** by itself qualify Chrome's native-host installation or an end-to-end microphone session.

Install Playwright in your test environment, then run:

```sh
node integrations/voice-control-browser/tests/dom.test.cjs
swift test --filter VoiceControlBrowserWireTests
```

The DOM script defaults to an installed Chrome channel. `PLAYWRIGHT_CHANNEL` changes the channel; `PLAYWRIGHT_MODULE` can name an existing Playwright module path without modifying the repository's dependencies. Framing tests cover ordered frame boundaries, oversized headers/output, empty frames, and partial-frame EOF. Keep native-host stdout exclusively framed; diagnostics belong on stderr and must omit page content.


The end-to-end synthetic fixture is `tests/live-browser.test.cjs`, with its exact-production-source Swift driver in `tests/BrowserQualification.swift`. It requires `MACPARAKEET_BROWSER_FIXTURE_QUALIFICATION=1`, `JEV_API_KEY`, and `BROWSER_QUALIFICATION_BINARY`; `BROWSER_HOST_BINARY` defaults to the debug product. `CHROMIUM_EXECUTABLE` can choose a locally installed Chrome for Testing. It records real execution video and a machine-readable evidence manifest. The test adds loopback-only host permission to a disposable manifest copy because programmatic popup interaction lacks a real toolbar user gesture; this is not a qualification of production activeTab consent. It never overwrites existing user pairing. See [historical-browser-extension](../../docs/research/2026-09-19-jev-voice-control/historical-browser-extension/README.md) and [evidence](../../docs/research/2026-09-19-jev-voice-control/evidence.md). The extension recording is not native-path evidence.
