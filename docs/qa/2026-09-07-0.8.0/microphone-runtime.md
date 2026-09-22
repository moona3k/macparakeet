# Microphone and meeting runtime verification

Status: **PASS for the observed microphone-only flows on baseline `8548c099`**. System-audio capture, Bluetooth route changes, global hotkeys, pause/mute and quiet completion while another app holds focus remain separate checks.

The isolated Release GUI copy used its own bundle identifier and redirected Application Support directory. All meeting rows and audio belong to this QA session. The microphone route was macOS System Default → MacBook Pro Microphone at 48 kHz; output was MacBook Pro Speakers. No normal-library records were modified.

## Inputs and method

Use public FLEURS `en_us_0000.wav`, 10.56 seconds, from the fixture inventory. This exercise plays speech through the physical speakers into the physical microphone; it is distinct from file transcription and from direct digital loopback. Test Input displayed Listening, detected input, and automatically returned to its idle control. This establishes first-buffer/meter behavior, not recognition accuracy.

Select microphone-only meeting capture in the QA app's settings. The screen/system-audio status changed from permission-required to Ready without granting screen capture. Set Open app when meeting ends and Notify when transcript is ready both off. Calendar remained off. Start from Meetings; observe explicit Starting and enabled stop controls, then Recording. Play the public fixture, request Stop, and confirm End recording before its confirmation expires. Wait for Start recording to return and inspect the owned database and artifact directory.

## Results

| Check | First attempt | Second attempt |
| --- | --- | --- |
| Speaker volume | Original 13/100 | Temporarily 50/100; restored to 13 in `finally` |
| Captured duration | 48.900 seconds | 13.500 seconds |
| Reported elapsed duration | 48.813 seconds | 13.427 seconds |
| Capture result | Healthy, microphone complete, coverage 1 | Healthy, microphone complete, coverage 1 |
| Final status | Completed | Completed |
| Transcript | Empty | 116 characters; public sample's communication/styles/years terms present |
| Audio folder | Retained | Retained |
| Recovery lock after settlement | Absent | Absent |

The first recording's measured microphone mean was −51.3 dB and peak −31.7 dB. The low playback level did not establish usable speech delivery; its empty transcript is not counted as a transcription pass. The second recording recognized the public sentence after increasing playback level. This supports the diagnosis of an inadequate first setup, rather than proving every potential empty-transcript cause impossible.

The first attempt was longer because the automation initially treated the Stop action as final; the UI correctly required an explicit Confirm end recording. No stop-success claim was made until Start recording returned and the saved row/artifacts were verified. The second run confirmed promptly and completed in 13.5 seconds. Both owned sessions remain available for inspection; no recorded audio is committed to this report.

See [sanitized result fields](evidence/mic-meetings-results.json). The app remained on the Meetings surface after settlement, but it was already foreground: that observation does **not** prove quiet completion preserves another app's focus. Mic-only also creates an empty `system-raw.m4a` placeholder; the capture report correctly lists only microphone as the captured source.

## Remaining environment gate

The unique QA app has microphone access, but Accessibility is not yet granted. Opening its Accessibility setup reached macOS's Touch ID/password authorization sheet before adding the app. The user was asked to authenticate; no password was requested in chat and no TCC database was edited. System-audio permission has not yet been granted or tested.
