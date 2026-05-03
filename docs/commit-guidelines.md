# Commit Message Guidelines

> Status: **ACTIVE**

This project uses **rich commit messages** optimized for AI-assisted development. Each commit should capture enough context that a future agent (or human) can understand the full reasoning.

## Structure

```
<title>: Short summary (imperative mood)

## What Changed
Detailed breakdown of every file/section modified.

## Root Intent
Why this commit exists. The underlying problem or goal.

## Prompt That Would Produce This Diff
A detailed instruction that would recreate this work from scratch.
This is the "recipe" - if you gave this prompt to an AI agent with
access to the codebase, it should produce an equivalent diff.

## ADRs Applied (if any)
Links to architectural decisions that informed the changes.

## Files Changed
Summary with line counts for quick scanning.
```

## Example (Feature)

```
Add dictation overlay with waveform visualization

## What Changed
- Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift: New compact dark pill overlay
  with recording state indicator, waveform, and cancel button
- Sources/MacParakeet/Views/Dictation/WaveformView.swift: Real-time audio level waveform using
  AVAudioEngine tap data
- Sources/MacParakeetCore/Services/Dictation/DictationService.swift: Added audioLevelPublisher for UI
- Tests/MacParakeetTests/DictationServiceTests.swift: Test audio level callback registration

## Root Intent
Users need visual feedback when dictating -- they need to know the app is recording,
see their voice levels, and have a clear way to cancel. The pill overlay appears over
all apps without stealing focus.

## Prompt That Would Produce This Diff
Implement a dictation overlay for MacParakeet modeled after OatFlow's pill overlay.
Create a compact dark pill that:
1. Appears as a borderless NSPanel over all windows
2. Shows recording state with pulsing indicator
3. Displays real-time waveform from AVAudioEngine audio levels
4. Has a cancel button (Escape key also cancels)
5. Does NOT steal focus from the active app (non-activating panel)

Use KeyablePanel pattern if text input is needed. Add audioLevelPublisher
to DictationService so the view can subscribe to audio levels.

## ADRs Applied
- ADR-001 + ADR-007: Parakeet TDT model with FluidAudio CoreML runtime

## Files Changed
- Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift (+145)
- Sources/MacParakeet/Views/Dictation/WaveformView.swift (+62)
- Sources/MacParakeetCore/Services/Dictation/DictationService.swift (+28, ~12)
- Tests/MacParakeetTests/DictationServiceTests.swift (+34)
```

## Example (Bug Fix)

```
Fix clipboard not restoring after dictation paste

## What Changed
- Sources/MacParakeetCore/Services/Dictation/DictationService.swift: Save clipboard contents
  before pasting transcription, restore after CGEvent paste completes

## Root Intent
Users complained that dictation overwrites their clipboard. The paste
operation should be transparent -- save what was on the clipboard, paste
the transcription via simulated Cmd+V, then restore the original clipboard.

## Prompt That Would Produce This Diff
Fix the dictation paste flow in DictationService to preserve the user's
clipboard. Before writing the transcription to NSPasteboard, save the
current contents. After the CGEvent Cmd+V is dispatched and a short delay
(100ms), restore the saved clipboard contents.

## Files Changed
- Sources/MacParakeetCore/Services/Dictation/DictationService.swift (~18)
```

## Why This Matters

1. **Git history becomes documentation** -- Rich context lives in version control, not lost chat logs
2. **Reproducible changes** -- The prompt section is a recipe that could regenerate the diff
3. **Onboarding via archaeology** -- New devs/agents understand decisions by reading commits
4. **Auditable reasoning** -- The "why" is preserved alongside the "what"

## When to Use This Format

- **Always** for significant changes (multi-file, architectural, spec updates)
- **Optional** for trivial fixes (typos, single-line changes)
