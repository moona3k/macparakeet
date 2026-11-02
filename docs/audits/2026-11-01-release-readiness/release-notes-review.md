# Independent release-notes review

Reviewed `docs/releases/0.8.11/github.md` and `sparkle.html` at
`09773c2d0ccbf440390d7f9426ed0624078d0f40`, against the actual `v0.8.10`
source/tag notes, current implementation, feature gates, and contracts.
No builds, tests, native audio/UI actions, or publication were performed.
This report does not use earlier release notes as proof that an implementation
claim is correct. The parent owns final prose and publication.

## Substantive findings

### P2 — Reverse the AEC timing explanation and identify saved-meeting scope

**Location:** `github.md:12`.

The sentence says the reference track arrives ahead of the microphone. The
fix addresses the opposite relationship: recorded offsets put the system
reference *after its echo* in the microphone. Reading the reference 20 ms
earlier makes that echo path causal for the offline estimator/model. It is
post-stop cleaned-microphone processing for transcription, not a new live
meeting playback echo canceller.

**Evidence:** `MeetingCleanedMicRenderer.swift:38–44,456–464`;
`Tests/MacParakeetTests/Services/Capture/MeetingAecRenderLookaheadTests.swift:4–16`;
`spec/05-audio-pipeline.md:329–340`. The actual tag-to-head diff introduces
`referenceLookaheadMs` and applies it to probe/render alignment.

**Suggested prose:** “Improved echo reduction in saved meeting transcripts
when system audio and microphone timing are slightly offset.”

Sparkle's “Improved meeting echo alignment” is directionally correct, but
using the same saved-transcript scope would avoid implying a live-playback fix.

### P2 — Restore skipped-version Apple Intelligence requirements and migration notice

**Location:** `sparkle.html:16–17`.

The standalone description says Apple Intelligence is available for cleanup,
then gives only the app's macOS 14.2 requirement. Apple Intelligence actually
requires macOS 26, eligibility, enabled system models, and readiness. The old
Sparkle description also explained an upgrade consequence that still applies
to users skipping versions: an old Apple Intelligence default is cleared,
and an unsupported analysis override falls back to Default AI. “Cleanup only”
does not tell these users why their previous AI setup changed or where to fix it.

**Evidence:** `AppleIntelligenceAvailability.swift:40–55,73–80`;
`LLMConfigStore.swift:238–251`; `LLMExecutionContext.swift:14–20`;
`spec/11-llm-integration.md:138`; the actual
`git show v0.8.10:docs/releases/0.8.10/sparkle.html` includes both the OS caveat
and migration notice. This is inherited upgrade guidance, not a new 0.8.11 feature.

**Suggested prose:** “Apple Intelligence is available for Dictation & cleanup
on eligible Macs running macOS 26 or later with Apple Intelligence enabled.
If it was previously your Default AI or meeting-analysis provider, check
Settings → AI Setup: the unsupported selection is cleared. Saved API keys
remain.” For precise migration wording, keep “an old Apple analysis override
falls back to Default AI.”

Keep the separate application requirement of Apple Silicon and macOS 14.2+.

### P2 — Name Hide Video as the recovery action and qualify retained audio

**Location:** `sparkle.html:9`; align the wording at `github.md:10`.

Sparkle says saved audio stays available after a failed video load, without
the Hide Video action that the GitHub version correctly mentions. When a
transcript is entered directly with the video panel open, failure leaves
`playerState = .error` and can leave `player` nil; Hide Video then invokes
`cancelVideoPreparation()` and prepares retained audio. The promise should
also be limited to audio that was retained: the implementation cannot restore
an absent/deleted local file, and legacy conversion can itself fail.

**Evidence:** `MediaPlayerViewModel.swift:147–198,310–324,436–440`;
`TranscriptResultView.swift:899–907,1038–1045`;
`MediaPlayerViewModelTests.swift:395–454` tests failed direct-load recovery
by explicitly calling `cancelVideoPreparation()`.

**Suggested prose:** “Show Video can prepare separate video and audio
streams. Hide Video cancels preparation or returns to retained audio after
a video-load failure, when a saved audio file is available.”

This is a documentation precision issue, not a newly discovered runtime defect.

## Claim-by-claim disposition

| Claim | Independent source check | Disposition |
| --- | --- | --- |
| Next meeting can start while prior processing continues; saved processing and Retry | Tag-to-head capture settlement/output/queue split; detail recovery requires meeting error/cancelled plus saved sources | Supported. Avoid promising recovery of missing source files or all capture failures. |
| Opt-in Beta active-meeting reminders, initially off, Record required | `AppFeatures.meetingActivityDetectionEnabled = true`; runtime preference defaults off; reminder coordinator and Settings describe explicit Record | Supported and newly exposed since 0.8.10. |
| Separate customizable start/stop cues; Bloom and Gong | Configuration/controller/library and processed resource files added since tag | Supported. Existing default system cues remain; no default sound change should be implied. |
| Dictation start/stop URLs, default-off, apps/websites can invoke | Independent runtime key defaults false; router/parser and coordinator use persistent dictation | Supported and new. Toggle also exists but omitting it is not an accuracy defect. |
| Keyboard state isolation and failed streaming-flush retry suppression | Generated session events/marker filtering; permanent posting stop and partial-insert fallback | Supported. Does not establish physical/remote-keyboard acceptance or fix arbitrary upstream stale HID state. |
| Split-stream YouTube playback and preparation indication | Downloader/FFmpeg resource ownership and UI stage/elapsed-time presentation | Supported within compatible formats/limits; recovery wording needs the finding above. “Progress” means stages/time, not a measured percentage. |
| Scratch-storage failure reporting | Probe creates parent, checks output write, throws output-read failures | Supported. Do not claim the root cause of every reported file-import failure is solved. |
| Meeting echo change | Offline lookahead implementation and dedicated synthetic test | New behavior supported; GitHub explanation reverses the timing relationship. |
| One corrective card retry and preservation on failure | `LLMService.generateKnowledgeCard` loops at most twice, uses shared typed validation; CardGenerationService validates before replace | Supported. Saved-card preservation is an existing invariant exercised by new recovery tests, not a wholly new storage feature. |
| Title retry, years/longer titles, generic-year rejection, adopted calendar/manual protection | Generator retry classification and title validation; current recording persistence protection | Supported. Retry is bounded to one extra attempt for connection/timeout/CLI failures; invalid model output is rejected rather than endlessly retried. |
| Compact Settings, broader search, visible vocabulary load failures, punctuation-bearing literals | Layout/search additions; load-state guards; shared escaped Unicode-boundary matcher | Supported. Native layout/accessibility acceptance remains separate. |
| CLI 5.2.0 history corrections, vocabulary boundaries, activity trigger, processing-state duration | CLI version declaration/history projection; shared matcher; start-context model and processing placeholder | Supported. New trigger-enum value is correctly called out; existing field/exit-code claim does not erase that compatibility change. |
| Experimental surfaces remain gated | Current AppFeatures and compile/runtime availability checks | Supported for the standard packaged release. In-process MLX additionally depends on an opt-in build target, so “not included in this release” is clearer than claiming no custom Release build could enable it. |
| Older-version features in standalone Sparkle | Actual 0.8.10 tag source/notes and current implementations | These are correctly identified as inherited rather than newly introduced in 0.8.11. Restore Apple migration/OS details above. |

## Knowledge-card Release reachability

Ask being gated does **not** gate knowledge-card generation. The bundled CLI
unconditionally registers `CardsCommand` (`MacParakeetCLI.swift:24`), whose
generation command constructs `CardGenerationService` (`CardsCommand.swift:136`).
The GUI configurer also injects that service when analysis LLM configuration
exists (`AppEnvironmentConfigurer.swift:281`), and
`PromptResultsViewModel.swift:742,795` invokes it for automatic processing;
`TranscriptionViewModel.swift:1156` invokes it after retranscription.
The fix can truthfully be mentioned in public notes. A CLI/background-processing
context is clearer than implying that a new visible card/Ask workspace ships.

## Additional publication guidance

- For standalone Sparkle parity, append “Once enabled, other apps and websites
  can send these links” to the dictation-link bullet. GitHub already carries
  the global-consent implication; Sparkle should not depend on a second page
  to convey it.
- Retain optional/Beta/default-off language for reminders and URL control.
  Browser meeting detection requires Accessibility; a settings path and that
  qualifier would make the reminder bullet more actionable, without claiming
  every browser/call provider is supported.
- Link the complete GitHub notes/CLI compatibility from Sparkle. Its current
  trigger-value summary is useful but the full GitHub paragraph explains the
  closed-enum and in-progress-meeting implications.
- Remove the draft/not-published line only as part of the actual publication
  transition. Do not copy preparation/authorization statements into published
  notes. This audit does not itself change publication state.
- Neither notes file claims that the known initial system-audio-start failure
  or the reported Whisper near-silence accuracy problem is fixed. Keep that
  boundary: capture settlement, reference alignment, and model accuracy are
  different problems. Avoid a new blanket “all meeting recording problems fixed”
  or “fully verified” headline.

No claim here establishes current live-provider availability, native acceptance,
notarization, installation, or Sparkle upgrade success.

## Recheck after the notes rewrite

Re-read both working-tree notes in full against the findings and claim inventory
above. All three substantive findings are resolved:

- Both channels now describe echo reduction in **saved meeting transcripts**
  with slightly offset system/microphone timing; neither reverses the reference
  relationship or promises a live-playback echo fix.
- Both channels give the macOS 26/system-model requirement for Apple
  Intelligence and explain the old default/analysis-route migration, direct
  users to AI Setup, and preserve the saved-key assurance. The app's separate
  macOS 14.2 requirement remains clear.
- Both channels condition audio recovery on an available saved audio file
  and identify cancellation/Hide Video after a failed load as the recovery
  action. They no longer imply audio is recreated when it was not retained.

Sparkle now also carries the any-app/website URL-control consent disclosure.
The existing optional/Beta wording and GitHub's explicit default-off reminder
description remain intact. The other claims remain supported as recorded in
the inventory; no new blocking inaccurate claim was found. The suggested
Sparkle link to complete CLI notes and a more specific reminder settings path
remain optional usability improvements, not blockers.

Reviewed content hashes (SHA-256):

- `github.md`: `9395432fc4d1737a7721ba775fdb8c23168c4680f3a81a152880f1ae309978fc`
- `sparkle.html`: `5210299b60a9f84be395fa9eb8fb15fba4a3eb80a91c48595dc3d232adb18850`

`git diff --check` passed for both notes. The draft/not-published line is
correct for preparation and must be removed at publication. This recheck
approves claim accuracy of these note drafts; it does not qualify the app,
notarization, installation, or update delivery.
