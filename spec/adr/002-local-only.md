# ADR-002: No Cloud Processing

> Status: **Accepted**
> Date: 2026-02-08

## Context

MacParakeet is entering a market where the dominant player (WisprFlow) relies on cloud processing. WisprFlow sends audio to remote servers for transcription and AI refinement, which creates three problems users consistently report:

1. **Privacy**: Audio data leaves the device. Users dictating medical notes, legal documents, proprietary code, or personal journals have legitimate privacy concerns.
2. **Latency**: WisprFlow users report 20-30 second server delays during peak usage hours. Cloud dependency means performance varies with server load, network conditions, and geographic distance.
3. **Reliability**: WisprFlow's Trustpilot rating is 2.8/5, with many complaints about server outages and inconsistent behavior. Cloud dependency introduces a failure mode that local processing eliminates entirely.

Meanwhile, local-only alternatives (MacWhisper, VoiceInk, BetterDictation) have proven that on-device STT is viable and increasingly preferred by privacy-conscious users.

## Decision

**100% local processing.** No audio, text, or user data is sent to any server, ever. The only network call the app makes is user-initiated YouTube URL downloads (for file transcription), which fetches a public video -- not user data. Downloaded YouTube audio is stored locally only (retained by default, user-configurable cleanup).

This applies to:

- **STT**: Parakeet TDT 0.6B-v3 runs locally via MLX (ADR-001)
- **Text processing**: Deterministic pipeline runs locally (ADR-004)
- **LLM features**: Qwen3-4B runs locally via MLX-Swift for command mode and advanced text modes
- **Updates**: Standard macOS app update mechanisms (Sparkle or App Store)
- **Analytics**: None. No telemetry, no crash reporting, no usage tracking.

## Rationale

### Privacy is the brand

"Your voice never leaves your Mac" is not just a feature -- it is the core brand promise. In a market where the leading competitor sends audio to cloud servers, local-only processing is MacParakeet's primary differentiator for privacy-conscious users.

### Consistency over peak quality

A cloud LLM (GPT-4, Claude) would produce better results for command mode and advanced text refinement. However:

- Local LLM (Qwen3-4B) produces **acceptable** results for the use cases that matter (reformatting, expanding abbreviations, command interpretation).
- Local processing is **consistently fast** -- no variance based on server load, network, or time of day.
- Users can always re-dictate or manually edit. The cost of a slightly less polished LLM output is low; the cost of a 20-second delay or privacy breach is high.

### No subscription required

Cloud processing requires ongoing server costs, which necessitates subscription pricing. Local-only processing has zero marginal cost per user, enabling our one-time purchase model (ADR-003).

### Market validation

- MacWhisper ($30, local-only) has strong sales and user loyalty
- VoiceInk ($39.99, local-only, open source) has a growing community
- Reddit threads consistently show users preferring local alternatives to WisprFlow
- Apple's own direction (on-device Siri, Apple Intelligence) validates the local-first approach

## Consequences

### Positive

- Zero privacy concerns -- audio never leaves the device
- Consistent performance regardless of network conditions
- Works offline (airplane, poor connectivity, restricted networks)
- No server costs, enabling one-time purchase pricing
- No dependency on third-party cloud services
- Simple architecture -- no networking layer, no auth, no API keys

### Negative

- **LLM quality ceiling**: Qwen3-4B (4-bit quantized, local) is significantly less capable than GPT-4 or Claude for complex text transformation. Command mode and formal rewriting will be "good enough" rather than "excellent."
- **No internet required, but model download is**: First launch requires downloading Parakeet (~1.5GB) and Qwen3 (~2.5GB) models. After that, fully offline.
- **No cloud backup or sync**: User data stays on-device. If the Mac is lost, dictation history is lost. This is intentional -- users who want cloud backup can use macOS iCloud or Time Machine.
- **No collaborative features**: Real-time sharing, team vocabularies, or cross-device sync would require cloud infrastructure. These are out of scope.

## Trade-offs Considered

| Approach | Quality | Privacy | Latency | Cost |
|----------|---------|---------|---------|------|
| Cloud-only (WisprFlow) | High | Low | Variable (20-30s peak) | Subscription |
| Hybrid (local STT + cloud LLM) | Medium-High | Medium | Fast STT, slow LLM | Subscription |
| **Local-only (our choice)** | **Medium** | **High** | **Consistent, fast** | **One-time** |

The hybrid approach was considered and rejected. It would compromise the privacy promise ("your voice never leaves your Mac" becomes "your voice stays local but your text goes to a server"), complicate the architecture, and still require subscription pricing for cloud LLM costs.

## References

- WisprFlow Trustpilot reviews: 2.8/5 average, common complaints about delays and reliability
- Reddit r/macapps sentiment: strong preference for local processing
- Apple Intelligence strategy: on-device processing as default, cloud only for complex tasks with user consent
