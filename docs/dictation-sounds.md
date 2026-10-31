# Dictation sounds

In **Settings → Capture → Dictation**, enable **Play sounds when dictation starts
and stops**. Choose each cue independently: macOS default, Handy Pop, Handy
Marimba, None, or a custom file. Each cue has a volume slider, preview button,
and Reset button. Reset restores Tink/Pop at 40% and removes that cue's imported
copy. The master toggle remains off by default.

## Custom files and playback

Imports accept WAV, AIFF, MP3, M4A, and CAF files up to 5 MB and 5 seconds.
MacParakeet validates the audio and keeps a copy in
`AppPaths.appSupportDir/DictationSounds`; the original can be moved or deleted.
Canceling or failing an import keeps the previous selection.

Unavailable files or a selected cue that cannot start playback fall back once
to the matching system cue and show a warning. If the system cue also fails,
Settings reports that the sound could not be played. Playback never waits for
a cue to finish before capture can continue.
None and zero volume stay silent. Previews and capture cues respect the macOS
sound-effects preference and system output volume. A capture cue stops any
previous cue or preview. Previews are unavailable while a capture cue is playing.
Use headphones or short cues to avoid recording the sound through speakers.

Preferences use `AppPaths.appDefaults()`. Development builds share those
preferences with stable but keep imported files in separate storage. A custom
file selected in one build may need importing again in the other.

The bundled Handy sounds are from revision
`93c9ee05efe294cf2a56bd534b77ea1079f21b77` of
[cjpais/Handy](https://github.com/cjpais/Handy). Their MIT license is included
in `Resources/Legal/HandySounds.txt` and the packaged app's Legal directory.

## Testing

```sh
swift test -Xswiftc -warn-concurrency \
  --filter 'DictationSound|SettingsSearchIndexTests|DictationFlowCoordinatorTests'
```

Manually check both presets and a custom file, independent volumes, None,
reset, import cancellation/errors, and relaunch persistence. Check hold-to-talk,
hands-free dictation, rapid start/stop, and the macOS sound-effects setting.

Controller regressions cover failed selected/system playback, successful
restoration in a fresh controller, and a delayed successful or failed restore
finishing after a replacement import or reset. The restore races use a held
read result rather than timing sleeps.
