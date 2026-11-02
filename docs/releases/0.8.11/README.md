# MacParakeet 0.8.11 candidate

Prepared, not published. The stable app remains 0.8.10 and the standalone CLI remains 5.1.0. This candidate contains CLI 5.2.0; 0.9.0 remains reserved for qualified public Voice Control.

- [Draft GitHub notes](github.md)
- [Draft standalone Sparkle description](sparkle.html)
- [Release regression review and verification](../../audits/2026-11-01-release-readiness/README.md)
- [Canonical distribution procedure](../../distribution.md)

The previous candidate was built and Developer ID signed: **0.8.11 / 20261101201053**, source `0146098b013e`. It includes PR #1309, both review rounds' fixes, real helpers and required echo assets. Its bundled CLI, helpers, packaged resources, Release feature gates and isolated transcription/persistence/export checks passed. See the [updated signed-candidate receipt](../../audits/2026-11-01-release-readiness/evidence/signed-candidate-final.md) for hashes and retained artifacts. The initial build `20261101185026` predates the fresh-review title fixes and is superseded.

The telemetry companion is merged and deployed. That app and DMG have Accepted notarization, valid staples and Gatekeeper acceptance; the mounted image and final DMG Sparkle signature passed. See the [candidate artifact receipt](https://github.com/moona3k/macparakeet-website/blob/b475bf0a6cf979a26423b2a2c243ea5d9c1f9652/docs/release-0811-candidate.md) and [telemetry deployment receipt](https://github.com/moona3k/macparakeet-website/blob/b475bf0a6cf979a26423b2a2c243ea5d9c1f9652/docs/release-0811-telemetry.md). The signed-candidate receipt above records the earlier, pre-notarization stage.

Before publication, finish native and physical acceptance and verify installation and a real Sparkle upgrade from 0.8.10. No app release has been published. If executable source changes, build a new candidate with `VERSION=0.8.11` and `REQUIRE_MEETING_ECHO_ASSETS=1` and record its new build number and hashes. Upload and appcast publication must use the same verified DMG bytes.

The PR #1310 follow-up additionally requires confirmed calendar provenance before protecting a matching name. The earlier artifact is preserved in `dist/qualified-20261101201053/` and is superseded for release. Current candidate identity and qualification are recorded in the [latest artifact receipt](https://github.com/moona3k/macparakeet-website/blob/3111c3804aebffd1e6177fbcd9d2fae0ad98c8e2/docs/release-0811-candidate.md); the pinned receipt above remains historical.

The replacement is **0.8.11 / 20261102065713**, executable source `cfa883efe0e9ddc308f11c735656e04737922195`. App and DMG notarization are Accepted; staples, signatures and Gatekeeper assessments passed. Final stapled DMG: **182746189 bytes**, SHA-256 `47e65cbfaf81040a5eb92942cdb1b88382689699f7f41695fc100e18b5218c48`. The immutable receipt records submission IDs and the remaining native/install/upgrade gates.
