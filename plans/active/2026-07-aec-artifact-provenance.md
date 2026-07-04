# AEC Artifact Provenance (2026-07)

Goal: meeting artifact folders self-describe their echo-cancellation outcome.
Motivation: users report transcript-accuracy issues by sharing folders;
support/QA must determine cleaned-vs-raw and why without app logs. Design:
render-resolution summary (reason code, model version, render timing, delay
estimate, probe stats) persisted as additive optional `echoSuppression` fields
in meeting-recording-metadata.json, written when the readiness gate resolves
(PR #671's taxonomy). Shipped with the echo-probe skip PR. Related: journal
design rationale 2026-07-03; ADR-026 (pending).
