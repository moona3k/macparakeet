# Model and physical qualification

`scripts/dev/model_qualification.py` runs the existing release demo through the
real CLI, synthesized speech, Parakeet v3, CoreML, SQLite, a fresh CLI history
read, and Markdown export. It requires a prebuilt executable and accepted,
preprovisioned model bytes. It never builds or downloads models. Child commands
run under macOS `sandbox-exec` with networking denied and a bounded timeout.

The strengthened `release_demo_smoke.sh` checks persisted ID, completed status,
and exact saved text in a separate process. Both results must identify Parakeet
v3, so a routing regression cannot pass by using another engine. It requires at least four of five
distinctive fixture words and the persisted transcript in the exported Markdown
(ignoring timestamp prefixes and whitespace). Nonempty but unrelated output is
a failure. Parakeet v3 and raw processing are explicit, so saved engine and
formatting preferences do not silently choose a different journey.

## Prepare once, qualify repeatedly

Use an Apple Silicon Mac and the dedicated disposable macOS account named
`macparakeet-e2e`. Do not rename an everyday account or run with sudo. State
directories and `--database` do not isolate shared UserDefaults or Keychain;
the account boundary is intentional. Do not put valuable app data in it.
Python 3.9+, `say`, `afconvert`, and `sandbox-exec` must be available. Install a
local system voice before disconnecting networking; speech synthesis failures
are failures, never model passes.

Build or install the intended CLI separately. Provision the selected model in
an owned state directory, using that CLI's normal model installation command:

```sh
export MACPARAKEET_DEBUG_APP_STATE_DIR="$HOME/qualification-state"
export MACPARAKEET_TELEMETRY=0
/absolute/path/to/macparakeet-cli models download parakeet-v3
python3 scripts/dev/model_qualification.py pin \
  --state-dir "$MACPARAKEET_DEBUG_APP_STATE_DIR" \
  --output "$HOME/approved-parakeet-v3.json"
```

Provisioning is explicitly separate and may use the network. The pin records
SHA-256 for every regular file in `FluidAudio/Models`; symlinks and an empty
cache are rejected. Retain the accepted manifest with the model's provenance
and release qualification records. Do not regenerate it merely to make a
changed cache pass. Extra, missing, or changed model files require deliberate
requalification. This manifest identifies accepted local bytes; it is not an
independent assertion of their publisher or authenticity.

Run qualification with a new evidence directory:

```sh
python3 scripts/dev/model_qualification.py run \
  --cli /absolute/path/to/macparakeet-cli \
  --state-dir "$HOME/qualification-state" \
  --manifest "$HOME/approved-parakeet-v3.json" \
  --output-dir "$HOME/qualification-runs/candidate-001"
```

The tested CLI must report `parakeet-v3` installed. Networking stays denied
even if its loader attempts a download. The default journey timeout is ten
minutes; `--timeout` can change it for a deliberately slower qualification host.
A timeout kills and reaps the owned command group. Evidence retains commands,
exit statuses, version, audio, original/readback JSON, export, content checks,
binary and manifest digests, OS/architecture, and pass/failure status. Failure
does not delete evidence or modify the accepted manifest.

The legacy smoke remains callable directly for development, including its
Swift-run fallback. **Only the qualification wrapper establishes this account,
asset pinning, offline, and timeout boundary.** Ordinary PR CI runs the cheap
driver/content checks, not a model download or real inference.

## Physical journeys still require devices and a person

The file-model journey does not prove microphone capture, hotkeys, TCC,
Bluetooth, clipboard delivery, system audio, or acoustic echo quality. Use the
intended signed app build in the same disposable account and record build/CLI
hash, OS, model manifest, device names, route, and permission state alongside
each outcome. Capture only synthetic speech/audio and owned destination files.

| Journey | Action | Required observable result |
| --- | --- | --- |
| Dictation delivery | Focus an owned TextEdit document, dictate the fixture, stop | Exactly one insertion; matching completed History text and retained audio according to the configured policy |
| Cancel/restart | Cancel before recognition returns, immediately dictate a different phrase | No stale insertion or completed cancelled take; only the new result is delivered; opt-in discarded history is labelled cancelled |
| Permission denial | Deny microphone access, attempt capture, then grant access and retry | Clear failure without a saved completed take; subsequent permitted capture succeeds |
| Dual-source meeting | Play one known phrase as system audio and speak a distinct phrase into the mic; stop and relaunch | One durable recording, both sources attributable, playable artifacts and consistent transcript/manifest/notes after relaunch |
| Bluetooth route transition | Repeat dictation/meeting while selecting and disconnecting the actual Bluetooth device | Document selected and observed route, interruption/recovery behavior, missing or duplicated speech, and saved media playability |
| Missing/late source | Start a meeting with one source silent, introduce it later, then stop | Timeline alignment and source labels remain correct; silence does not fabricate speech; retained media decodes |

Report each as passed, failed, or not run with its evidence and missing
prerequisites. Synthetic files and stub STT cannot satisfy these rows. Device
quality claims need an appropriate acoustic corpus and metrics in addition to
this small functional journey.

## Verification in this change

The content/pinning/process checks passed locally, including changed-model and
wrong-export negative controls, command failure/timeout, and a real socket
operation rejected by the offline sandbox after an allow-profile control
succeeded. The current ordinary account was rejected before CLI launch. Real
`say`/`afconvert` orchestration also passed with a deliberately fake CLI; a
wrong-export response failed the full shell driver. That checks the driver,
not speech recognition. Real
model inference and physical journeys were **not run**: this session does not
have the dedicated account, accepted model manifest, and device/permission
qualification setup. The runner makes those limits executable rather than
turning them into silent skips or claiming a model pass.
