# Privacy, identity, and abuse workstream

Read `shared.md` first.

## One goal

Design and threat-model owner authentication, recipient access, encryption, revocation, recovery, and abuse controls for accountless share links.

## Questions to answer

- Compare stable hardware fingerprints, locally generated device keys, macOS Keychain/Secure Enclave keys, anonymous server-issued credentials, recovery keys, passkeys, and ordinary accounts.
- Separate owner authentication from recipient bearer-link access. Explain what each credential authorizes.
- Analyze device loss, keychain reset, migration to a new Mac, reinstall, cloned backups, stolen share URLs, server compromise, brute force, scraping, spam, illegal content, and denial-of-wallet.
- Compare server-readable content, application-layer encryption, and end-to-end encrypted URL-fragment designs; state the product consequences for previews, search, moderation, abuse response, and collaboration.
- Identify relevant privacy/security obligations for a small US-operated global service at an architectural level, without presenting legal advice.
- Recommend retention, deletion, rate limiting, quota, report-abuse, CSP, indexing, and metadata policies.

## Done

Return a threat model, credential lifecycle, abuse-control ladder, and direct verdict on the machine-fingerprint proposal, with current primary-source citations for platform and security claims.
