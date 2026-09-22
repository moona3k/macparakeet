# Saved meeting splitting — issue #895

> **Current direction: Split and transcribe.** Each part is a new saved
> recording with independent audio, followed by sequential first transcription
> and normal enabled meeting automation. The original remains untouched.
> The [revised plan](../../plans/2026-09-11-issue-895-meeting-split-plan.md) and
> [approved contract](../../../spec/contracts/meeting-splitting.md) supersede
> transcript-preservation, speaker-baseline and hard word-boundary rules in
> this historical research and prototype. No feature ships in these docs.

- [Implementation handoff](../../plans/2026-09-11-issue-895-meeting-split-plan.md): scope, code entry points, implementation units, acceptance tests and release gates for a future coding agent. The app feature is not implemented by this research change.
- [Findings and recommendation](report.md): feasibility, user flow, data rules, current-main citations, architecture and implementation gates.
- [Architecture and design assessment](report.md#architecture-and-design-assessment): ordinary meeting outputs, a small shared Core interface, three internal responsibilities and native interaction considerations.
- [Interactive HTML mockup](split-recording-prototype.html): open directly in a browser. Add boundaries and titles, create sample meetings, inspect their timestamps, and try the audio-removed or edited-transcript scenarios. All data is fictional; no files are changed.
- [Native audio experiment](audio-range-spike.swift) and [measured results](audio-range-results.json): synthetic AAC range exports with the original preserved.
- [Research-time verification receipt](artifact-check.json): browser flows, layout, original hashes and limitations. [Publication check](publication-check.json) covers the packaged handoff and reference-only clarification; screenshots preserve the earlier banner.
- [Final recommendation review](recommendation-review.md): bounded independent Sonnet 5 review of the synthesis against current main.

Research baseline: GitHub main `aaf3dc261536e5fc5158c4b1ca714bd3f4cece19`, inspected September 11, 2026. These are research artifacts, not an implemented or released app feature. Refresh the issue, governing contracts and affected code before implementation.

**The HTML is a reference, not the final UI/UX specification.** Its layout, controls, copy and interaction sequence are illustrative. The implementing agent should explore the best native experience in the current app, document the choice and validate it. A sheet is one candidate, not a requirement; do not embed the prototype in a WebView or treat screenshot matching as acceptance.

The provisional [storage](storage-findings.md) and [transcript/product](transcript-product-findings.md) notes came from Sonnet 5 exploration of the older dirty checkout. Their recommendations were reviewed and corrected in the main report; they are not an implementation contract.

To rerun the synthetic experiment on a Mac with the Swift toolchain, from the repository root:

```sh
split_spike_dir=$(mktemp -d /tmp/macparakeet-895-audio.XXXXXX)
swiftc -parse-as-library docs/research/2026-09-11-issue-895-meeting-split/audio-range-spike.swift -o "$split_spike_dir/audio-range-spike"
"$split_spike_dir/audio-range-spike" "$split_spike_dir"
```

This creates a synthetic source and six small exports only in the new scratch directory. The short fixture does not establish production performance, multi-track correctness or crash recovery.
