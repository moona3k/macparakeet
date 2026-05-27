# Issue #368 Calendar Permission Root Cause

## Summary

Issue #368 reports that Calendar access cannot be connected from either
Settings or onboarding in MacParakeet 0.6.11 (`d42138a00cdc`). The CleanShot
evidence shows the Calendar button briefly entering its requesting state and
then returning to "Grant Calendar Access" without a macOS prompt or blocked
permission recovery state.

The root cause is the signed release app's missing Calendar entitlement:
`com.apple.security.personal-information.calendars`.

## Evidence

- The reported build is the shipped Developer ID app:
  `CFBundleIdentifier=com.macparakeet.MacParakeet`,
  `CFBundleShortVersionString=0.6.11`,
  `CFBundleVersion=20260524210220`,
  `MacParakeetGitCommit=d42138a00cdc`.
- The shipped app bundle includes `NSCalendarsFullAccessUsageDescription`, so
  this is not an Info.plist usage-string omission.
- The shipped app entitlements include only:
  `com.apple.security.device.audio-input` and
  `com.apple.security.network.client`.
- The user's visible behavior matches EventKit returning failure before TCC
  records a decision: the UI awaits `CalendarService.requestPermission()`, gets
  `false`, re-reads `.notDetermined`, and renders the same grant button again.
- Local TCC inspection on the matching installed app showed no
  `kTCCServiceCalendar` row for `com.macparakeet.MacParakeet`, consistent with
  no first-time Calendar prompt being presented or recorded.

## Official Docs Check

Apple's EventKit docs say apps must request access through `EKEventStore`
before reading calendar data, and full access is the required access level for
reading events. Apple's Info.plist docs require
`NSCalendarsFullAccessUsageDescription` for full calendar access. Apple's
Calendar entitlement docs define
`com.apple.security.personal-information.calendars` as the entitlement that
allows read-write access to the user's calendar and instruct developers to add
that entitlement when enabling App Sandbox or Hardened Runtime capabilities.

MacParakeet uses Developer ID hardened-runtime signing in
`scripts/dist/sign_notarize.sh`, so the final app needs both:

- `NSCalendarsFullAccessUsageDescription` in `Info.plist`
- `com.apple.security.personal-information.calendars = true` in the signed app
  entitlements

## Why Local Testing Missed It

Most local calendar testing exercised the dev bundle (`com.macparakeet.dev`)
or an already-granted TCC identity. That path did not force a fresh first-time
Calendar prompt for the signed release bundle identity. The dev run script also
did not explicitly sign with the release entitlement file, so dev smoke testing
was not a strong parity check for the final Developer ID app.

## Fix

- Add `com.apple.security.personal-information.calendars` to
  `scripts/dist/MacParakeet.entitlements`.
- Sign the dev app with the same entitlement file so local calendar permission
  smoke tests exercise the same capability surface as release.
- Add `scripts/dist/verify_app_privacy_surface.sh` and run it from
  `scripts/dist/sign_notarize.sh` after codesigning. The verifier checks the
  microphone, system-audio, and calendar privacy strings plus the app
  entitlements needed by TCC.

## Regression Guard

Before notarization, `scripts/dist/sign_notarize.sh` now fails if the signed app
is missing:

- `NSMicrophoneUsageDescription`
- `NSAudioCaptureUsageDescription`
- `NSCalendarsFullAccessUsageDescription`
- `com.apple.security.device.audio-input`
- `com.apple.security.personal-information.calendars`
- `com.apple.security.network.client`
