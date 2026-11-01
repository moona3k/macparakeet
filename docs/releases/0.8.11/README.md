# MacParakeet 0.8.11 candidate

Prepared, not published. The stable app remains 0.8.10 and the standalone CLI remains 5.1.0. This candidate contains CLI 5.2.0; 0.9.0 remains reserved for qualified public Voice Control.

- [Draft GitHub notes](github.md)
- [Draft standalone Sparkle description](sparkle.html)
- [Release regression review and verification](../../audits/2026-11-01-release-readiness/README.md)
- [Canonical distribution procedure](../../distribution.md)

Before publication, finish the acceptance gates in the review receipt, choose the exact candidate commit, and build with `VERSION=0.8.11` and `REQUIRE_MEETING_ECHO_ASSETS=1`. Record the bundle's timestamp build number. Qualify the actual signed app, helpers and DMG, obtain Accepted notarization for those exact artifacts, and verify Sparkle installation from 0.8.10. Upload and appcast publication must use the same verified DMG bytes. This preparation does not authorize publication.
