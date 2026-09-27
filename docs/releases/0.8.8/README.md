# 0.8.8 release preparation

These are unpublished drafts for the next app release. They do not change the stable version, publish a tag, or update the public download/feed.

- [GitHub release body](github.md): full user-facing notes since v0.8.7, including compatibility and optional-feature limits.
- [Sparkle description](sparkle.html): standalone HTML for the newest appcast item, suitable for users skipping versions.

The public stable release remains v0.8.7. The `v0.8.8` tag/release links in these drafts are deliberate publication targets and will not resolve until release.

The local package under this checkout's ignored `dist/` directory will carry the exact source revision, build timestamp, signed/notarized app and DMG, SHA-256 checksums, Sparkle signature, appcast draft, and verification evidence. Those values must come from the final artifact; never copy them from an earlier candidate.

Before publication, require final-candidate CI and artifact checks and review the remaining physical/upgrade qualification results. Keep existing appcast items and prepend the new item. Do not upload a different DMG after computing its signature or checksum. Publication is a separate user decision.
