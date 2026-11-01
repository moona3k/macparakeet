# Dictation sounds

In **Settings → Capture → Dictation**, enable **Play sounds when dictation starts
and stops**. Choose each cue independently: macOS default, Bloom, Gong, None,
or a custom file. Each cue has a volume slider, preview button,
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

## Original Bloom and Gong pairs

Bloom offers warm, rounded resonance. Gong offers a deeper, bowl-like metallic
resonance. Both pairs are original MacParakeet sounds. Each higher start
sound marks microphone readiness; each lower stop sound marks the end of
capture, not successful transcription or insertion. Choose each cue independently
and use Preview at your normal listening volume. The files include quiet tails:
660 / 860 ms for Bloom and 800 / 950 ms for Gong (start / stop). Playback never
delays capture for those tails.

The assets are synthesized from original equations and contain no Handy samples.
The [sound design and provenance](dictation-sound-design.md) note describes the
offline generator and verification. No synthesis or extra dependency runs in the app.

Saved Handy Pop and Handy Marimba selections now use Bloom. Their saved volumes,
retained custom-file references, and the master sound toggle are preserved.
macOS default, None, and custom selections remain unchanged. New preferences save
`bloom`. Reset still restores the macOS cue at 40%.

## Testing

```sh
swift test -Xswiftc -warn-concurrency \
  --filter 'DictationSound|SettingsSearchIndexTests|DictationFlowCoordinatorTests'
```

Manually check Bloom, Gong, and a custom file, independent volumes, None,
reset, import cancellation/errors, and relaunch persistence. Check hold-to-talk,
hands-free dictation, rapid start/stop, and the macOS sound-effects setting.

Controller regressions cover failed selected/system playback, successful
restoration in a fresh controller, and a delayed successful or failed restore
finishing after a replacement import or reset. The restore races use a held
read result rather than timing sleeps.

Configuration tests cover legacy preset migration and canonical preference roundtrips.
Controller tests decode all four bundled assets, verify the approved audio hashes,
and check independent capture and preview players without a system fallback.
