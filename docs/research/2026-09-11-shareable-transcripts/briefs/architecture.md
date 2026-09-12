# Architecture, integration, and economics workstream

Read `shared.md` first.

## One goal

Map the current MacParakeet integration points and propose a minimal, vendor-conscious web architecture with realistic data, API, operational, and cost boundaries.

## Questions to answer

- Inspect `origin/main` without changing the checkout: current copy/export actions, transcription/meeting/summary models, GRDB repositories, settings/network-service patterns, telemetry consent, licensing identity, and deletion flows.
- Identify the cleanest module boundaries across MacParakeetCore, MacParakeetViewModels, app SwiftUI, public contracts, and a separate web service.
- Propose API resources and schemas for device registration, share creation/update/revocation/listing, content versions, and recipient reads.
- Compare Cloudflare Workers/D1/R2/KV/Durable Objects with one conventional managed alternative for this workload using current official pricing/limits.
- Estimate storage and request scale for 1k, 10k, and 100k active users under explicit assumptions.
- Identify migration/versioning, idempotency, offline retry, observability-without-content, and deletion propagation requirements.

## Done

Return repository evidence with exact paths/line anchors or `git show origin/main:<path>` references, one recommended architecture, one credible alternative, rough unit economics, API/data sketches, rollout slices, and open technical spikes. Do not run builds or tests.
