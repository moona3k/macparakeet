# MacParakeet 0.8.11 candidate

Prepared, not published. The stable app remains 0.8.10 and the standalone CLI remains 5.1.0. This candidate contains CLI 5.2.0; 0.9.0 remains reserved for qualified public Voice Control.

- [Draft GitHub notes](github.md)
- [Draft standalone Sparkle description](sparkle.html)
- [Release regression review and verification](../../audits/2026-11-01-release-readiness/README.md)
- [Canonical distribution procedure](../../distribution.md)

A local candidate is built and Developer ID signed: **0.8.11 / 20261101185026**, source `b9eab04a1f4f`. It includes real helpers and required echo assets. Its bundled CLI, helpers, packaged resources, release gates and isolated transcription/persistence/export checks passed. See the [signed-candidate receipt](../../audits/2026-11-01-release-readiness/evidence/signed-candidate.md) for hashes and retained artifacts.

Before publication, finish native and physical acceptance, obtain Accepted notarization for the exact app and DMG, and verify installation and Sparkle upgrade from 0.8.10. No notarization submission or DMG has been made yet. If source changes, build a new candidate with `VERSION=0.8.11` and `REQUIRE_MEETING_ECHO_ASSETS=1` and record its new build number and hashes. Upload and appcast publication must use the same verified DMG bytes. This preparation does not authorize publication.
