# Documentation map

Start with the [spec index](../spec/README.md) for product behavior, release
channels, feature gates and accepted decisions. The
[architecture map](../spec/03-architecture.md) explains ownership and data flow;
[subsystem guides](../Sources/MacParakeetCore/) explain local implementation
constraints.

| Need | Read |
|---|---|
| Product direction and current behavior | [Vision](../spec/00-vision.md), [features](../spec/02-features.md), [ADRs](../spec/adr/) |
| Persisted data or public boundaries | [Data model](../spec/01-data-model.md), [contracts](../spec/contracts/README.md) |
| Agent/CLI operation | [Integrations](../integrations/README.md), [CLI changelog](../Sources/CLI/CHANGELOG.md) |
| Development and review | [AGENTS.md](../AGENTS.md), [review workflow](pr-review-workflow.md), [testing](../spec/09-testing.md) |
| Build, package or release | [Distribution](distribution.md), [human QA](human-qa-guide.md), [release smoke](release-demo-smoke.md) |
| Telemetry or local diagnostics | [Telemetry](telemetry.md), [privacy contract](../spec/contracts/telemetry-v1.md), [offline audio-log queries](local-audio-diagnostics-query.md) |
| Brand and UI | [UI patterns](../spec/04-ui-patterns.md), [brand identity](brand-identity.md), [brand assets](../brand-assets/README.md) |
| Planned or unfinished work | [Plan status board](../plans/README.md), [docs/plans](plans/) |
| Dated verification | [QA packages](qa/), [audits](audits/) |
| Proposals and historical context | [Research](research/), [historical archive](historical/README.md) |

ADRs preserve the reason for a decision; explicit amendments override older
implementation descriptions. Active specs and contracts describe intended
current behavior, with code/tests checked when they disagree. A proposal, old
plan checkbox or accepted strategy does not establish shipped capability.
Dated QA evidence applies only to its recorded candidate and environment.

The [2026-09-07 documentation audit](audits/2026-09-07-documentation-alignment.md)
records the current alignment pass. Its
[follow-up ideas](research/2026-09-07-documentation-audit-followups.md) are separate
from accepted decisions and release requirements.
