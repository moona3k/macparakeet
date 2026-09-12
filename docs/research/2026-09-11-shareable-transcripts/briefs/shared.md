# Shared research brief: shareable transcripts

## Goal

Determine how MacParakeet can let a person deliberately publish selected text from a local transcription as a revocable web link without weakening its private, local-first product identity.

## Observed context

- Repository: `/Users/dmoon/code/macparakeet`.
- Current working checkout is dirty and 329 commits behind `origin/main`; do not change it or treat it as the current upstream product. `origin/main` was refreshed on 2026-09-11 at `aaf3dc261536e5fc5158c4b1ca714bd3f4cece19`.
- Authoritative product direction: `spec/adr/027-product-north-star.md` and `spec/adr/002-local-only.md` on `origin/main`.
- The current product has local transcripts for dictation, meetings, files, and YouTube; summaries/notes and export/copy surfaces already exist.
- The desired first milestone is text-only, read-only sharing. The owner chooses which transcript, notes, and summary fields to include. Audio is excluded.
- A recipient should open a normal web URL without installing MacParakeet or creating an account.
- The founder controls `macparakeet.com` and is willing to operate modest server infrastructure.

## Settled for this investigation

- Research and recommendations only. Do not implement, deploy, publish, register domains, mutate GitHub, or edit repository files.
- Sharing is an explicit network surface and must be opt-in per share; local capture/transcription stays local.
- Evaluate collaboration as a later phase, not part of the first milestone.
- Treat a hardware-derived fingerprint as a proposal to evaluate, not a chosen design.
- Prefer current primary sources and distinguish sourced fact, inference, and recommendation.

## Fences

- Do not inspect or expose real transcripts, local databases, audio, private config, environment files, keys, or credentials.
- Do not build or test in the dirty checkout.
- Do not assume the existence or availability of `sharekee.com`; recommend naming separately from architecture.
- Do not optimize around a specific cloud vendor until alternatives and migration boundaries are considered.

## Report shape

Return a concise but substantive memo with:

1. direct findings and recommendation;
2. a comparison table where useful;
3. concrete failure/abuse scenarios;
4. primary-source URLs with titles and dates/access dates;
5. uncertainties or claims that could not be verified;
6. the five decisions that most affect the first implementation plan.
